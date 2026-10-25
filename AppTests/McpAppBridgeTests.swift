// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing
import UIKit

@testable import MonoAgent
@testable import MonoAgentStore

@MainActor private final class BridgeGateway: McpAppRequestGateway {
  var isActive = true
  var retryRequiresConsent = false
  var onInvalidation: (@MainActor () -> Void)?
  var requests: [ApiMcpAppRequest] = []
  var result: JSONValue = .object(["content": .array([])])
  var failure: APIError?
  var hold = false
  var held: [CheckedContinuation<JSONValue, any Error>] = []
  var renewals = 0
  func request(_ body: ApiMcpAppRequest) async throws -> JSONValue {
    requests.append(body)
    if hold { return try await withCheckedThrowingContinuation { held.append($0) } }
    if let failure {
      retryRequiresConsent = true
      throw failure
    }
    return result
  }
  func renew() async throws {
    renewals += 1
    failure = nil
    retryRequiresConsent = false
  }
  func release(_ value: JSONValue = .object(["contents": .array([])])) {
    let pending = held
    held.removeAll()
    for waiter in pending { waiter.resume(returning: value) }
  }
  func close() {
    guard isActive else { return }
    isActive = false
    let callback = onInvalidation
    onInvalidation = nil
    callback?()
  }
}
@MainActor private final class BridgeConsent: McpConsentPresenting {
  var answer: Bool? = true
  var prompts: [McpConsentPrompt] = []
  var waiter: CheckedContinuation<Bool, Never>?
  var cancellations = 0
  var requestID: UUID?
  var settleOnCancel = true
  func confirm(_ prompt: McpConsentPrompt, requestID: UUID) async -> Bool {
    guard self.requestID == nil else { return false }
    self.requestID = requestID
    defer { if self.requestID == requestID { self.requestID = nil } }
    prompts.append(prompt)
    if let answer { return answer }
    return await withCheckedContinuation { waiter = $0 }
  }
  func approve() {
    let saved = waiter
    waiter = nil
    saved?.resume(returning: true)
  }
  func cancel(requestID: UUID) {
    guard self.requestID == requestID else { return }
    self.requestID = nil
    cancellations += 1
    let saved = waiter
    waiter = nil
    if settleOnCancel { saved?.resume(returning: false) }
  }
}
@MainActor private final class BridgeOpener: McpLinkOpening {
  var urls: [URL] = []
  var succeeds = true
  func open(_ url: URL) async -> Bool {
    urls.append(url)
    return succeeds
  }
}
@MainActor private final class BridgeObservations {
  var values: [JSONValue] = []
  var tick: Double = 0
  func responses(_ id: JSONValue) -> [JSONValue] {
    values.filter { $0[mcp: "kind"] == .string("response") && $0[mcp: "rpc"]?[mcp: "id"] == id }
      .compactMap { $0[mcp: "rpc"] }
  }
  func notifications(_ method: String) -> [JSONValue] {
    values.filter {
      $0[mcp: "kind"] == .string("notification")
        && $0[mcp: "rpc"]?[mcp: "method"] == .string(method)
    }.compactMap { $0[mcp: "rpc"]?[mcp: "params"] }
  }
}
private actor BridgeNativeTransport: HTTPTransport {
  enum Mode: Sendable { case normal, parallelReads, toolOverlap }
  let base = "/api/v1/threads/thread-example/messages/message-example/mcp-apps/garden"
  let resource: ApiMcpAppResource
  var mode: Mode = .normal
  var requests: [URLRequest] = []
  var accessCount = 0
  var heldTool: CheckedContinuation<HTTPResponse, any Error>?
  var heldReads: [CheckedContinuation<HTTPResponse, any Error>] = []
  init(resource: ApiMcpAppResource) { self.resource = resource }
  func configure(_ mode: Mode) { self.mode = mode }
  func postCount(_ method: String) -> Int {
    requests.filter { request in
      request.url?.path == base + "/requests" && request.httpMethod == "POST"
        && (try? JSONDecoder().decode(ApiMcpAppRequest.self, from: request.httpBody ?? Data()))?
          .method == method
    }.count
  }
  func toolIsHeld() -> Bool { heldTool != nil }
  func readCount() -> Int { heldReads.count }
  private func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
    .init(data: try JSONEncoder().encode(value))
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url?.path
    if path == "/api/v1/bootstrap" { return Scenario.bootstrap }
    if path == base { return try response(resource) }
    if path == base + "/access" {
      accessCount += 1
      var part = resource.app
      let token = accessCount == 1 ? "initial" : "renewed-\(accessCount)"
      part.resourceUrl = base + "?expires=1&token=" + token
      part.bridgeUrl = base + "/requests?expires=1&token=" + token
      return try response(
        JSONValue.object([
          "part": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(part))
        ]))
    }
    guard path == base + "/requests", let data = request.httpBody else {
      throw URLError(.resourceUnavailable)
    }
    let body = try JSONDecoder().decode(ApiMcpAppRequest.self, from: data)
    if body.method == "tools/call" {
      if mode == .toolOverlap { return try await withCheckedThrowingContinuation { heldTool = $0 } }
      return try toolResponse()
    }
    if body.method == "resources/read" {
      let token = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == "token" }?.value
      if mode != .normal, token == "initial" {
        return .init(
          data: Data(#"{"error":{"code":"reply_access_expired","message":"Expired"}}"#.utf8),
          status: 410)
      }
      if mode == .parallelReads {
        return try await withCheckedThrowingContinuation { heldReads.append($0) }
      }
      return try readResponse()
    }
    throw URLError(.resourceUnavailable)
  }
  private func toolResponse() throws -> HTTPResponse {
    try response(
      JSONValue.object([
        "result": .object([
          "content": .array([.object(["type": .string("text"), "text": .string("Beds planned")])])
        ])
      ]))
  }
  private func readResponse() throws -> HTTPResponse {
    try response(JSONValue.object(["result": .object(["contents": .array([])])]))
  }
  func releaseTool() throws {
    let waiter = heldTool
    heldTool = nil
    waiter?.resume(returning: try toolResponse())
  }
  func releaseRead() throws { heldReads.removeFirst().resume(returning: try readResponse()) }
}
private actor BridgeStoreEvents: ConsoleEventSource {
  var continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation?
  func subscribe(thread: String?, capacity: Int) -> AsyncThrowingStream<StreamUpdate, any Error> {
    let pair = AsyncThrowingStream<StreamUpdate, any Error>.makeStream()
    continuation = pair.continuation
    return pair.stream
  }
  func cancel() {
    continuation?.finish()
    continuation = nil
  }
}
@MainActor private final class BridgeStoreHarness {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let transport: BridgeNativeTransport
  let store: ConsoleStore
  let resource: ApiMcpAppResource
  init() throws {
    resource = try McpGardenFixture.resource()
    transport = BridgeNativeTransport(resource: resource)
    store = ConsoleStore(
      profile: SavedConsole(name: "Flockbox", endpoint: Scenario.endpoint),
      api: APIClient(endpoint: Scenario.endpoint, transport: transport),
      events: BridgeStoreEvents(),
      repository: FileConsoleRepository(directory: directory),
      replyFiles: ReplyFileCache(directory: directory.appendingPathComponent("files")))
  }
  func load() async throws -> McpAppAccess {
    await store.start()
    let thread = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data).threads[
      0]
    var message = try JSONDecoder().decode(
      WebMessage.self,
      from: Data(
        #"{"id":"message-example","threadId":"thread-example","role":"assistant","parts":[],"attachments":[],"createdAt":"2030-01-02T12:00:00Z","updatedAt":"2030-01-02T12:00:00Z","status":"completed","seq":1}"#
          .utf8))
    message.parts = [.mcpApp(resource.app)]
    store.hold(.init(thread: thread, messages: [message], savedAt: Date()))
    store.selectedThreadID = "thread-example"
    store.connection = .live
    return try await store.loadMcpApp(
      threadID: "thread-example", messageID: "message-example", partID: "garden")
  }
  func stop() async {
    await store.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}
