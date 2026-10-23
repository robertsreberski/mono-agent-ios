// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgentKit

@Suite("MCP capability access")
struct McpAppAccessTests {
  private let reference = ReplyPartReference(threadId: "t", messageId: "m", partId: "p")
  private let base = "/api/v1/threads/t/messages/m/mcp-apps/p"
  private func part(_ token: String = "fictional") -> McpAppPart {
    McpAppPart(
      type: "mcp_app", id: "p", invocationId: "invocation", connectionId: "connection",
      serverName: "garden", toolName: "plan", resourceUri: "ui://garden/planner",
      mediaType: "text/html;profile=mcp-app", protocolVersion: "2026-01-26",
      resourceUrl: base + "?expires=1&token=" + token,
      bridgeUrl: base + "/requests?expires=1&token=" + token)
  }
  private func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
    .init(data: try JSONEncoder().encode(value))
  }
  private func resource(_ part: McpAppPart) -> ApiMcpAppResource {
    .init(app: part, html: "<p>garden</p>", connected: true)
  }
  private var expired: HTTPResponse {
    .init(
      data: Data(#"{"error":{"code":"reply_access_expired","message":"Expired"}}"#.utf8),
      status: 410)
  }

  @Test func renewalValidatesEveryPublishedFieldAndBothCapabilities() async throws {
    let published = part()
    for key in [
      "type", "id", "invocationId", "connectionId", "serverName", "toolName", "resourceUri",
      "mediaType", "protocolVersion", "title", "description", "expiresAt",
    ] {
      var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: JSONEncoder().encode(published))
      object[key] = .string("different")
      let changed = try JSONDecoder().decode(McpAppPart.self, from: JSONEncoder().encode(object))
      let transport = ScriptedTransport([.response(try response(ApiMcpAppAccess(part: changed)))])
      let service = CapabilityService(
        endpoint: Scenario.endpoint,
        api: APIClient(endpoint: Scenario.endpoint, transport: transport))
      await #expect(throws: McpAppAccessError.identityMismatch) {
        try await service.renewMcpAppAccess(published, reference: reference)
      }
    }
    for route in 0..<3 {
      var changed = published
      if route == 0 {
        changed.resourceUrl =
          base.replacingOccurrences(of: "/t/", with: "/other/") + "?expires=1&token=fictional"
      }
      if route == 1 { changed.bridgeUrl = "/api/v1/uploads/p/content?expires=1&token=fictional" }
      if route == 2 { changed.bridgeUrl = base + "/requests?expires=1&token=different" }
      let transport = ScriptedTransport([.response(try response(ApiMcpAppAccess(part: changed)))])
      await #expect(throws: CapabilityError.invalidURL) {
        try await CapabilityService(
          endpoint: Scenario.endpoint,
          api: APIClient(endpoint: Scenario.endpoint, transport: transport)
        )
        .renewMcpAppAccess(published, reference: reference)
      }
    }
  }

  @Test func loadReturnsRenewedAccessAndRejectsSubstitutedResource() async throws {
    let renewed = part("renewed")
    let transport = ScriptedTransport([
      .response(expired),
      .response(try response(ApiMcpAppAccess(part: renewed))),
      .response(try response(resource(renewed))),
    ])
    let service = CapabilityService(
      endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: transport)
    )
    let loaded = try await service.loadMcpApp(part(), reference: reference)
    #expect(loaded.access == renewed)
    #expect(await transport.requests.map(\.httpMethod) == ["GET", "POST", "GET"])
    var wrong = renewed
    wrong.connectionId = "different"
    let substituted = ScriptedTransport([.response(try response(resource(wrong)))])
    await #expect(throws: McpAppAccessError.identityMismatch) {
      try await CapabilityService(
        endpoint: Scenario.endpoint,
        api: APIClient(endpoint: Scenario.endpoint, transport: substituted)
      )
      .loadMcpApp(part(), reference: reference)
    }
  }

  @Test func onlyResourceReadRenewsAndRetriesAndOnlyOnce() async throws {
    for method in ["resources/read", "tools/call", "ui/open-link", "ui/update-model-context"] {
      let transport = ScriptedTransport([
        .response(expired), .response(try response(ApiMcpAppAccess(part: part("renewed")))),
        .response(expired),
      ])
      let service = CapabilityService(
        endpoint: Scenario.endpoint,
        api: APIClient(endpoint: Scenario.endpoint, transport: transport))
      await #expect(throws: APIError.self) {
        try await service.requestMcpApp(
          .init(method: method, confirmed: true), published: part(), access: part(),
          reference: reference)
      }
      #expect(await transport.requests.count == (method == "resources/read" ? 3 : 1))
    }
  }

  @Test func boundedResourceAndResultAcceptExactCapRejectOneByteOver() async throws {
    let query = ApiCapabilityQuery(expires: "1", token: "fictional")
    for isResource in [true, false] {
      let limit = isResource ? 4 * 1024 * 1024 : 1024 * 1024
      let prefix =
        isResource ? try JSONEncoder().encode(resource(part())) : Data(#"{"result":{}}"#.utf8)
      for extra in [0, 1] {
        let data = prefix + Data(repeating: 32, count: limit - prefix.count + extra)
        let transport = ScriptedTransport([.response(.init(data: data))])
        let api = APIClient(endpoint: Scenario.endpoint, transport: transport)
        let operation: @Sendable () async throws -> Void = {
          if isResource {
            _ = try await api.mcpAppResource(
              threadId: "t", messageId: "m", partId: "p", query: query, etag: nil)
          } else {
            _ = try await api.mcpAppRequest(
              threadId: "t", messageId: "m", partId: "p", query: query,
              body: .init(method: "resources/read"))
          }
        }
        if extra == 0 {
          try await operation()
        } else {
          await #expect(throws: ReplyContentError.tooLarge) { try await operation() }
        }
      }
    }
  }
}
