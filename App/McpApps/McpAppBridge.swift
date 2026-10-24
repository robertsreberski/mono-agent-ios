// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Observation

/// Method/effect layer above the opaque-frame relay. No transcript or presentation ownership.
@MainActor @Observable
final class McpAppBridge: McpAppEnvelopeDelegate {
  enum State { case awaitingInitialize, awaitingInitialized, ready, tearingDown, closed }
  private(set) var state: State = .awaitingInitialize
  private(set) var statusText = "Loading interactive app…"
  private(set) var height: Double = 320
  private(set) var retryRequiresConsent = false
  private(set) var host: McpAppHost?
  #if DEBUG
    var debugEnvelopeObserver: ((Data) -> Void)?
  #endif
  private(set) var inFlight = 0
  private let gateway: any McpAppRequestGateway
  private let consent: any McpConsentPresenting
  private let opener: any McpLinkOpening
  private var resource: ApiMcpAppResource?
  private var environment: McpHostEnvironment
  @ObservationIgnored private let now: @MainActor () -> TimeInterval
  @ObservationIgnored private var operations: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var recentIDs: [McpRpcID] = []
  @ObservationIgnored private var pendingConsent = false
  @ObservationIgnored private var starting = false
  @ObservationIgnored private var tokens: Double = 40
  @ObservationIgnored private var lastTick: TimeInterval
  @ObservationIgnored private var sizeTask: Task<Void, Never>?
  @ObservationIgnored private var requestedHeight: Double?
  @ObservationIgnored private var teardownTask: Task<Void, Never>?
  @ObservationIgnored private var teardownID: McpRpcID?
  @ObservationIgnored private var teardownWaiter: CheckedContinuation<Void, Never>?

