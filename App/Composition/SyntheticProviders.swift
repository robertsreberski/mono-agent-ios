// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Fictional, per-instance provider scenarios. No request can reach a console or vendor.
  enum ProviderFixture {
    static let date = "2030-01-02T12:00:00.000Z"
    static func status(_ scenario: StoreScenario) throws -> ProviderAuthStatusSnapshot {
      var value: ProviderAuthStatusSnapshot = try AgentSettingsFixture.decode(
        #"{"schema":"mono-agent.provider-auth.v1","generatedAt":"2030-01-02T12:00:00.000Z","providers":[{"providerId":"openai-codex","label":"Codex","usages":[],"state":"present","source":"stored","credentialType":"oauth","verification":"verified_by_account_request","methods":[{"authType":"oauth","strategy":"device_code","label":"Device code","recommended":true},{"authType":"oauth","strategy":"paste_back","label":"Browser paste-back","recommended":false}]},{"providerId":"anthropic","label":"Claude","usages":[],"state":"missing","verification":"not_verified","methods":[{"authType":"api_key","strategy":"api_key_prompt","label":"API key","recommended":true}]},{"providerId":"openai","label":"OpenAI","usages":[],"state":"present","source":"stored","credentialType":"oauth","verification":"not_verified","methods":[{"authType":"oauth","strategy":"paste_back","label":"ChatGPT sign-in","recommended":true},{"authType":"api_key","strategy":"api_key_prompt","label":"API key","recommended":false}]}]}"#
      )
      if [.providerAuthSecret, .providerAuthSelect].contains(scenario) {
        if scenario == .providerAuthSelect {
          value.providers[1].methods = try AgentSettingsFixture.decode(
            #"[{"authType":"oauth","strategy":"provider_prompt","label":"Provider sign-in","recommended":true}]"#
          )
        }
        value.providers.swapAt(0, 1)
      }
      return value
    }
    static func usage(stale: Bool = false) throws -> ProviderUsageSnapshot {
      try AgentSettingsFixture.decode(
        #"{"schema":"mono-agent.provider-usage.v1","providers":[{"providerId":"openai-codex","label":"Codex","plan":"Plus","fetchedAt":"2030-01-02T11:30:00.000Z","stale":\#(stale),"windows":[{"kind":"session","label":"Session","usedPercent":38,"periodMs":18000000,"resetsAt":"2030-01-02T14:00:00.000Z"},{"kind":"weekly","label":"Weekly","usedPercent":96,"periodMs":604800000,"resetsAt":"2030-01-06T11:30:00.000Z"}]},{"providerId":"anthropic","label":"Claude","fetchedAt":"2030-01-02T11:30:00.000Z","stale":false,"windows":[{"kind":"session","label":"Session","usedPercent":18,"periodMs":18000000,"resetsAt":"2030-01-02T14:30:00.000Z"}]}]}"#
      )
    }
    static func session(
      providerID: String, authType: String, strategy: String, scenario: StoreScenario
    ) throws -> ProviderAuthSessionSnapshot {
      var session: ProviderAuthSessionSnapshot = try AgentSettingsFixture.decode(
        #"{"schema":"mono-agent.provider-auth-session.v1","id":"synthetic-auth-one","providerId":"openai-codex","authType":"oauth","strategy":"device_code","state":"awaiting_user","createdAt":"2030-01-02T12:00:00.000Z","updatedAt":"2030-01-02T12:00:00.000Z","expiresAt":"2030-01-02T12:10:00.000Z","progress":"Waiting for authentication…"}"#
      )
      session.providerId = providerID
      session.authType = authType
      session.strategy = strategy
      if scenario == .providerAuthManualCode && strategy == "device_code" {
        session.state = "failed"
        session.progress = nil
        session.error = try AgentSettingsFixture.decode(
          #"{"code":"device_code_unavailable","message":"Device sign-in is unavailable. Use browser paste-back."}"#
        )
        return session
      }
      switch scenario {
      case .providerAuthDeviceCode:
        session.authUrl = try AgentSettingsFixture.decode(
          #"{"url":"https://auth.example.net/sign-in","instructions":"Sign in in your browser, then return here."}"#
        )
        session.deviceCode = try AgentSettingsFixture.decode(
          #"{"verificationUri":"https://auth.example.net/device","userCode":"FLOCK-2048"}"#)
      case .providerAuthSecret:
        session.state = "awaiting_input"
        session.prompt = try AgentSettingsFixture.decode(
          #"{"id":"secret-one","type":"secret","message":"Enter your API key","placeholder":"API key"}"#
        )
      case .providerAuthSelect:
        session.state = "awaiting_input"
        session.prompt = try AgentSettingsFixture.decode(
          #"{"id":"select-one","type":"select","message":"Choose an account region","options":[{"id":"north","label":"North region"},{"id":"south","label":"South region"}]}"#
        )
      default:
        session.state = "awaiting_input"
        session.prompt = try AgentSettingsFixture.decode(
          #"{"id":"manual-one","type":"manual_code","message":"Paste the browser authorization code","placeholder":"Authorization code"}"#
        )
        session.authUrl = try AgentSettingsFixture.decode(
          #"{"url":"https://auth.example.net/authorize","instructions":"Open the authentication page, then paste the returned code here."}"#
        )
      }
      return session
    }
    static func check(completed: Bool) throws -> ProviderAuthCheckSessionSnapshot {
      try AgentSettingsFixture.decode(
        #"{"schema":"mono-agent.provider-auth-check.v1","id":"synthetic-check-one","state":"\#(completed ? "completed" : "running")","createdAt":"2030-01-02T12:00:00.000Z","updatedAt":"2030-01-02T12:00:00.000Z","expiresAt":"2030-01-02T12:10:00.000Z","results":[{"providerId":"openai-codex","label":"Codex","state":"\#(completed ? "passed" : "running")"},{"providerId":"anthropic","label":"Claude","state":"quota_limited"},{"providerId":"openai","label":"OpenAI","state":"network_failed"}]}"#
      )
    }
  }

  actor ProviderScript {
    let scenario: StoreScenario
    private var session: ProviderAuthSessionSnapshot?
    private var check: ProviderAuthCheckSessionSnapshot?
    private var sessionNumber = 0
    private var authenticated = false
    private var checked = false
    init(_ scenario: StoreScenario) { self.scenario = scenario }
    private func encoded<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
      HTTPResponse(data: try JSONEncoder().encode(value), status: status)
    }
    func response(_ request: URLRequest) throws -> HTTPResponse? {
      let base = "/api/v1/agents/" + AgentSettingsFixture.atlas
      let method = request.httpMethod ?? "GET"
      let path = request.url?.path ?? ""
      switch (method, path) {
      case ("GET", base + "/provider-auth"):
        var value = try ProviderFixture.status(scenario)
        if authenticated {
          value.providers[0].state = "present"
          value.providers[0].verification = "verified_by_account_request"
        }
        if checked { value.providers[0].verification = "verified_by_live_request" }
        return try encoded(value)
      case ("GET", base + "/provider-usage"), ("POST", base + "/provider-usage/refresh"):
        return try encoded(ProviderFixture.usage(stale: scenario == .providerUsageStale))
      case ("POST", base + "/provider-auth/sessions"):
        let input = try JSONDecoder().decode(ApiAuthStart.self, from: request.httpBody ?? Data())
        guard
          try ProviderFixture.status(scenario).providers.contains(where: { provider in
            provider.providerId == input.providerId
              && provider.methods.contains {
                $0.strategy == input.strategy && $0.authType == input.authType
              }
          })
        else { throw URLError(.resourceUnavailable) }
        session = try ProviderFixture.session(
          providerID: input.providerId, authType: input.authType, strategy: input.strategy,
          scenario: scenario)
        sessionNumber += 1
        session?.id = "synthetic-auth-\(sessionNumber)"
        return try encoded(session!, status: 201)
      case ("GET", base + "/provider-auth/sessions/" + (session?.id ?? "")):
        guard let session else { throw URLError(.resourceUnavailable) }
        return try encoded(session)
      case ("POST", base + "/provider-auth/sessions/" + (session?.id ?? "") + "/input"):
        // Consume without retaining input or adding it to any diagnostic.
        let input = try JSONDecoder().decode(ApiAuthInput.self, from: request.httpBody ?? Data())
        guard session?.prompt?.id == input.promptId, !input.value.isEmpty else {
          throw URLError(.resourceUnavailable)
        }
        if session?.prompt?.type == "select" {
          session?.prompt = try AgentSettingsFixture.decode(
            #"{"id":"text-two","type":"text","message":"Enter an account label","placeholder":"Account label"}"#
          )
          return try encoded(session!)
        }
        session?.state = "succeeded"
        session?.prompt = nil
        session?.authUrl = nil
        session?.deviceCode = nil
        session?.progress = "Authentication succeeded."
        authenticated = true
        return try encoded(session!)
      case ("DELETE", base + "/provider-auth/sessions/" + (session?.id ?? "")):
        session?.state = "cancelled"
        session?.prompt = nil
        session?.authUrl = nil
        session?.deviceCode = nil
        return HTTPResponse(data: Data(), status: 204)
      case ("POST", base + "/provider-auth/checks"):
        _ = try JSONDecoder().decode(ApiAuthCheckStart.self, from: request.httpBody ?? Data())
        check = try ProviderFixture.check(completed: false)
        return try encoded(check!, status: 201)
      case ("GET", base + "/provider-auth/checks/synthetic-check-one"):
        guard check != nil else { throw URLError(.resourceUnavailable) }
        check = try ProviderFixture.check(completed: true)
        checked = true
        return try encoded(check!)
      case ("DELETE", base + "/provider-auth/checks/synthetic-check-one"):
        check?.state = "cancelled"
        return HTTPResponse(data: Data(), status: 204)
      default:
        if path.contains("/provider-auth") || path.contains("/provider-usage") {
          throw URLError(.resourceUnavailable)
        }
        return nil
      }
    }
  }
#endif
