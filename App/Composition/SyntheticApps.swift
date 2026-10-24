// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import Observation
  import SwiftUI

  @MainActor @Observable final class McpUiDiagnostics {
    let interactive: Bool
    private(set) var toolPosts = 0
    private(set) var linkPosts = 0
    init(interactive: Bool) { self.interactive = interactive }
    func record(_ method: String) {
      if method == "tools/call" { toolPosts += 1 }
      if method == "ui/open-link" { linkPosts += 1 }
    }
  }
  extension EnvironmentValues { @Entry var mcpDiagnostics: McpUiDiagnostics? }

  actor McpUiScript {
    let scenario: StoreScenario
    let diagnostics: McpUiDiagnostics
    init(_ scenario: StoreScenario, diagnostics: McpUiDiagnostics) {
      self.scenario = scenario
      self.diagnostics = diagnostics
    }
    static func part(_ scenario: StoreScenario) throws -> McpAppPart {
      var part = try McpGardenFixture.resource().app
      part.title =
        scenario == .conversationMcpLongTitle
        ? "Garden planning canvas with a deliberately long title that still exposes the complete accessible app name"
        : "Garden planner"
      part.serverName = "garden-tools"
      part.toolName = "render_plan"
      return part
    }
    static func messages(_ scenario: StoreScenario) throws -> [WebMessage] {
      var message = try TranscriptFixture.message(id: "mcp-message", role: "assistant", text: "")
      message.parts = [.mcpApp(try part(scenario))]
      return [message]
    }
    private func encoded<T: Encodable>(_ value: T) throws -> HTTPResponse {
      .init(data: try JSONEncoder().encode(value))
    }
    func response(_ request: URLRequest) async throws -> HTTPResponse? {
      guard let path = request.url?.path, path.contains("/mcp-apps/") else { return nil }
      if scenario != .conversationMcpApp {
        return .init(
          data: Data(
            #"{"error":{"code":"mcp_app_unavailable","message":"Synthetic source unavailable"}}"#
              .utf8), status: 409)
      }
      let base =
        "/api/v1/threads/\(DashboardFixture.openThreadID)/messages/mcp-message/mcp-apps/garden"
      if path == base + "/access" {
        var part = try Self.part(scenario)
        part.resourceUrl = base + "?expires=1&token=fictional-garden"
        part.bridgeUrl = base + "/requests?expires=1&token=fictional-garden"
        return try encoded(JSONValue.object(["part": try TranscriptFixture.json(part)]))
      }
      if path == base {
        var resource = try McpGardenFixture.resource()
        resource.app = try Self.part(scenario)
        return try encoded(resource)
      }
      if path == base + "/requests", let bytes = request.httpBody {
        let body = try JSONDecoder().decode(ApiMcpAppRequest.self, from: bytes)
        await diagnostics.record(body.method)
        let result: JSONValue
        switch body.method {
        case "tools/call":
          result = .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string("Garden planned")])
            ]),
            "structuredContent": .object(["calls": .number(Double(await diagnostics.toolPosts))]),
          ])
        case "resources/read": result = .object(["contents": .array([])])
        case "ui/open-link":
          result = .object([
            "allowed": .bool(true), "url": .string("https://garden.example/approved"),
          ])
        case "ui/update-model-context": result = .object(["accepted": .bool(true)])
        default: throw URLError(.resourceUnavailable)
        }
        return try encoded(JSONValue.object(["result": result]))
      }
      throw URLError(.resourceUnavailable)
    }
  }
#endif
