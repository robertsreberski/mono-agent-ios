// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing
import UIKit

@testable import MonoAgent

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
  func confirm(_ prompt: McpConsentPrompt) async -> Bool {
    prompts.append(prompt)
    if let answer { return answer }
    return await withCheckedContinuation { waiter = $0 }
  }
  func approve() {
    let saved = waiter
    waiter = nil
    saved?.resume(returning: true)
  }
  func cancel() {
    cancellations += 1
    let saved = waiter
    waiter = nil
    saved?.resume(returning: false)
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
private final class BridgeResourceBundle: NSObject {}

@Suite("MCP WebKit bridge semantics", .serialized)
@MainActor
struct McpAppBridgeTests {
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
  private func make(
    gateway: BridgeGateway = .init(), consent: BridgeConsent = .init(),
    opener: BridgeOpener = .init(),
    observations: BridgeObservations = .init(), toolResult: JSONValue? = nil,
    advancingClock: Bool = false
  ) async throws -> McpAppBridge {
    let bridge = McpAppBridge(
      resource: try McpGardenFixture.resource(toolResult: toolResult), gateway: gateway,
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
    gateway.close()
    #expect(bridge.state == .closed && consent.waiter == nil && consent.cancellations == 1)
    consent.approve()
    #expect(gateway.requests.isEmpty && bridge.host?.isRetired == true)
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
    gateway.close()
    gateway.release()
    try await Task.sleep(for: .milliseconds(30))
    #expect(bridge.state == .closed && observations.responses(.string("held-0")).isEmpty)
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
    try await command(bridge, .object(["navigate": .bool(true)]))
    try await wait { bridge.state == .closed }
    #expect(consent.cancellations == 1 && consent.waiter == nil && gateway.requests.isEmpty)
    consent.approve()
    #expect(gateway.requests.isEmpty)
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