@MainActor private final class BridgeSendGate {
  var waiters: [CheckedContinuation<Void, Never>] = []
  func hold(_ value: JSONValue) async {
    if value[mcp: "method"] == .string("ui/notifications/tool-input") {
      await withCheckedContinuation { waiters.append($0) }
    }
  }
  func release() { waiters.removeFirst().resume() }
}
private final class BridgeResourceBundle: NSObject {}

@Suite("MCP WebKit bridge semantics", .serialized)
@MainActor
struct McpAppBridgeTests {
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
  private func waitAsync(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !(await condition()) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition())
  }
  private func make(
    gateway: any McpAppRequestGateway = BridgeGateway(), consent: BridgeConsent = .init(),
    opener: BridgeOpener = .init(),
    observations: BridgeObservations = .init(), toolResult: JSONValue? = nil,
    advancingClock: Bool = false, html: String? = nil
  ) async throws -> McpAppBridge {
    var resource = try McpGardenFixture.resource(toolResult: toolResult)
    if let html { resource.html = html }
    let bridge = McpAppBridge(
      resource: resource, gateway: gateway,
      consent: consent, opener: opener,
      now: {
        if advancingClock {
          observations.tick += 0.1
          return observations.tick
        }
        return ProcessInfo.processInfo.systemUptime
      })
    bridge.debugEnvelopeObserver = { data in
      if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        value[mcp: "method"] == .string("fixture/observed"), let params = value[mcp: "params"]
      {
        observations.values.append(params)
      }
    }
    try await bridge.start()
    let host = try #require(bridge.host)
    host.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?
      .addSubview(host.webView)
    try await wait {
      bridge.state == .ready && !observations.notifications("ui/notifications/tool-result").isEmpty
    }
    return bridge
  }
  private func command(_ bridge: McpAppBridge, _ params: JSONValue) async throws {
    let host = try #require(bridge.host)
    do {
      try await host.sendEnvelope(
        JSONEncoder().encode(
          JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("fixture/command"), "params": params,
          ])))
    } catch {
      // The command can synchronously cause retirement before native delivery returns.
      guard bridge.state == .closed else { throw error }
    }
  }
  private func rpc(_ method: String, id: String, params: JSONValue = .object([:])) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params,
    ])
  }
  private func request(
    _ bridge: McpAppBridge, _ observations: BridgeObservations, _ method: String, id: String,
    params: JSONValue = .object([:])
  ) async throws -> JSONValue {
    let prior = observations.responses(.string(id)).count
    try await command(bridge, .object(["rpc": rpc(method, id: id, params: params)]))
    try await wait { observations.responses(.string(id)).count > prior }
    return try #require(observations.responses(.string(id)).last)
  }

  @Test func pinnedConformanceDefaultsNegotiationAndFixedContext() async throws {
    let url = try #require(
      Bundle(for: BridgeResourceBundle.self).url(
        forResource: "mcp-protocol-vectors", withExtension: "json"))
    let golden = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    #expect(golden[mcp: "source"] == .string("@modelcontextprotocol/ext-apps@1.7.5"))
    let observations = BridgeObservations()
    let gateway = BridgeGateway()
    let bridge = try await make(gateway: gateway, observations: observations)
    defer { bridge.close() }
    let initial = try #require(observations.responses(.string("initialize")).first?[mcp: "result"])
    #expect(initial[mcp: "hostCapabilities"] == golden[mcp: "hostCapabilities"])
    #expect(initial[mcp: "hostCapabilities"]?[mcp: "sandbox"]?[mcp: "permissions"] == nil)
    #expect(initial[mcp: "hostContext"]?[mcp: "platform"] == .string("mobile"))
    #expect(
      initial[mcp: "hostContext"]?[mcp: "availableDisplayModes"] == .array([.string("inline")]))
    let defaults = try #require(golden[mcp: "defaults"]?.mcpArray)
    for (index, vector) in defaults.enumerated() {
      let method = try #require(vector[mcp: "method"]?.mcpString)
      let response = try await request(
        bridge, observations, method, id: "default-\(index)",
        params: vector[mcp: "params"] ?? .object([:]))
      if let revision = vector[mcp: "revision"] {
        #expect(response[mcp: "result"]?[mcp: "protocolVersion"] == revision)
      } else {
        #expect(response[mcp: "result"] == vector[mcp: "result"])
      }
    }
    for (index, vector) in try #require(golden[mcp: "invalid"]?.mcpArray).enumerated() {
      let response = try await request(
        bridge, observations, try #require(vector[mcp: "method"]?.mcpString),
        id: "invalid-\(index)", params: vector[mcp: "params"] ?? .object([:]))
      #expect(response[mcp: "error"]?[mcp: "code"] == .number(-32602))
    }
    let unsupported = try await request(bridge, observations, "tools/list", id: "unsupported")
    #expect(unsupported[mcp: "error"]?[mcp: "code"] == .number(-32601))
    #expect(gateway.requests.isEmpty)
    #expect(
      observations.notifications("ui/notifications/tool-input").first
        == .object(["arguments": .object(["beds": .number(3)])]))
  }
  @Test func invalidInitialToolResultUsesWebFallbackAndHeightCoalesces() async throws {
    let observations = BridgeObservations()
    let bridge = try await make(observations: observations, toolResult: .object([:]))
    defer { bridge.close() }
    #expect(
      observations.notifications("ui/notifications/tool-result").first?[mcp: "isError"]
        == .bool(true))
    let batch: [JSONValue] = [10, 5000, 250.6].map {
      .object([
        "jsonrpc": .string("2.0"), "method": .string("ui/notifications/size-changed"),
        "params": .object(["height": .number($0)]),
      ])
    }
    try await command(bridge, .object(["batch": .array(batch)]))
    try await wait { bridge.height == 251 }
    try await command(
      bridge,
      .object([
        "rpc": .object([
          "jsonrpc": .string("2.0"), "method": .string("ui/notifications/size-changed"),
          "params": .object(["height": .number(-1)]),
        ])
      ]))
    try await wait { bridge.height == 160 }
    try await command(
      bridge,
      .object([
        "rpc": .object([
          "jsonrpc": .string("2.0"), "method": .string("ui/notifications/size-changed"),
          "params": .object(["height": .number(9000)]),
        ])
      ]))
    try await wait { bridge.height == 1600 }
    var environment = McpHostEnvironment()
    environment.theme = "dark"
    environment.width = 2000
    await bridge.updateEnvironment(environment)
    try await wait {
      observations.notifications("ui/notifications/host-context-changed").last?[mcp: "theme"]
        == .string("dark")
    }
    #expect(
      observations.notifications("ui/notifications/host-context-changed").last?[
        mcp: "containerDimensions"]
        == .object(["maxWidth": .number(1400), "maxHeight": .number(1600)]))
    #expect(!bridge.host!.isRetired)
  }
  @Test func toolsRequireNativeConsentAndIgnoreAppConfirmedWithBoundedPreview() async throws {
    let gateway = BridgeGateway()
    let consent = BridgeConsent()
    consent.answer = false
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, consent: consent, observations: observations)
    defer { bridge.close() }
    let params: JSONValue = .object([
      "name": .string("plan"), "confirmed": .bool(true),
      "arguments": .object([
        "note": .string(String(repeating: "x", count: 4000)),
        "token": .string("fictional-hidden-value"),
      ]),
    ])
    let denied = try await request(bridge, observations, "tools/call", id: "denied", params: params)
    #expect(denied[mcp: "error"] != nil && gateway.requests.isEmpty)
    #expect((consent.prompts.first?.argumentPreview?.utf8.count ?? 0) <= 2048)
    #expect(consent.prompts.first?.argumentPreview?.contains("[redacted]") == true)
    #expect(consent.prompts.first?.argumentPreview?.contains("fictional-hidden-value") == false)
    consent.answer = true
    let allowed = try await request(
      bridge, observations, "tools/call", id: "allowed", params: params)
    #expect(allowed[mcp: "result"] == gateway.result)
    #expect(gateway.requests.count == 1 && gateway.requests[0].confirmed == true)
    #expect(gateway.requests[0].params?[mcp: "confirmed"] == nil)
    #expect(consent.prompts.count == 2)
  }
  @Test func onlyOneConsentOthersDeclineAndInvalidationCancelsPending() async throws {
    let gateway = BridgeGateway()
    let consent = BridgeConsent()
    consent.answer = nil
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, consent: consent, observations: observations)
    defer { bridge.close() }
    try await command(
      bridge,
      .object(["rpc": rpc("tools/call", id: "held", params: .object(["name": .string("plan")]))]))
    try await wait { consent.waiter != nil }
    let denied = try await request(
      bridge, observations, "ui/open-link", id: "other",
      params: .object(["url": .string("https://garden.example/")]))
    #expect(denied[mcp: "result"]?[mcp: "isError"] == .bool(true))
    #expect(consent.prompts.count == 1)
    let late = try #require(consent.waiter)
    let host = try #require(bridge.host)
    let sent = host.debugSendAttempts
    let completed = bridge.debugCompletedOperations
    consent.settleOnCancel = false
    gateway.close()
    #expect(bridge.state == .closed && consent.waiter == nil && consent.cancellations == 1)
    late.resume(returning: true)
    try await wait { bridge.debugCompletedOperations > completed }
    #expect(gateway.requests.isEmpty && host.isRetired && host.debugSendAttempts == sent)
  }
  @Test func openLinkUsesApprovedChangedDestinationAndContextRequiresAccepted() async throws {
    let gateway = BridgeGateway()
    let opener = BridgeOpener()
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, opener: opener, observations: observations)
    defer { bridge.close() }
    gateway.result = .object([
      "allowed": .bool(true), "url": .string("https://approved.example/changed"),
    ])
    let opened = try await request(
      bridge, observations, "ui/open-link", id: "open",
      params: .object(["url": .string("https://garden.example/requested")]))
    #expect(opened[mcp: "result"] == .object([:]))
    #expect(opener.urls.map(\.absoluteString) == ["https://approved.example/changed"])
    gateway.result = .object(["allowed": .bool(true), "url": .string("file:///fictional.txt")])
    let invalid = try await request(
      bridge, observations, "ui/open-link", id: "invalid-url",
      params: .object(["url": .string("https://garden.example/")]))
    #expect(invalid[mcp: "result"]?[mcp: "isError"] == .bool(true) && opener.urls.count == 1)
    gateway.result = .object(["reason": .string(String(repeating: "r", count: 900))])
    let rejected = try await request(
      bridge, observations, "ui/update-model-context", id: "context-rejected")
    #expect(rejected[mcp: "error"]?[mcp: "message"]?.mcpString?.count == 500)
    gateway.result = .object(["accepted": .bool(true)])
    let accepted = try await request(
      bridge, observations, "ui/update-model-context", id: "context-accepted",
      params: .object(["structuredContent": .object(["beds": .number(3)])]))
    #expect(accepted[mcp: "result"] == .object([:]))
  }
  @Test func expiredEffectNeverReplaysAndExplicitRetryObtainsFreshConsent() async throws {
    let gateway = BridgeGateway()
    let consent = BridgeConsent()
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, consent: consent, observations: observations)
    defer { bridge.close() }
    gateway.failure = .init(status: 410, code: "reply_access_expired")
    let expired = try await request(
      bridge, observations, "tools/call", id: "expired", params: .object(["name": .string("plan")]))
    #expect(expired[mcp: "error"] != nil && bridge.retryRequiresConsent)
    #expect(gateway.requests.count == 1 && gateway.renewals == 0)
    try await bridge.renewAccessForRetry()
    #expect(gateway.requests.count == 1 && gateway.renewals == 1)
    _ = try await request(
      bridge, observations, "tools/call", id: "retry", params: .object(["name": .string("plan")]))
    #expect(
      gateway.requests.count == 2 && consent.prompts.count == 2 && !bridge.retryRequiresConsent)
  }
  @Test func fourInFlightAndLateResultsAreDiscardedAfterClose() async throws {
    let gateway = BridgeGateway()
    gateway.hold = true
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, observations: observations)
    defer {
      bridge.close()
      gateway.release()
    }
    for i in 0..<4 {
      try await command(
        bridge,
        .object([
          "rpc": rpc(
            "resources/read", id: "held-\(i)", params: .object(["uri": .string("garden://beds")]))
        ]))
    }
    try await wait { gateway.held.count == 4 }
    let busy = try await request(
      bridge, observations, "resources/read", id: "busy",
      params: .object(["uri": .string("garden://beds")]))
    #expect(busy[mcp: "error"] != nil && gateway.requests.count == 4 && bridge.inFlight == 4)
    #expect(gateway.requests.allSatisfy { $0.confirmed == false })
    let host = try #require(bridge.host)
    let sent = host.debugSendAttempts
    let completed = bridge.debugCompletedOperations
    gateway.close()
    gateway.release()
    try await wait { bridge.debugCompletedOperations >= completed + 4 }
    #expect(bridge.state == .closed && host.debugSendAttempts == sent)
  }
  @Test func recentIdWindowIsSlidingNotLifetimeAndDuplicatesClose() async throws {
    let observations = BridgeObservations()
    let bridge = try await make(observations: observations, advancingClock: true)
    defer { bridge.close() }
    for i in 0..<257 { _ = try await request(bridge, observations, "ping", id: "window-\(i)") }
    _ = try await request(bridge, observations, "ping", id: "window-0")
    #expect(bridge.state == .ready)
    try await command(bridge, .object(["rpc": rpc("ping", id: "window-0")]))
    try await wait { bridge.state == .closed }
    #expect(bridge.statusText.contains("Reopen"))
  }
  @Test func floodClosesAndMalformedIdNeverForwards() async throws {
    let observations = BridgeObservations()
    let gateway = BridgeGateway()
    let bridge = try await make(gateway: gateway, observations: observations)
    defer { bridge.close() }
    let batch = (0..<80).map { rpc("ping", id: "flood-\($0)") }
    try await command(bridge, .object(["batch": .array(batch)]))
    try await wait { bridge.state == .closed }
    #expect(bridge.statusText.contains("Reopen") && gateway.requests.isEmpty)
    let invalidGateway = BridgeGateway()
    let invalid = try await make(gateway: invalidGateway)
    defer { invalid.close() }
    try await command(
      invalid,
      .object([
        "rpc": .object([
          "jsonrpc": .string("2.0"), "id": .number(1.5), "method": .string("tools/call"),
          "params": .object(["name": .string("plan")]),
        ])
      ]))
    try await wait { invalid.state == .closed }
    #expect(invalidGateway.requests.isEmpty)
  }
  @Test func navigationRetirementCancelsConsentAndDeepMessagesNeverForward() async throws {
    let gateway = BridgeGateway()
    let consent = BridgeConsent()
    consent.answer = nil
    let bridge = try await make(gateway: gateway, consent: consent)
    defer { bridge.close() }
    try await command(
      bridge,
      .object([
        "rpc": rpc(
          "tools/call", id: "before-navigation", params: .object(["name": .string("plan")]))
      ]))
    try await wait { consent.waiter != nil }
    let late = try #require(consent.waiter)
    let host = try #require(bridge.host)
    let completed = bridge.debugCompletedOperations
    consent.settleOnCancel = false
    try await command(bridge, .object(["navigate": .bool(true)]))
    try await wait { bridge.state == .closed }
    #expect(consent.cancellations == 1 && consent.waiter == nil && gateway.requests.isEmpty)
    let sent = host.debugSendAttempts
    late.resume(returning: true)
    try await wait { bridge.debugCompletedOperations > completed }
    #expect(gateway.requests.isEmpty && host.debugSendAttempts == sent)
    let deepGateway = BridgeGateway()
    let deep = try await make(gateway: deepGateway)
    defer { deep.close() }
    var value: JSONValue = .object([:])
    for _ in 0..<40 { value = .object(["child": value]) }
    try await command(
      deep,
      .object([
        "rpc": rpc(
          "tools/call", id: "deep", params: .object(["name": .string("plan"), "arguments": value]))
      ]))
    try await wait { deep.state == .closed }
    #expect(deepGateway.requests.isEmpty)
  }
  @Test func malformedForwardResultsReturnErrorsAndIdKindsRemainDistinct() async throws {
    let gateway = BridgeGateway()
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, observations: observations)
    defer { bridge.close() }
    gateway.result = .object(["content": .array([.object(["type": .string("text")])])])
    let tool = try await request(
      bridge, observations, "tools/call", id: "invalid-tool-result",
      params: .object(["name": .string("plan")]))
    #expect(tool[mcp: "error"] != nil)
    gateway.result = .object([
      "contents": .array([.object(["uri": .string("garden://beds"), "text": .number(3)])])
    ])
    let resource = try await request(
      bridge, observations, "resources/read", id: "invalid-resource-result",
      params: .object(["uri": .string("garden://beds")]))
    #expect(resource[mcp: "error"] != nil)
    for id: JSONValue in [.number(7), .string("7"), .string("")] {
      try await command(
        bridge,
        .object(["rpc": .object(["jsonrpc": .string("2.0"), "id": id, "method": .string("ping")])]))
      try await wait { !observations.responses(id).isEmpty }
      #expect(observations.responses(id).first?[mcp: "result"] == .object([:]))
    }
    #expect(bridge.state == .ready)
  }
  @Test func declinedHandlerFailureAndUnknownMethodMatchSdkErrorCodes() async throws {
    let url = try #require(
      Bundle(for: BridgeResourceBundle.self).url(
        forResource: "mcp-protocol-vectors", withExtension: "json"))
    let golden = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let gateway = BridgeGateway()
    let consent = BridgeConsent()
    consent.answer = false
    let observations = BridgeObservations()
    let bridge = try await make(gateway: gateway, consent: consent, observations: observations)
    defer { bridge.close() }
    let declined = try await request(
      bridge, observations, "tools/call", id: "error-declined",
      params: .object(["name": .string("plan")]))
    #expect(declined[mcp: "error"]?[mcp: "code"] == golden[mcp: "errorCodes"]?[mcp: "declined"])
    consent.answer = true
    gateway.failure = .init(status: 500, code: "synthetic_failure")
    let failure = try await request(
      bridge, observations, "tools/call", id: "error-handler",
      params: .object(["name": .string("plan")]))
    #expect(
      failure[mcp: "error"]?[mcp: "code"] == golden[mcp: "errorCodes"]?[mcp: "handlerFailure"])
    let unknown = try await request(bridge, observations, "unknown", id: "error-unknown")
    #expect(unknown[mcp: "error"]?[mcp: "code"] == golden[mcp: "errorCodes"]?[mcp: "unknownMethod"])
  }
  @Test func synchronousScriptStartInitializeReachesReady() async throws {
    let observations = BridgeObservations()
    let html = """
      <script>
      parent.postMessage({jsonrpc:'2.0',id:'initialize',method:'ui/initialize',params:{
        appInfo:{name:'Early garden',version:'1.0'},appCapabilities:{},protocolVersion:'2026-01-26'}},'*');
      addEventListener('message',event=>{
        if(event.source!==parent)return;
        const rpc=event.data;
        if(rpc.id==='initialize'&&rpc.result)parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'},'*');
        parent.postMessage({jsonrpc:'2.0',method:'fixture/observed',params:{kind:rpc.method?'notification':'response',rpc}},'*');
      });
      </script><h1>Early garden</h1>
      """
    let bridge = try await make(observations: observations, html: html)
    defer { bridge.close() }
    let host = try #require(bridge.host)
    let state =
      try await host.webView.callAsyncJavaScript(
        "return window.mcpBufferState()", arguments: [:], in: nil,
        contentWorld: McpAppBridgeListener.world) as? [String: Any]
    #expect(bridge.state == .ready && host.innerLoaded && !host.isRetired)
    #expect(state?["loads"] as? Int == 1)
    #expect(state?["count"] as? Int == 0 && state?["bytes"] as? Int == 0)
    let sends = try host.debugSendAttempts.map {
      try JSONDecoder().decode(JSONValue.self, from: $0)
    }
    #expect(
      sends.filter { $0[mcp: "id"] == .string("initialize") && $0[mcp: "result"] != nil }.count == 1
    )
  }
  @Test func nativeLocaleUsesBcp47() async throws {
    let environment = McpHostEnvironment()
    #expect(environment.locale == Locale.current.identifier(.bcp47))
    #expect(!environment.locale.contains("_"))
    let observations = BridgeObservations()
    let bridge = try await make(observations: observations)
    defer { bridge.close() }
    #expect(
      observations.responses(.string("initialize")).first?[mcp: "result"]?[mcp: "hostContext"]?[
        mcp: "locale"] == .string(Locale.current.identifier(.bcp47)))
  }
  @Test func sharedPresenterIsNotCancelledWhenAnotherBridgeClosesOrDeinitializes() async throws {
    let consent = BridgeConsent()
    consent.answer = nil
    var old: McpAppBridge? = try await make(consent: consent)
    weak let released = old
    let gateway = BridgeGateway()
    let observations = BridgeObservations()
    let active = try await make(gateway: gateway, consent: consent, observations: observations)
    defer { active.close() }
    try await command(
      active,
      .object(["rpc": rpc("tools/call", id: "shared", params: .object(["name": .string("plan")]))]))
    try await wait { consent.waiter != nil }
    let requestID = consent.requestID
    old?.close()
    old = nil
    try await wait { released == nil }
    #expect(consent.cancellations == 0 && consent.requestID == requestID && consent.waiter != nil)
    consent.approve()
    try await wait { observations.responses(.string("shared")).count == 1 }
    #expect(gateway.requests.count == 1 && active.state == .ready)
  }
  @Test func duplicateInitializedOperationsStayTrackedAndCannotSendAfterTeardown() async throws {
    let bridge = try await make()
    defer { bridge.close() }
    try await wait { bridge.debugOperationCount == 0 }
    let gate = BridgeSendGate()
    bridge.debugBeforeSend = { await gate.hold($0) }
    let initialized: JSONValue = .object([
      "jsonrpc": .string("2.0"), "method": .string("ui/notifications/initialized"),
    ])
    try await command(bridge, .object(["batch": .array([initialized, initialized])]))
    try await wait { gate.waiters.count == 2 }
    #expect(bridge.debugOperationCount == 2)
    gate.release()
    try await wait { bridge.debugOperationCount == 1 }
    let host = try #require(bridge.host)
    let sent = host.debugSendAttempts.count
    let completed = bridge.debugCompletedOperations
    await bridge.teardown()
    gate.release()
    try await wait { bridge.debugCompletedOperations >= completed + 2 }
    let after = try host.debugSendAttempts.dropFirst(sent).map {
      try JSONDecoder().decode(JSONValue.self, from: $0)
    }
    #expect(after.count == 1 && after.first?[mcp: "method"] == .string("ui/resource-teardown"))
  }
  @Test func slidOutIdReuseDoesNotUntrackPendingConsent() async throws {
    let consent = BridgeConsent()
    consent.answer = nil
    consent.settleOnCancel = false
    let gateway = BridgeGateway()
    let observations = BridgeObservations()
    let bridge = try await make(
      gateway: gateway, consent: consent, observations: observations, advancingClock: true)
    defer { bridge.close() }
    let tool = rpc("tools/call", id: "sliding-consent", params: .object(["name": .string("plan")]))
    try await command(bridge, .object(["rpc": tool]))
    try await wait { consent.waiter != nil }
    let late = try #require(consent.waiter)
    for i in 0..<257 { _ = try await request(bridge, observations, "ping", id: "slide-\(i)") }
    try await command(bridge, .object(["rpc": tool]))
    try await wait {
      observations.responses(.string("sliding-consent")).count == 1
        && bridge.debugOperationCount == 1
    }
    let host = try #require(bridge.host)
    let sent = host.debugSendAttempts
    let completed = bridge.debugCompletedOperations
    bridge.close()
    late.resume(returning: true)
    try await wait { bridge.debugCompletedOperations > completed }
    #expect(
      gateway.requests.isEmpty && host.debugSendAttempts == sent && consent.cancellations == 1)
  }
  @Test func nativeGatewayCancelZeroPostsAllowOnePostAndRenewalsKeepResultsLive() async throws {
    let h = try BridgeStoreHarness()
    let session = try await h.load()
    let consent = BridgeConsent()
    consent.answer = false
    let observations = BridgeObservations()
    let bridge = try await make(
      gateway: McpStoreGateway(store: h.store, session: session), consent: consent,
      observations: observations)
    defer { bridge.close() }
    let denied = try await request(
      bridge, observations, "tools/call", id: "transport-cancel",
      params: .object(["name": .string("plan")]))
    #expect(denied[mcp: "error"]?[mcp: "code"] == .number(-32603))
    #expect(await h.transport.postCount("tools/call") == 0)
    consent.answer = true
    _ = try await request(
      bridge, observations, "tools/call", id: "transport-allow",
      params: .object(["name": .string("plan")]))
    #expect(await h.transport.postCount("tools/call") == 1)
    let bodies = try await h.transport.requests.filter {
      $0.url?.path.hasSuffix("/requests") == true
    }.map { try JSONDecoder().decode(ApiMcpAppRequest.self, from: $0.httpBody!) }
    #expect(bodies.count == 1 && bodies.first?.confirmed == true)
    bridge.close()
    await h.stop()
  }
  @Test func nativeGatewayParallelExpiredReadsBothReturnExactlyOnce() async throws {
    let h = try BridgeStoreHarness()
    let session = try await h.load()
    await h.transport.configure(.parallelReads)
    let observations = BridgeObservations()
    let bridge = try await make(
      gateway: McpStoreGateway(store: h.store, session: session), observations: observations)
    defer { bridge.close() }
    for id in ["parallel-1", "parallel-2"] {
      try await command(
        bridge,
        .object([
          "rpc": rpc("resources/read", id: id, params: .object(["uri": .string("garden://beds")]))
        ]))
      try await waitAsync { await h.transport.readCount() == (id == "parallel-1" ? 1 : 2) }
    }
    try await h.transport.releaseRead()
    try await wait { observations.responses(.string("parallel-1")).count == 1 }
    try await h.transport.releaseRead()
    try await wait { observations.responses(.string("parallel-2")).count == 1 }
    #expect(bridge.state == .ready && !session.isClosed)
    #expect(await h.transport.postCount("resources/read") == 4)
    let sent = try #require(bridge.host).debugSendAttempts.map {
      try JSONDecoder().decode(JSONValue.self, from: $0)
    }
    for id in ["parallel-1", "parallel-2"] {
      #expect(sent.filter { $0[mcp: "id"] == .string(id) && $0[mcp: "result"] != nil }.count == 1)
    }
    bridge.close()
    await h.stop()
  }
  @Test func nativeGatewayConfirmedToolOverlapReadRenewalReturnsOnceWithoutReplay() async throws {
    let h = try BridgeStoreHarness()
    let session = try await h.load()
    await h.transport.configure(.toolOverlap)
    let observations = BridgeObservations()
    let bridge = try await make(
      gateway: McpStoreGateway(store: h.store, session: session), observations: observations)
    defer { bridge.close() }
    try await command(
      bridge,
      .object([
        "rpc": rpc("tools/call", id: "long-tool", params: .object(["name": .string("plan")]))
      ]))
    while !(await h.transport.toolIsHeld()) { try await Task.sleep(for: .milliseconds(10)) }
    _ = try await request(
      bridge, observations, "resources/read", id: "renew-during-tool",
      params: .object(["uri": .string("garden://beds")]))
    try await h.transport.releaseTool()
    try await wait { observations.responses(.string("long-tool")).count == 1 }
    #expect(
      observations.responses(.string("long-tool")).first?[mcp: "result"]?[mcp: "content"]?.mcpArray
        != nil)
    #expect(bridge.state == .ready && !session.isClosed)
    #expect(await h.transport.postCount("tools/call") == 1)
    #expect(await h.transport.postCount("resources/read") == 2)
    let sent = try #require(bridge.host).debugSendAttempts.map {
      try JSONDecoder().decode(JSONValue.self, from: $0)
    }
    #expect(
      sent.filter { $0[mcp: "id"] == .string("long-tool") && $0[mcp: "result"] != nil }.count == 1)
    bridge.close()
    await h.stop()
  }
  @Test func appTeardownClosesAndHostTeardownAcknowledgesOrTimesOut() async throws {
    let app = try await make()
    defer { app.close() }
    try await command(
      app,
      .object([
        "rpc": .object([
          "jsonrpc": .string("2.0"), "method": .string("ui/notifications/request-teardown"),
        ])
      ]))
    try await wait { app.state == .closed }
    #expect(app.statusText.contains("Reopen"))
    for acknowledges in [true, false] {
      let observations = BridgeObservations()
      let bridge = try await make(observations: observations)
      defer { bridge.close() }
      try await command(bridge, .object(["acknowledgeTeardown": .bool(acknowledges)]))
      let start = ContinuousClock.now
      await bridge.teardown()
      let elapsed = start.duration(to: .now)
      #expect(bridge.state == .closed && bridge.host?.isRetired == true)
      #expect(observations.values.contains { $0[mcp: "kind"] == .string("teardown") })
      if !acknowledges { #expect(elapsed >= .milliseconds(450) && elapsed < .seconds(2)) }
    }
  }
}