  init(
    resource: ApiMcpAppResource, gateway: any McpAppRequestGateway,
    consent: any McpConsentPresenting, opener: any McpLinkOpening,
    environment: McpHostEnvironment = .init(),
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.resource = resource
    self.gateway = gateway
    self.consent = consent
    self.opener = opener
    self.environment = environment
    self.now = now
    lastTick = now()
    gateway.onInvalidation = { [weak self] in
      self?.close(reason: "The app session ended. Reopen to load it again.")
    }
  }
  static func make(
    store: ConsoleStore, session: McpAppAccess, consent: any McpConsentPresenting,
    opener: any McpLinkOpening = McpSystemLinkOpener(), environment: McpHostEnvironment = .init()
  ) async throws -> McpAppBridge {
    guard let resource = session.resource, resource.connected, !session.isClosed else {
      throw CancellationError()
    }
    let bridge = McpAppBridge(
      resource: resource, gateway: McpStoreGateway(store: store, session: session),
      consent: consent, opener: opener, environment: environment)
    try await bridge.start()
    return bridge
  }
  func start() async throws {
    guard !starting, host == nil, state == .awaitingInitialize, gateway.isActive, let resource
    else {
      throw CancellationError()
    }
    starting = true
    defer { starting = false }
    let created = try await McpAppHost.make(html: resource.html, delegate: self)
    guard state != .closed, gateway.isActive, !created.isRetired, !Task.isCancelled else {
      created.close()
      throw CancellationError()
    }
    host = created
  }
  func mcpAppHostDidRetire(_ host: McpAppHost) {
    guard self.host === host else { return }
    close(reason: "The app was stopped. Reopen to load it again.")
  }
  func mcpAppHost(_ host: McpAppHost, didReceiveEnvelope envelope: Data) {
    guard self.host === host, state != .closed, !host.isRetired, gateway.isActive else { return }
    #if DEBUG
      debugEnvelopeObserver?(envelope)
    #endif
    let tick = now()
    tokens = min(40, tokens + max(0, tick - lastTick) * 20)
    lastTick = tick
    guard tokens >= 1 else {
      close(reason: "The app sent too many messages. Reopen to try again.")
      return
    }
    tokens -= 1
    guard envelope.count <= McpAppBridgeListener.maximumEnvelopeBytes,
      let value = try? JSONDecoder().decode(JSONValue.self, from: envelope), value.mcpBounded(),
      let rpc = value.mcpObject, rpc["jsonrpc"] == .string("2.0")
    else {
      close(reason: "The app sent an invalid message. Reopen to try again.")
      return
    }
    if rpc["method"] == nil {
      // Only our own teardown response has a native pending request. Unsolicited replies drop.
      if state == .tearingDown, let id = McpRpcID(rpc["id"]), id == teardownID,
        (rpc["result"] != nil) != (rpc["error"] != nil)
      {
        close(reason: "The interactive app closed. Reopen to load it again.")
      }
      return
    }
    guard let method = rpc["method"]?.mcpString else {
      close()
      return
    }
    if rpc["id"] == nil {
      notification(method, params: rpc["params"])
      return
    }
    guard let id = McpRpcID(rpc["id"]) else {
      close(reason: "Invalid app request ID. Reopen to try again.")
      return
    }
    guard !recentIDs.contains(id) else {
      close(reason: "The app reused a request ID. Reopen to try again.")
      return
    }
    recentIDs.append(id)
    if recentIDs.count > 256 { recentIDs.removeFirst() }
    guard state != .tearingDown else { return }
    guard inFlight < 4 else {
      launch("busy:" + id.key) { [weak self] in
        await self?.reply(
          id, failure: .init(code: -32000, message: "The app has too many pending requests."))
      }
      return
    }
    inFlight += 1
    launch(id.key) { [weak self] in
      guard let self else { return }
      defer { self.inFlight = max(0, self.inFlight - 1) }
      do {
        let params = try McpAppWire.parameters(method, rpc["params"])
        let result = try await self.handle(method, params: params)
        guard !Task.isCancelled, self.state != .closed else { return }
        await self.reply(id, result: result)
      } catch {
        guard !Task.isCancelled, self.state != .closed else { return }
        if error is CancellationError {
          self.close()
          return
        }
        if let api = error as? APIError, api.code == "reply_access_expired" {
          self.retryRequiresConsent = true
          self.statusText = "App access expired. Retry explicitly with fresh confirmation."
        }
        await self.reply(
          id,
          failure: (error as? McpBridgeFailure)
            ?? .init(
              code: -32000,
              message: self.retryRequiresConsent
                ? "App access expired; explicit retry is required." : "The MCP App request failed.")
        )
      }
    }
  }
  private func launch(_ key: String, _ operation: @escaping @MainActor () async -> Void) {
    operations[key] = Task { [weak self] in
      await operation()
      self?.operations[key] = nil
    }
  }
  private func assertActive() throws {
    guard !Task.isCancelled, state == .ready, gateway.isActive else { throw CancellationError() }
  }
  private func handle(_ method: String, params: JSONValue) async throws -> JSONValue {
    if method == "ping" { return .object([:]) }
    if method == "ui/initialize" {
      if state == .awaitingInitialize { state = .awaitingInitialized }
      let revision = params[mcp: "protocolVersion"]!.mcpString!
      return .object([
        "protocolVersion": .string(
          McpAppWire.revisions.contains(revision) ? revision : McpAppWire.latestRevision),
        "hostInfo": .object(["name": .string("mono-agent iOS"), "version": .string("0.4.0")]),
        "hostCapabilities": McpAppWire.hostCapabilities,
        "hostContext": environment.context(height: height),
      ])
    }
    if method == "ui/request-display-mode" { return .object(["mode": .string("inline")]) }
    guard state == .ready else {
      throw McpBridgeFailure(code: -32000, message: "The app handshake is not complete.")
    }
    try assertActive()
    if method != "resources/read" {
      let allowed = await requestConfirmation(method, params: params)
      try assertActive()
      if !allowed {
        if method == "ui/open-link" { return .object(["isError": .bool(true)]) }
        throw McpBridgeFailure.declined
      }
    }
    try assertActive()
    let result = try await gateway.request(
      .init(method: method, params: params, confirmed: method != "resources/read"))
    try assertActive()
    switch method {
    case "tools/call":
      guard McpAppWire.validContent(result[mcp: "content"]),
        result[mcp: "isError"] == nil || result[mcp: "isError"] == .bool(true)
          || result[mcp: "isError"] == .bool(false)
      else {
        throw McpBridgeFailure(code: -32000, message: "The tool returned an invalid result.")
      }
      return result
    case "resources/read":
      guard let contents = result[mcp: "contents"]?.mcpArray,
        contents.allSatisfy({ item in
          item[mcp: "uri"]?.mcpString != nil
            && (item[mcp: "text"]?.mcpString != nil || item[mcp: "blob"]?.mcpString != nil)
        })
      else {
        throw McpBridgeFailure(code: -32000, message: "The resource returned an invalid result.")
      }
      return result
    case "ui/open-link":
      guard result[mcp: "allowed"] == .bool(true), let raw = result[mcp: "url"]?.mcpString,
        raw.utf8.count <= 8192, let url = URL(string: raw),
        ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil
      else { return .object(["isError": .bool(true)]) }
      let opened = await opener.open(url)
      try assertActive()
      if !opened { statusText = "The browser blocked the app's external link." }
      return opened ? .object([:]) : .object(["isError": .bool(true)])
    case "ui/update-model-context":
      guard result[mcp: "accepted"] == .bool(true) else {
        throw McpBridgeFailure(
          code: -32000,
          message: McpAppWire.boundedText(result[mcp: "reason"]?.mcpString, limit: 500)
            ?? "The host did not apply the context update.")
      }
      return .object([:])
    default: throw McpBridgeFailure.invalidParams
    }
  }
  private func requestConfirmation(_ method: String, params: JSONValue) async -> Bool {
    guard !pendingConsent else { return false }
    pendingConsent = true
    defer { pendingConsent = false }
    let prompt: McpConsentPrompt
    if method == "tools/call" {
      let name =
        McpAppWire.boundedText(params[mcp: "name"]?.mcpString, limit: 256) ?? "requested tool"
      let server = McpAppWire.boundedText(resource?.app.serverName, limit: 256) ?? "server"
      let preview = McpAppWire.argumentPreview(params[mcp: "arguments"])
      prompt = .init(
        method: method, title: "Allow app tool call?", detail: "Run \(name) on \(server).",
        argumentPreview: preview)
    } else if method == "ui/open-link" {
      prompt = .init(
        method: method, title: "Open external link?",
        detail: McpAppWire.boundedText(params[mcp: "url"]?.mcpString, limit: 8192)
          ?? "the requested link",
        argumentPreview: nil)
    } else {
      prompt = .init(
        method: method, title: "Allow app context update?",
        detail: "The app wants to prepare context for a future model turn.", argumentPreview: nil)
    }
    return await consent.confirm(prompt)
  }
  private func notification(_ method: String, params: JSONValue?) {
    guard params == nil || params?.mcpObject != nil else { return }
    if method == "ui/notifications/request-teardown" {
      close(reason: "The interactive app closed. Reopen to load it again.")
      return
    }
    if method == "ui/notifications/initialized", state == .awaitingInitialized || state == .ready {
      state = .ready
      statusText = "Interactive app ready."
      let input =
        resource?.toolInput?.mcpObject.map { JSONValue.object(["arguments": .object($0)]) }
        ?? .object([:])
      let result = McpAppWire.initialToolResult(resource?.toolResult)
      launch("initialized") { [weak self] in
        await self?.sendNotification("ui/notifications/tool-input", params: input)
        await self?.sendNotification("ui/notifications/tool-result", params: result)
      }
    } else if method == "ui/notifications/size-changed", let h = params?[mcp: "height"]?.mcpNumber,
      h.isFinite
    {
      requestedHeight = max(160, min(1600, h)).rounded()
      guard sizeTask == nil else { return }
      sizeTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(16))
        guard let self, !Task.isCancelled, self.state != .closed, let h = self.requestedHeight
        else { return }
        self.sizeTask = nil
        self.requestedHeight = nil
        self.height = h
        await self.sendNotification(
          "ui/notifications/host-context-changed", params: self.environment.context(height: h))
      }
    }
  }
  func updateEnvironment(_ environment: McpHostEnvironment) async {
    self.environment = environment
    guard state == .ready else { return }
    await sendNotification(
      "ui/notifications/host-context-changed", params: environment.context(height: height))
  }
  /// Explicit native Retry only renews access. A new app request always obtains new consent;
  /// the old confirmed request is never retained or replayed, even after successful renewal.
  func renewAccessForRetry() async throws {
    try assertActive()
    guard retryRequiresConsent else { return }
    try await gateway.renew()
    try assertActive()
    retryRequiresConsent = false
    statusText = "Interactive app ready."
  }
  private func reply(_ id: McpRpcID, result: JSONValue) async {
    await send(.object(["jsonrpc": .string("2.0"), "id": id.value, "result": result]))
  }
  private func reply(_ id: McpRpcID, failure: McpBridgeFailure) async {
    await send(
      .object([
        "jsonrpc": .string("2.0"), "id": id.value,
        "error": .object([
          "code": .number(Double(failure.code)),
          "message": .string(String(failure.message.prefix(500))),
        ]),
      ]))
  }
  private func sendNotification(_ method: String, params: JSONValue) async {
    await send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
  }
  private func send(_ value: JSONValue) async {
    guard state != .closed, let host else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      try await host.sendEnvelope(encoder.encode(value))
    } catch { close(reason: "The app bridge stopped. Reopen to try again.") }
  }
  func teardown() async {
    guard state != .closed, state != .tearingDown else { return }
    state = .tearingDown
    cancelOperations()
    let id = McpRpcID(.string("host-teardown:" + UUID().uuidString))!
    teardownID = id
    await withCheckedContinuation { waiter in
      teardownWaiter = waiter
      teardownTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        self?.close(reason: "The interactive app closed. Reopen to load it again.")
      }
      launch("teardown") { [weak self] in
        await self?.send(
          .object([
            "jsonrpc": .string("2.0"), "id": id.value, "method": .string("ui/resource-teardown"),
            "params": .object([:]),
          ]))
      }
    }
  }
  private func cancelOperations() {
    for operation in operations.values { operation.cancel() }
    operations.removeAll()
    inFlight = 0
    sizeTask?.cancel()
    sizeTask = nil
    requestedHeight = nil
    if pendingConsent {
      pendingConsent = false
      consent.cancel()
    }
  }
  func close(reason: String = "The interactive app closed. Reopen to load it again.") {
    guard state != .closed else { return }
    state = .closed
    statusText = reason
    cancelOperations()
    teardownTask?.cancel()
    teardownTask = nil
    teardownID = nil
    let waiter = teardownWaiter
    teardownWaiter = nil
    gateway.onInvalidation = nil
    gateway.close()
    resource = nil
    host?.close()
    waiter?.resume()
  }
  isolated deinit {
    for operation in operations.values { operation.cancel() }
    sizeTask?.cancel()
    teardownTask?.cancel()
    consent.cancel()
    gateway.onInvalidation = nil
    gateway.close()
    host?.close()
    teardownWaiter?.resume()
  }
}
