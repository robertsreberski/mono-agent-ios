// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore

  enum AutomationsFixture {
    static let jobID = "sample-digest"
    static let threadID = "thread-automation"
    static func overview(_ scenario: StoreScenario, enabled: Bool = true) throws -> WebCronOverview
    {
      var value: WebCronOverview = try AgentSettingsFixture.decode(
        #"{"generatedAt":"2030-01-02T12:00:00Z","actionsEnabled":true,"jobs":[{"jobId":"sample-digest","expression":"0 9 * * *","timezone":"Europe/Paris","conversationId":"session-sample","configured":true,"declaredEnabled":false,"effectiveEnabled":true,"nextRunAt":"2099-01-03T09:00:00Z","health":"healthy","threadId":"thread-automation","lastRun":{"runId":"run-sample","jobId":"sample-digest","sequence":4,"trigger":"scheduled","status":"succeeded","scheduledAt":"2030-01-02T09:00:00Z","orderedAt":"2030-01-02T09:00:00Z","completedAt":"2030-01-02T09:01:00Z","eventCount":0,"projection":"summary"}},{"jobId":"sample-cleanup","expression":"0 3 * * 0","timezone":"UTC","conversationId":"session-cleanup","configured":true,"declaredEnabled":true,"effectiveEnabled":false,"health":"warning","threadId":"thread-cleanup"},{"jobId":"retired-sample","conversationId":"session-retired","configured":false,"declaredEnabled":false,"effectiveEnabled":false,"health":"unknown","threadId":"thread-retired"}]}"#
      )
      value.jobs[0].effectiveEnabled = enabled
      if scenario == .automationsEmpty { value.jobs = [] }
      if scenario == .automationsDegraded {
        value.degradedReason = "The sample scheduler cannot provide current state."
        value.jobsTruncated = true
      }
      return value
    }
    static func thread() throws -> WebThread {
      var value = try DashboardFixture.threads(source: AgentSettingsFixture.atlas)[0]
      value.id = threadID
      value.sourceId = AgentSettingsFixture.atlas
      value.title = jobID
      value.projectId = nil
      value.projectName = nil
      value.tagIds = []
      value.canSend = false
      value.canUpload = false
      value.runState.status = "idle"
      value.trigger = try AgentSettingsFixture.decode(#"{"kind":"cron","jobId":"sample-digest"}"#)
      return value
    }
    static func message() throws -> WebMessage {
      try AgentSettingsFixture.decode(
        #"{"id":"message-automation","threadId":"thread-automation","turnId":"turn-automation","role":"assistant","parts":[{"type":"telemetry","event":"cron_run","data":{"runId":"run-sample","jobId":"sample-digest","sequence":4,"status":"succeeded","trigger":"scheduled","orderedAt":"2030-01-02T09:00:00Z"}},{"type":"text","text":"The fictional digest is ready.\n\n```swift\nlet sample = \"Flockbox\"\nprint(sample)\n```\n\nAll sample checks completed."}],"attachments":[],"createdAt":"2030-01-02T09:01:00Z","updatedAt":"2030-01-02T09:01:00Z","status":"complete","seq":1}"#
      )
    }
    static func bootstrap(_ scenario: StoreScenario, theme: String) throws -> ApiBootstrap {
      var value = try AgentSettingsFixture.bootstrap(scenario, theme: theme)
      if scenario == .automationsOffline,
        let index = value.agents.firstIndex(where: { $0.sourceId == AgentSettingsFixture.atlas })
      {
        value.agents[index].status = "offline"
      }
      return value
    }
    static func prepare(
      _ scenario: StoreScenario, store: ConsoleStore,
      repository: any ConsoleRepository, theme: String
    ) async throws {
      try await AgentSettingsFixture.prepare(
        scenario, store: store, repository: repository, theme: theme)
      var cache = try await repository.loadCache(store.namespace)
      cache.revision += 1
      cache.bootstrap = try bootstrap(scenario, theme: theme)
      cache.automationOverviews = [
        .init(
          sourceID: AgentSettingsFixture.atlas,
          overview: try overview(scenario), savedAt: Date())
      ]
      cache.conversations.append(
        .init(
          thread: try thread(),
          messages: [try scenario.isCronRuns ? CronRunsFixture.message() : message()],
          savedAt: Date()))
      try await repository.saveCache(cache, namespace: store.namespace)
    }
  }
  /// One instance per launch. Unrecognized routes fail closed; no fallback network transport.
  actor AutomationsScript {
    let scenario: StoreScenario
    private var enabled = true
    private var replyCount = 0
    private var replyWaiter: CheckedContinuation<Void, Never>?
    private var canonicalOperation: String?
    func releaseReply() {
      replyWaiter?.resume()
      replyWaiter = nil
    }
    private var keys: [String: String] = [:]
    init(_ scenario: StoreScenario) { self.scenario = scenario }
    func response(_ request: URLRequest, theme: String) async throws -> HTTPResponse {
      let method = request.httpMethod ?? "GET"
      let path = request.url?.path ?? ""
      let base = "/api/v1/agents/" + AgentSettingsFixture.atlas + "/cron"
      func encoded<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(data: try JSONEncoder().encode(value), status: status)
      }
      switch (method, path) {
      case ("GET", "/api/v1/bootstrap"):
        return try encoded(AutomationsFixture.bootstrap(scenario, theme: theme))
      case ("GET", base):
        return try encoded(AutomationsFixture.overview(scenario, enabled: enabled))
      case ("GET", base + "/config-view"):
        return try encoded(
          try AgentSettingsFixture.decode(
            #"{"configView":{"id":"cron","label":"Cron configuration","status":"ready","fields":[{"id":"schedule","label":"Schedule","value":"0 9 * * *","source":"agent config"},{"id":"timezone","label":"Timezone","value":"Europe/Paris","source":"agent config"},{"id":"key","label":"Operator API key","value":"[redacted]","source":"environment","redacted":true}]}}"#,
            as: JSONValue.self))
      case ("POST", base + "/jobs/sample-digest/run"),
        ("POST", base + "/jobs/sample-digest/effective-enabled"):
        guard let data = request.httpBody,
          case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: data),
          case .string(let key) = body["idempotencyKey"]
        else { throw URLError(.badServerResponse) }
        if scenario == .cronConfirm && body["confirmationToken"] != .string("synthetic-cron-token")
        {
          keys[path] = key
          return try encoded(
            try AgentSettingsFixture.decode(
              #"{"kind":"confirmation_required","confirmation":{"token":"synthetic-cron-token","expiresAt":"2099-01-03T12:00:00Z","message":"This sample job may interrupt an active run. Confirm to continue."}}"#,
              as: JSONValue.self), status: 428)
        }
        if scenario == .cronConfirm, keys[path] != key { throw URLError(.badServerResponse) }
        if path.hasSuffix("effective-enabled") {
          guard case .bool(let value) = body["enabled"] else { throw URLError(.badServerResponse) }
          enabled = value
          let job = try AutomationsFixture.overview(scenario, enabled: enabled).jobs[0]
          let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(job))
          return try encoded(
            JSONValue.object([
              "kind": .string("completed"), "value": .object(["job": json]),
              "replayed": .bool(false),
            ]))
        }
        let run = try AutomationsFixture.overview(scenario).jobs[0].lastRun!
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(run))
        return try encoded(
          JSONValue.object([
            "kind": .string("completed"), "value": .object(["run": json]), "replayed": .bool(false),
          ]))
      case ("GET", base + "/jobs/sample-digest/runs"):
        let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
          .first { $0.name == "before" }?.value
        let run = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(CronRunsFixture.run(before == nil ? 4 : 3)))
        return try encoded(
          JSONValue.object([
            "runs": .array([run]), "nextCursor": before == nil ? .string("older-sample") : .null,
          ]))
      case ("GET", base + "/jobs/sample-digest/runs/run-sample"),
        ("GET", base + "/jobs/sample-digest/runs/run-sample-older"):
        var message = try CronRunsFixture.message(detail: true)
        if path.hasSuffix("-older") {
          message.id = "message-older-run"
          if case .telemetry(var telemetry) = message.parts[0],
            case .object(var fields) = telemetry.data
          {
            fields["runId"] = .string("run-sample-older")
            fields["sequence"] = .number(3)
            telemetry.data = .object(fields)
            message.parts[0] = .telemetry(telemetry)
          }
        }
        return try encoded(["message": message])
      case ("POST", base + "/jobs/sample-digest/runs/run-sample/reply-threads"):
        guard let data = request.httpBody,
          let body = try? JSONDecoder().decode(ApiCronReply.self, from: data),
          UUID(uuidString: body.operationId) != nil,
          ["summary", "detail"].contains(body.snapshotKind)
        else { throw URLError(.badServerResponse) }
        if let operation = canonicalOperation, operation != body.operationId {
          throw URLError(.badServerResponse)
        }
        canonicalOperation = body.operationId
        replyCount += 1
        if scenario == .cronReplyRetry && replyCount == 1 {
          return HTTPResponse(
            data: Data(
              #"{"error":{"code":"cron_reply_outcome_unknown","message":"Sample response was lost."}}"#
                .utf8), status: 503)
        }
        if ProcessInfo.processInfo.arguments.contains("--cron-hold-reply") {
          await withCheckedContinuation { replyWaiter = $0 }
        }
        let thread = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(CronRunsFixture.importedThread()))
        let message = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(CronRunsFixture.importedMessage()))
        return try encoded(
          JSONValue.object([
            "operationId": .string(body.operationId),
            "sourceId": .string(AgentSettingsFixture.atlas),
            "jobId": .string(AutomationsFixture.jobID),
            "runId": .string("run-sample"), "duplicate": .bool(replyCount > 1),
            "thread": thread, "messages": .array([message]),
          ]))
      case ("GET", "/api/v1/threads/" + CronRunsFixture.importedID):
        let thread = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(CronRunsFixture.importedThread()))
        let message = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(CronRunsFixture.importedMessage()))
        return try encoded(
          JSONValue.object([
            "thread": thread, "messages": .array([message]), "messagesNextCursor": .null,
          ]))
      case ("GET", "/api/v1/threads/" + AutomationsFixture.threadID):
        let thread = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(AutomationsFixture.thread()))
        let message = try JSONDecoder().decode(
          JSONValue.self,
          from: JSONEncoder().encode(
            scenario.isCronRuns ? CronRunsFixture.message() : AutomationsFixture.message()))
        return try encoded(
          JSONValue.object([
            "thread": thread, "messages": .array([message]), "messagesNextCursor": .null,
          ]))
      case ("GET", "/api/v1/threads/" + AutomationsFixture.threadID + "/messages"):
        let message = try JSONDecoder().decode(
          JSONValue.self,
          from: JSONEncoder().encode(
            scenario.isCronRuns ? CronRunsFixture.message() : AutomationsFixture.message()))
        return try encoded(JSONValue.object(["messages": .array([message]), "nextCursor": .null]))
      default:
        if method == "GET",
          let value = try DashboardFixture.response(for: request, empty: false, theme: theme)
        {
          return value
        }
        throw URLError(.resourceUnavailable)
      }
    }
  }
#endif
