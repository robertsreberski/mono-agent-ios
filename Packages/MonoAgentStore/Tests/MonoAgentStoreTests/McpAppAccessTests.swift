// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@Suite("MCP ephemeral Store access")
@MainActor
struct McpAppAccessTests {
  private let base = "/api/v1/threads/thread-example/messages/message-example/mcp-apps/garden"
  private func part(_ token: String? = nil) throws -> McpAppPart {
    var part: McpAppPart = try decode(
      #"{"type":"mcp_app","id":"garden","invocationId":"invocation","connectionId":"connection","serverName":"garden","toolName":"plan","resourceUri":"ui://garden/planner","mediaType":"text/html;profile=mcp-app","protocolVersion":"2026-01-26"}"#
    )
    if let token {
      part.resourceUrl = base + "?expires=1&token=" + token
      part.bridgeUrl = base + "/requests?expires=1&token=" + token
    }
    return part
  }
  private func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
  private func access(_ token: String = "fictional-capability") throws -> HTTPResponse {
    try response(JSONValue.object(["part": try json(part(token))]))
  }
  private func resource() throws -> HTTPResponse {
    try response(
      JSONValue.object([
        "app": try json(part()), "html": .string("<p>fictional-ephemeral-html</p>"),
        "connected": .bool(true),
      ]))
  }
  private func live() async throws -> Harness {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    var message = try sampleMessage()
    message.parts = [.mcpApp(try part())]
    try h.seed(messages: [message])
    h.store.selectedThreadID = "thread-example"
    h.store.connection = .live
    await h.transport.set(base + "/access", [.response(try access())])
    await h.transport.set(base, [.response(try resource())])
    return h
  }
  private func load(_ h: Harness) async throws -> McpAppAccess {
    try await h.store.loadMcpApp(
      threadID: "thread-example", messageID: "message-example", partID: "garden")
  }

  @Test func compositionLoadsWithoutExposingOrPersistingCapabilities() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    let session = try await load(h)
    #expect(session.profileID == h.store.profile.id)
    #expect(session.resource?.html == "<p>fictional-ephemeral-html</p>")
    #expect(session.resource?.app.resourceUrl == nil && session.resource?.app.bridgeUrl == nil)
    #expect(await h.transport.count(base + "/access", method: "POST") == 1)
    #expect(await h.transport.count(base, method: "GET") == 1)
    h.store.closeMcpApp(session)
    #expect(session.resource == nil && session.current == nil && session.isClosed)
    await h.store.stop()
  }

  @Test func cachedTranscriptsStripBothMcpCapabilityUrls() throws {
    var message = try sampleMessage()
    message.parts = [.mcpApp(try part("fictional-private-token"))]
    let sanitized = try CacheSanitizer.sanitize(message)
    let data = try JSONEncoder().encode(sanitized)
    let text = String(decoding: data, as: UTF8.self)
    #expect(
      !text.contains("resourceUrl") && !text.contains("bridgeUrl")
        && !text.contains("fictional-private-token"))
    guard case .mcpApp(let saved) = sanitized.parts[0] else {
      Issue.record("Missing MCP identity")
      return
    }
    #expect(saved.invocationId == "invocation" && saved.connectionId == "connection")
  }

  @Test func offlineBackgroundStoppedAndLateResultsCannotPublish() async throws {
    let offline = Harness()
    await #expect(throws: McpAppStoreError.unavailable) { try await load(offline) }
    try? FileManager.default.removeItem(at: offline.directory)
    for change in 0..<5 {
      let h = try await live()
      await h.transport.set(base + "/access", [.paused])
      let read = Task { try await load(h) }
      await eventually { await h.transport.pauseCount() == 1 }
      if change == 0 { await h.store.scenePhaseChanged(.background) }
      if change == 1 {
        h.store.selection &+= 1
        h.store.invalidateMcpApps()
      }
      if change == 2 { await h.store.stop() }
      if change == 3 { read.cancel() }
      if change == 4 {
        var changed = try part()
        changed.invocationId = "replaced-invocation"
        h.store.conversations["thread-example"]?.record.messages[0].parts = [.mcpApp(changed)]
      }
      await h.transport.release(try access())
      await #expect(throws: CancellationError.self) { _ = try await read.value }
      #expect(h.store.mcpApps.isEmpty)
      await h.store.stop()
      try? FileManager.default.removeItem(at: h.directory)
    }
  }

  @Test func explicitRenewalWinsAnOlderInFlightResponse() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    let session = try await load(h)
    await h.transport.set(base + "/requests", [.paused])
    let read = Task {
      try await h.store.requestMcpApp(.init(method: "resources/read"), session: session)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(base + "/access", [.response(try access("renewed"))])
    try await h.store.renewMcpApp(session)
    await h.transport.release(try response(JSONValue.object(["result": .object([:])])))
    await #expect(throws: CancellationError.self) { _ = try await read.value }
    #expect(session.current?.bridgeUrl?.contains("token=renewed") == true)
    #expect(!session.isClosed)
    await h.store.stop()
  }

  @Test func expiredConfirmedRequestIsNeverReplayedAndNeedsExplicitRenewal() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    let session = try await load(h)
    await h.transport.set(
      base + "/requests",
      [
        .response(
          .init(
            data: Data(#"{"error":{"code":"reply_access_expired","message":"Expired"}}"#.utf8),
            status: 410))
      ])
    await #expect(throws: APIError.self) {
      try await h.store.requestMcpApp(
        .init(method: "tools/call", confirmed: true), session: session)
    }
    #expect(session.retryRequiresConsent)
    #expect(await h.transport.count(base + "/requests", method: "POST") == 1)
    #expect(await h.transport.count(base + "/access", method: "POST") == 1)
    await h.store.stop()
    #expect(session.isClosed && session.resource == nil)
  }
}
