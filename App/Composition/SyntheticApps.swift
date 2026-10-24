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
    private var expireTool = false
    func expireNextTool() { expireTool = true }
    private let longLink = ProcessInfo.processInfo.arguments.contains("--mcp-long-link")
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
      let root = "/api/v1/threads/\(DashboardFixture.openThreadID)/messages/mcp-message/mcp-apps/"
      guard path.hasPrefix(root), let id = path.dropFirst(root.count).split(separator: "/").first
      else { throw URLError(.resourceUnavailable) }
      let base = root + id
      var published = try Self.part(scenario)
      published.id = String(id)
      if path == base + "/access" {
        var part = published
        part.resourceUrl = base + "?expires=1&token=fictional-garden"
        part.bridgeUrl = base + "/requests?expires=1&token=fictional-garden"
        return try encoded(JSONValue.object(["part": try TranscriptFixture.json(part)]))
      }
      if path == base {
        var resource = try McpGardenFixture.resource()
        resource.app = published
        if longLink {
          resource.html = resource.html.replacingOccurrences(
            of: "https://garden.example/guide",
            with: "https://garden.example/" + String(repeating: "a", count: 7980)
          )
          .replacingOccurrences(
            of: "<style>",
            with:
              "<style>h1,#status,button{display:none}button:nth-of-type(3){display:inline-block}")
        }
        return try encoded(resource)
      }
      if path == base + "/requests", let bytes = request.httpBody {
        let body = try JSONDecoder().decode(ApiMcpAppRequest.self, from: bytes)
        await diagnostics.record(body.method)
        let result: JSONValue
        switch body.method {
        case "tools/call":
          if expireTool {
            expireTool = false
            return .init(
              data: Data(
                #"{"error":{"code":"reply_access_expired","message":"Synthetic access expired"}}"#
                  .utf8), status: 401)
          }
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
