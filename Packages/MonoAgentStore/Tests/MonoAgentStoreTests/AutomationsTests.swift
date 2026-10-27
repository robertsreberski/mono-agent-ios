// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct AutomationsTests {
  let source = "agent-example"
  var path: String { "/api/v1/agents/\(source)/cron" }
  func overview(_ jobs: String? = nil) throws -> WebCronOverview {
    try decode(
      """
      {"generatedAt":"2030-01-02T12:00:00Z","actionsEnabled":true,"jobs":[\(jobs ?? jobJSON)]}
      """)
  }
  var jobJSON: String {
    #"{"jobId":"sample-digest","expression":"0 9 * * *","timezone":"UTC","conversationId":"cron-sample","configured":true,"declaredEnabled":false,"effectiveEnabled":true,"health":"healthy","threadId":"thread-cron"}"#
  }
  func live() async throws -> Harness {
    let h = try await AgentSettingsTests().live()
    h.store.bootstrap?.agents[0].cron = try decode(#"{"read":true,"actions":true}"#)
    h.store.selectedBucket = BucketKey(sourceID: source)
    h.store.selectedThreadID = "thread-cron"
    await h.transport.set(path, [.response(try response(overview()))])
    await h.store.refreshAutomations(sourceID: source)
    h.store.openCronJob(sourceID: source, jobID: "sample-digest", threadID: "thread-cron")
    return h
  }
  func challenge() throws -> HTTPResponse {
    try response(
      try decode(
        #"{"kind":"confirmation_required","confirmation":{"token":"fictional-confirmation","expiresAt":"2099-01-01T00:00:00Z","message":"Confirm the sample action."}}"#,
        as: JSONValue.self), status: 428)
  }
  @Test func cachedOverviewNeverGrantsAuthorityAndReadsHaveSingleFlight() async throws {
    let h = try await live()
    let state = h.store.automationState(source)
    #expect(h.store.automationIsAuthoritative(source))
    await h.transport.set(path, [.paused, .response(try response(overview("")))])
    h.store.requestAutomations(sourceID: source, invalidate: true)
    let flight = state.flight
    await eventually { await h.transport.pauseCount() == 1 }
    for _ in 0..<8 { h.store.requestAutomations(sourceID: source, invalidate: true) }
    #expect(!h.store.automationIsAuthoritative(source))
    await h.transport.release(try response(overview()))
    await flight?.value
    #expect(state.overview?.jobs.isEmpty == true && state.freshness == .fresh)
    #expect(await h.transport.count(path) == 3)
    await h.store.flushCache()
    let restored = ConsoleStore(
      profile: h.profile, api: APIClient(endpoint: h.profile.endpoint, transport: h.transport),
      events: h.events, repository: h.repository, clock: h.clock)
    await restored.hydrate()
    #expect(restored.automationState(source).overview?.jobs.isEmpty == true)
    #expect(!restored.automationIsAuthoritative(source))
  }
  @Test func enableUsesEffectiveStateAndConfirmationReusesExactIdentity() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    let action = path + "/jobs/sample-digest/effective-enabled"
    await h.transport.set(
      action,
      [
        .response(try challenge()),
        .response(
          try response(
            try decode(
              #"{"kind":"completed","value":{"job":\#(jobJSON)},"replayed":false}"#,
              as: JSONValue.self))),
      ])
    h.store.performCronAction(sourceID: source, action: .enabled(false))
    h.store.performCronAction(sourceID: source, action: .run)
    await job.task?.value
    #expect(job.confirmation?.action == .enabled(false))
    let first = await AgentSettingsTests().body(h, action)
    #expect(first?["enabled"] == .bool(false))
    await h.transport.set(path, [.response(try response(overview()))])
    await h.store.confirmCronAction(sourceID: source)
    await job.task?.value
    let second = await AgentSettingsTests().body(h, action)
    #expect(first?["idempotencyKey"] == second?["idempotencyKey"])
    #expect(second?["confirmationToken"] == .string("fictional-confirmation"))
    #expect(await h.transport.count(action, method: "POST") == 2)
    #expect(job.confirmation == nil && job.notice != nil)
  }
  @Test(arguments: [
    "offline", "capability", "generation", "background", "selection", "degraded", "historical",
    "stale", "disabled",
  ])
  func exactAdmissionGuards(_ change: String) async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    switch change {
    case "offline": h.store.connection = .offline
    case "capability": h.store.bootstrap?.agents[0].cron?.actions = false
    case "generation": h.store.bootstrap?.agents[0].generation = "replacement"
    case "background": await h.store.scenePhaseChanged(.background)
    case "selection": h.store.selectedThreadID = "different-thread"
    case "degraded": h.store.automationState(source).overview?.degradedReason = "State unavailable"
    case "historical": h.store.automationState(source).overview?.jobs[0].configured = false
    case "stale": h.store.automationState(source).freshness = .stale
    default: h.store.automationState(source).overview?.actionsEnabled = false
    }
    h.store.performCronAction(sourceID: source, action: .run)
    await job.task?.value
    #expect(await h.transport.count(path + "/jobs/sample-digest/run", method: "POST") == 0)
    #expect(!job.busy)
  }
  @Test func dispatchRechecksCapabilityBeforeTaskStarts() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    h.store.performCronAction(sourceID: source, action: .run)
    let task = job.task
    h.store.bootstrap?.agents[0].cron?.actions = false
    await task?.value
    #expect(await h.transport.count(path + "/jobs/sample-digest/run", method: "POST") == 0)
    #expect(!job.busy)
  }
  @Test func lateMutationCannotPublishAfterSelectionOrEpochReplacement() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    let action = path + "/jobs/sample-digest/run"
    await h.transport.set(action, [.paused])
    h.store.performCronAction(sourceID: source, action: .run)
    let task = job.task
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.scenePhaseChanged(.background)
    await h.transport.release(try challenge())
    await task?.value
    #expect(job.confirmation == nil && job.notice == nil && job.error == nil)
    #expect(await h.transport.count(action, method: "POST") == 1)
  }
  @Test func configIsReadOnlyRedactedEphemeralAndSharesActionExclusion() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    await h.transport.set(path + "/config-view", [.paused])
    h.store.openCronConfig(sourceID: source)
    let task = job.task
    h.store.performCronAction(sourceID: source, action: .run)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(
      try response(
        try decode(
          #"{"configView":{"id":"cron","label":"Cron configuration","status":"ready","fields":[{"id":"key","label":"API key","value":"must-not-display","source":"environment","redacted":true}]}}"#,
          as: JSONValue.self)))
    await task?.value
    #expect(job.config?.fields[0].value == "••••••••" && job.configOpen)
    #expect(await h.transport.count(path + "/jobs/sample-digest/run", method: "POST") == 0)
    await h.store.flushCache()
    let cache = try await h.repository.loadCache(h.store.namespace)
    #expect(
      !String(decoding: try JSONEncoder().encode(cache), as: UTF8.self).contains("must-not-display")
    )
    h.store.closeCronJob(sourceID: source)
    #expect(job.config == nil && !job.configOpen)
  }
  @Test func changedEventsAreSourceScopedAndGapReadsReconcile() async throws {
    let h = try await live()
    let state = h.store.automationState(source)
    let other: ApiEvent = try decode(
      #"{"id":"event-other","version":1,"at":"2030-01-02T12:00:00Z","type":"cron.changed","payload":{"sourceId":"other-agent"}}"#
    )
    await h.store.receive(.event(generation: 1, gap: .initial, other))
    #expect(await h.transport.count(path) == 1)
    await h.transport.set(path, [.paused, .response(try response(overview("")))])
    let changed: ApiEvent = try decode(
      #"{"id":"event-cron","version":1,"at":"2030-01-02T12:00:00Z","type":"cron.changed","payload":{"sourceId":"agent-example","jobId":"sample-digest"}}"#
    )
    await h.store.receive(.event(generation: 1, gap: .initial, changed))
    let flight = state.flight
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.receive(.event(generation: 1, gap: .initial, changed))
    #expect(state.freshness == .stale)
    await h.transport.release(try response(overview()))
    await flight?.value
    #expect(state.overview?.jobs.isEmpty == true)
    #expect(await h.transport.count(path) == 3)
    await h.transport.set(path, [.response(try response(overview()))])
    await h.store.receive(.gap(generation: 2, reason: .overflow))
    #expect(state.freshness == .stale)
    await h.store.reconciliationTask?.value
    #expect(state.overview?.jobs.count == 1 && state.freshness == .fresh)
  }
  @Test func physicalCommandExclusionSurvivesClosingAndReopening() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    let action = path + "/jobs/sample-digest/run"
    await h.transport.set(action, [.paused])
    h.store.performCronAction(sourceID: source, action: .run)
    let task = job.task
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.closeCronJob(sourceID: source)
    let next = h.store.openCronJob(
      sourceID: source, jobID: "sample-digest", threadID: "thread-cron")
    h.store.performCronAction(sourceID: source, action: .run)
    h.store.openCronConfig(sourceID: source)
    #expect(next.task == nil)
    #expect(h.store.automationState(source).pendingJobs.contains("sample-digest"))
    await h.transport.release(try challenge())
    await task?.value
    #expect(next.confirmation == nil && next.error == nil)
    #expect(h.store.automationState(source).pendingJobs.isEmpty)
    #expect(await h.transport.count(action, method: "POST") == 1)
  }
  @Test func oldCacheDecodingAndSnapshotMergeRemainBackwardCompatible() throws {
    var old = CacheRecord()
    old.bootstrap = nil
    let encoded = try JSONEncoder().encode(old)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "automationOverviews")
    let decoded = try JSONDecoder().decode(
      CacheRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.automationOverviews == nil)
    var local = decoded
    var disk = decoded
    let now = Date()
    local.automationOverviews = [.init(sourceID: source, overview: try overview(), savedAt: now)]
    disk.automationOverviews = [
      .init(sourceID: source, overview: try overview(""), savedAt: now.addingTimeInterval(1))
    ]
    let merged = CacheMerge.rebase(local, onto: disk)
    #expect(merged.automationOverviews?.first?.overview.jobs.isEmpty == true)
  }
  @Test func failedReadRetainsSnapshotButRemovesAuthority() async throws {
    let h = try await live()
    await h.transport.set(path, [.failure])
    await h.store.refreshAutomations(sourceID: source)
    let state = h.store.automationState(source)
    #expect(state.overview?.jobs.count == 1 && state.error != nil)
    #expect(!h.store.automationIsAuthoritative(source))
    h.store.performCronAction(sourceID: source, action: .run)
    #expect(state.job?.task == nil)
  }
  @Test func schedulesAndStrictFutureDatesMatchWebGrammar() throws {
    var job = try overview().jobs[0]
    for (expression, expected) in [
      ("* * * * *", "Every minute"), ("*/15 * * * *", "Every 15 minutes"),
      ("7 * * * *", "Every hour at :07 (UTC)"), ("0 9 * * 1-5", "Weekdays at 09:00 (UTC)"),
      ("30 8 * * 7", "Every Sunday at 08:30 (UTC)"), ("*/7 * * * *", "*/7 * * * * (UTC)"),
    ] {
      job.expression = expression
      #expect(AutomationPresentation.schedule(job) == expected)
    }
    let now = try #require(ServerTimestamp.date("2030-01-01T00:00:00Z"))
    for stamp in [
      "2099-02-30T10:00:00Z", "2099-01-01T24:00:00Z", "2099-01-01T10:00:00", "2030-01-01T00:00:00Z",
      "nonsense",
    ] {
      #expect(AutomationPresentation.futureInstant(stamp, now: now) == nil)
    }
    #expect(AutomationPresentation.futureInstant("2099-01-01T10:00:00+02:00", now: now) != nil)
  }
  @Test func snapshotCountAndAgeStayWithinExistingCacheBudgets() async throws {
    let h = Harness()
    let now = Date()
    var cache = CacheRecord()
    cache.revision = 1
    cache.automationOverviews = try (0..<26).map { index in
      .init(
        sourceID: "source-\(index)", overview: try overview(),
        savedAt: now.addingTimeInterval(Double(-index)))
    }
    cache.automationOverviews?.append(
      .init(
        sourceID: "expired", overview: try overview(),
        savedAt: now.addingTimeInterval(-ConsoleBounds.maxAge - 1)))
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    let restored = try await h.repository.loadCache(h.store.namespace)
    #expect(restored.automationOverviews?.count == 24)
    #expect(restored.automationOverviews?.contains(where: { $0.sourceID == "expired" }) == false)
  }
  @Test func filteringSortingAndSnapshotProjection() throws {
    var value = try overview()
    var other = value.jobs[0]
    other.jobId = "alpha"
    other.health = "degraded"
    value.jobs.append(other)
    #expect(
      AutomationPresentation.jobs(value, query: "").map(\.jobId) == ["alpha", "sample-digest"])
    #expect(AutomationPresentation.jobs(value, query: "DEGRADED").map(\.jobId) == ["alpha"])
    for query in ["UTC", "0 9", "enabled"] {
      #expect(AutomationPresentation.jobs(value, query: query).count == 2)
    }
    value.jobs[0].nextRunAt = "2099-01-01T00:00:00Z"
    #expect(AutomationPresentation.nextRun(value.jobs[0], live: false, now: Date()) == nil)
    #expect(AutomationPresentation.state(value.jobs[0], live: false) == "Snapshot")
  }
}
