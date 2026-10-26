// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore

  /// Fictional agent-settings and notifications scenarios. Atlas Research gets a two-route
  /// shortlist, two advertised providers with catalogs (one paged), and settings capabilities.
  /// Every value is synthetic; the console is never contacted.
  enum AgentSettingsFixture {
    static let atlas = DashboardFixture.atlas
    /// The same fictional host over HTTP, for the insecure notifications explanation.
    static let insecureEndpoint = try! ConsoleEndpoint("http://console.example.ts.net")

    static func decode<T: Decodable>(_ text: String, as: T.Type = T.self) throws -> T {
      try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    static let configured =
      #"{"config":{"model":"sample:large","effort":"medium"},"override":null,"effective":{"model":"sample:large","effort":"medium","modelSource":"config","effortSource":"config"}}"#
    static let overridden =
      #"{"config":{"model":"sample:large","effort":"medium"},"override":{"model":"grove:fast","effort":"low"},"effective":{"model":"grove:fast","effort":"low","modelSource":"override","effortSource":"override"}}"#

    static func agent(_ value: WebAgentSummary, scenario: StoreScenario) throws -> WebAgentSummary {
      guard value.sourceId == atlas else { return value }
      var agent = value
      agent.generation = "generation-1"
      agent.models = ["sample:large", "sample:small"]
      agent.defaultModel = "sample:large"
      agent.defaultEffort = "medium"
      agent.modelOptions = try decode(
        #"{"sample:large":{"label":"Sample Large","effortLevels":["low","medium","high"],"supportsContext1M":true,"contextWindow":200000},"sample:small":{"label":"Sample Small","effortLevels":["low","medium"]}}"#
      )
      agent.providers = try decode(
        #"[{"id":"sample","label":"Sample","configured":true},{"id":"grove","label":"Grove","configured":true}]"#
      )
      agent.supportsAttachments = true
      agent.supportsManualCompaction = true
      agent.supportsProviderAuth = true
      agent.supportsProviderUsage = true
      agent.supportsProviderUsageRefresh = scenario.isProviders
      agent.supportsProviderAuthChecks = scenario.isProviders
      agent.restart = try decode(#"{"supported":true}"#)
      agent.cron = try decode(#"{"read":true,"actions":true}"#)
      agent.runSettings = try decode(scenario == .agentSettingsDegraded ? overridden : configured)
      switch scenario {
      case .agentSettingsOffline: agent.status = "offline"
      case .agentSettingsDegraded: agent.status = "degraded"
      default: agent.status = "online"
      }
      return agent
    }

    static func bootstrap(_ scenario: StoreScenario, theme: String) throws -> ApiBootstrap {
      var value = try DashboardFixture.bootstrap(theme: theme)
      value.agents = try value.agents.map { try agent($0, scenario: scenario) }
      return value
    }

    /// The cached snapshot carries the same agent so the first frame already matches.
    static func prepare(
      _ scenario: StoreScenario, store: ConsoleStore, repository: any ConsoleRepository,
      theme: String
    ) async throws {
      try await DashboardFixture.prepare(store, repository: repository, empty: false, theme: theme)
      var cache = try await repository.loadCache(store.namespace)
      cache.revision += 1
      cache.bootstrap = try bootstrap(scenario, theme: theme)
      try await repository.saveCache(cache, namespace: store.namespace)
    }

    static func catalogPage(provider: String, cursor: String?) -> String {
      switch (provider, cursor) {
      case ("sample", _):
        #"{"models":[{"id":"large","name":"Sample Large","provider":"sample","providerLabel":"Sample","effortLevels":["low","medium","high"],"supportsContext1M":true,"contextWindow":200000},{"id":"max","name":"Sample Max","provider":"sample","providerLabel":"Sample","effortLevels":["medium","high","max"]}],"nextCursor":null,"truncated":false}"#
      case ("grove", nil):
        #"{"models":[{"id":"fast","name":"Grove Fast","provider":"grove","providerLabel":"Grove","effortLevels":["low","medium"]}],"nextCursor":"grove-2","truncated":false}"#
      case ("grove", _):
        #"{"models":[{"id":"deep","name":"Grove Deep","provider":"grove","providerLabel":"Grove","reasoningMode":"toggle"}],"nextCursor":null,"truncated":false}"#
      default:
        #"{"models":[],"nextCursor":null,"truncated":false}"#
      }
    }
  }

  /// Per-instance, fail-closed console for the settings scenarios: pin and run-defaults writes
  /// change this instance's agent; `agent-settings-save-error` refuses every defaults write.
  actor AgentSettingsScript {
    let scenario: StoreScenario
    private var agent: WebAgentSummary?
    private(set) var writes = 0

    init(_ scenario: StoreScenario) { self.scenario = scenario }

    private func current(theme: String) throws -> WebAgentSummary {
      if let agent { return agent }
      let value = try AgentSettingsFixture.bootstrap(scenario, theme: theme).agents.first {
        $0.sourceId == AgentSettingsFixture.atlas
      }
      guard let value else { throw URLError(.resourceUnavailable) }
      agent = value
      return value
    }

    private func encoded(_ agent: WebAgentSummary) throws -> HTTPResponse {
      let json: JSONValue = .object([
        "agent": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(agent))
      ])
      return HTTPResponse(data: try JSONEncoder().encode(json))
    }

    func response(_ request: URLRequest, theme: String) throws -> HTTPResponse {
      guard let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { throw URLError(.badURL) }
      let query = Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first })
      let base = "/api/v1/agents/" + AgentSettingsFixture.atlas
      switch (request.httpMethod ?? "GET", url.path) {
      case ("GET", "/api/v1/bootstrap"):
        var value = try AgentSettingsFixture.bootstrap(scenario, theme: theme)
        let atlas = try current(theme: theme)
        value.agents = value.agents.map { $0.sourceId == atlas.sourceId ? atlas : $0 }
        return HTTPResponse(data: try JSONEncoder().encode(value))
      case ("GET", base + "/restart"):
        return HTTPResponse(data: Data(#"{"operation":null}"#.utf8))
      case ("GET", base + "/provider-auth"):
        return HTTPResponse(
          data: Data(
            #"{"schema":"mono-agent.provider-auth.v1","generatedAt":"2030-01-02T12:00:00Z","providers":[]}"#
              .utf8))
      case ("GET", base + "/provider-usage"):
        return HTTPResponse(
          data: Data(#"{"schema":"mono-agent.provider-usage.v1","providers":[]}"#.utf8))
      case ("GET", base + "/models"):
        return HTTPResponse(
          data: Data(
            AgentSettingsFixture.catalogPage(
              provider: query["provider"] ?? "", cursor: query["cursor"]
            ).utf8))
      case ("PATCH", base):
        writes += 1
        var value = try current(theme: theme)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        if case .object(let fields) = body, case .bool(let pinned)? = fields["pinned"] {
          value.pinned = pinned
        }
        agent = value
        return try encoded(value)
      case ("PUT", base + "/run-defaults"):
        writes += 1
        if scenario == .agentSettingsSaveError {
          return HTTPResponse(data: Data(#"{"error":"unavailable"}"#.utf8), status: 503)
        }
        var value = try current(theme: theme)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        guard case .object(let fields) = body else { throw URLError(.cannotParseResponse) }
        func text(_ key: String) -> String? {
          if case .string(let text)? = fields[key] { return text }
          return nil
        }
        var override = RunDefaultsJSON(model: text("model"), effort: text("effort"))
        if case .bool(let context)? = fields["context1M"] { override.context1M = context }
        value.runSettings = try AgentSettingsFixture.decode(override.settings(value))
        agent = value
        return try encoded(value)
      case ("DELETE", base + "/run-defaults"):
        writes += 1
        var value = try current(theme: theme)
        value.runSettings = try AgentSettingsFixture.decode(AgentSettingsFixture.configured)
        agent = value
        return try encoded(value)
      default:
        guard
          let response = try DashboardFixture.response(for: request, empty: false, theme: theme)
        else { throw URLError(.resourceUnavailable) }
        return response
      }
    }
  }

  /// The run-settings JSON a saved override produces, with config fallbacks for blank fields.
  private struct RunDefaultsJSON {
    var model: String?
    var effort: String?
    var context1M: Bool?
    func settings(_ agent: WebAgentSummary) -> String {
      let config = agent.runSettings.config
      func quoted(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
      let context = context1M.map { ",\"context1M\":\($0)" } ?? ""
      return
        #"{"config":{"model":\#(quoted(config.model)),"effort":\#(quoted(config.effort))},"override":{"model":\#(quoted(model)),"effort":\#(quoted(effort))\#(context)},"effective":{"model":\#(quoted(model ?? config.model)),"effort":\#(quoted(effort ?? config.effort)),"modelSource":"\#(model == nil ? "config" : "override")","effortSource":"\#(effort == nil ? "config" : "override")"}}"#
    }
  }
#endif
