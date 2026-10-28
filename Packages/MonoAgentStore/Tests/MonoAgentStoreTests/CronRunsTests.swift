// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct CronRunsTests {
  var source: String { "agent-example" }
  var path: String { "/api/v1/agents/agent-example/cron/jobs/sample-digest/runs" }
  var key: CronReplyKey { .init(sourceID: source, jobID: "sample-digest", runID: "run-1") }
  func message(_ run: String = "run-1", text: String = "Compact result", seq: Int = 1) throws
    -> WebMessage
  {
    var value = try sampleMessage("message-" + run, seq: seq)
    value.threadId = "thread-cron"
    value.status = "complete"
    value.parts = [
      try decode(
        #"{"type":"telemetry","event":"cron_run","data":{"runId":"\#(run)","sequence":1,"status":"failed","trigger":"scheduled","eventCount":1}}"#,
        as: WebMessagePart.self),
      try decode(#"{"type":"text","text":"\#(text)"}"#, as: WebMessagePart.self),
    ]
    return value
  }
  func run(_ id: String = "run-1") throws -> WebCronRunSummary {
    try decode(
      #"{"runId":"\#(id)","jobId":"sample-digest","sequence":1,"scheduledAt":"2030-01-02T12:00:00Z","orderedAt":"2030-01-02T12:00:00Z","trigger":"scheduled","status":"failed","eventCount":1,"projection":"summary"}"#
    )
  }
  func live() async throws -> Harness {
    let h = try await AutomationsTests().live()
    var thread = try sampleThread("thread-cron")
    thread.sourceId = source
    h.store.hold(.init(thread: thread, messages: [try message()], savedAt: Date()))
    await h.store.cronReplyRecovery.hydrate(h.store.namespace)
    return h
  }
  func receipt(_ h: Harness, operation: String, change: String = "") throws -> HTTPResponse {
    var thread = try sampleThread("thread-imported")
    thread.sourceId = source
    var message = try sampleMessage("message-imported")
    message.threadId = thread.id
    var value: JSONValue = .object([
      "operationId": .string(operation), "sourceId": .string(source),
      "jobId": .string("sample-digest"),
      "runId": .string("run-1"), "duplicate": .bool(false),
      "thread": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(thread)),
      "messages": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([message])),
    ])
    if case .object(var fields) = value, !change.isEmpty {
      if change == "threadSource", case .object(var thread) = fields["thread"] {
        thread["sourceId"] = .string("other-source")
        fields["thread"] = .object(thread)
      } else if change == "messageThread", case .array(var messages) = fields["messages"],
        case .object(var message) = messages[0]
      {
        message["threadId"] = .string("other-thread")
        messages[0] = .object(message)
        fields["messages"] = .array(messages)
      } else if change == "messages" {
        fields[change] = .array([])
      } else {
        fields[change] = .string("wrong")
      }
      value = .object(fields)
    }
    return try response(value)
  }
  @Test func registrySurvivesStoreReplacementAndRefusedStorageNeverBlocksAnImport() async throws {
    let h = try await live()
    let registry = CronReplyRecoveryStore(persistence: RefusedCronPersistence())
    await registry.hydrate(h.store.namespace)
    let original = try #require(
      registry.begin(key, snapshotKind: "summary", namespace: h.store.namespace))
    registry.finish(key, namespace: h.store.namespace)
    await registry.settlePersistence(h.store.namespace)
    let replacement = ConsoleStore(
      profile: h.profile,
      api: APIClient(endpoint: h.profile.endpoint, transport: h.transport), events: h.events,
      repository: h.repository, clock: h.clock, cronReplyRecovery: registry)
    replacement.bootstrap = h.store.bootstrap
    replacement.enabled = true
    replacement.started = true
    replacement.connection = .live
    replacement.selectedBucket = h.store.selectedBucket
    replacement.selectedThreadID = h.store.selectedThreadID
    replacement.hold(try #require(h.store.selectedConversation).record)
    replacement.automationState(source).overview = h.store.automationState(source).overview
    replacement.openCronJob(sourceID: source, jobID: key.jobID, threadID: "thread-cron")
    await h.transport.set(path + "/run-1/reply-threads", [.paused])
    // No automatic replay when replacement state is restored.
    #expect(replacement.cronReplyPhase(key) == .retry)
    #expect(await h.transport.count(path + "/run-1/reply-threads", method: "POST") == 0)
    replacement.replyToCronRun(sourceID: source, runID: key.runID, snapshotKind: "detail")
    let task = replacement.cronReplySnapshot(key)?.task
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(registry.reference(key, namespace: h.store.namespace) == original)
    let other = ConsoleStore(
      profile: h.profile,
      api: APIClient(endpoint: h.profile.endpoint, transport: h.transport), events: h.events,
      repository: h.repository, cronReplyRecovery: registry)
    #expect(other.cronReplyPhase(key) == .importing)
    await h.transport.release(try receipt(h, operation: original.operationID.uuidString))
    await task?.value
    await registry.settlePersistence(h.store.namespace)
    #expect(replacement.cronReplyNavigation?.threadID == "thread-imported")
    #expect(replacement.journalStorage == .durable && replacement.pendingSubmissions.isEmpty)
  }
  @Test func paginationAndEqualVersionDetailReplacementAndHidden404() async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    let page = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([try run()]))
    await h.transport.set(
      path,
      [
        .response(try response(JSONValue.object(["runs": page, "nextCursor": .string("older")]))),
        .response(try response(JSONValue.object(["runs": page, "nextCursor": .string("older")]))),
      ])
    await h.store.loadCronRuns(sourceID: source)
    #expect(job.runs.nextCursor == "older" && job.runs.runs.count == 1)
    await h.store.loadCronRuns(sourceID: source, older: true)
    #expect(job.runs.nextCursor == nil && job.runs.runs.count == 1)
    await h.transport.set(
      path + "/run-1",
      [
        .response(try response(["message": message(text: "Full activity")])),
        .response(
          HTTPResponse(
            data: Data(#"{"error":{"code":"cron_run_not_visible","message":"Hidden"}}"#.utf8),
            status: 404)),
      ])
    await h.store.loadCronRunActivity(sourceID: source, runID: "run-1")
    #expect(
      h.store.selectedConversation?.messages.first?.parts
        == (try message(text: "Full activity")).parts)
    await h.store.loadCronRunActivity(sourceID: source, runID: "run-1")
    #expect(job.runs.runs.isEmpty && job.runs.details.isEmpty)
    #expect(h.store.selectedConversation?.messages.isEmpty == true)
    #expect(!job.runs.loading && job.runs.loadingDetails.isEmpty)
  }
  @Test(arguments: ["selection", "background", "generation", "revision", "conversation"])
  func lateDetailCannotPublish(_ change: String) async throws {
    let h = try await live()
    let old = try #require(h.store.selectedConversation)
    await h.transport.set(path + "/run-1", [.paused])
    let task = Task { await h.store.loadCronRunActivity(sourceID: source, runID: "run-1") }
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case "selection": h.store.selectedThreadID = "other"
    case "background": await h.store.scenePhaseChanged(.background)
    case "generation": h.store.bootstrap?.agents[0].generation = "replacement"
    case "revision": h.store.invalidateAutomation(source)
    default: h.store.conversations["thread-cron"] = nil
    }
    await h.transport.release(try response(["message": message(text: "Late activity")]))
    await task.value
    #expect(old.messages.first?.parts == (try message()).parts)
    #expect(h.store.automationState(source).job?.runs.loadingDetails.isEmpty == true)
  }
  @Test func uncertainRetryIsSingleFlightAndPreservesOperationAndSnapshotDespiteOffline()
    async throws
  {
    let h = try await live()
    let endpoint = path + "/run-1/reply-threads"
    await h.transport.set(endpoint, [.paused, .paused])
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "summary")
    let state = try #require(h.store.cronReplySnapshot(key))
    let firstTask = state.task
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "detail")
    await h.transport.release(
      HTTPResponse(
        data: Data(#"{"error":{"code":"cron_reply_outcome_unknown","message":"Unknown"}}"#.utf8),
        status: 503))
    await firstTask?.value
    let original = try #require(
      h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    #expect(state.phase == .retry)
    h.store.connection = .offline
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "detail")
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == original)
    h.store.connection = .live
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "detail")
    let secondTask = state.task
    await eventually { await h.transport.pauseCount() == 1 }
    let body = await AgentSettingsTests().body(h, endpoint)
    #expect(body?["operationId"] == .string(original.operationID.uuidString.lowercased()))
    #expect(body?["snapshotKind"] == .string("summary"))
    await h.transport.release(try receipt(h, operation: original.operationID.uuidString))
    await secondTask?.value
    #expect(h.store.cronReplyNavigation?.threadID == "thread-imported")
    #expect(
      state.phase == .idle
        && h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == nil)
    #expect(await h.transport.count(endpoint, method: "POST") == 2)
    #expect(h.store.journal.pending.isEmpty && h.store.journalStorage == .durable)
  }
  @Test(arguments: ["cron_reply_agent_offline", "cron_reply_unsupported"])
  func recoveredPreflightFailureCannotForgetEarlierUncertainty(_ code: String) async throws {
    let h = try await live()
    let endpoint = path + "/run-1/reply-threads"
    await h.transport.set(endpoint, [.failure])
    h.store.replyToCronRun(sourceID: source, runID: key.runID, snapshotKind: "summary")
    await h.store.cronReplySnapshot(key)?.task?.value
    let reference = try #require(
      h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    await h.transport.set(
      endpoint,
      [
        .response(
          HTTPResponse(
            data: Data(
              "{\"error\":{\"code\":\"\(code)\",\"message\":\"Sample preflight unavailable\"}}".utf8
            ), status: 409))
      ])
    h.store.replyToCronRun(sourceID: source, runID: key.runID, snapshotKind: "detail")
    await h.store.cronReplySnapshot(key)?.task?.value
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == reference)
    #expect(h.store.cronReplyPhase(key) == .retry)
    let body = await AgentSettingsTests().body(h, endpoint)
    #expect(body?["snapshotKind"] == .string("summary"))
  }
  @Test(arguments: [
    "operationId", "sourceId", "jobId", "runId", "messages", "threadSource", "messageThread",
  ])
  func malformedReceiptNeverNavigatesAndRetainsIdentity(_ field: String) async throws {
    let h = try await live()
    let endpoint = path + "/run-1/reply-threads"
    await h.transport.set(endpoint, [.paused])
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "summary")
    let task = h.store.cronReplySnapshot(key)?.task
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(
      h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    await h.transport.release(
      try receipt(h, operation: reference.operationID.uuidString, change: field))
    await task?.value
    #expect(h.store.cronReplyNavigation == nil && h.store.conversations["thread-imported"] == nil)
    #expect(h.store.cronReplyPhase(key) == .retry)
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == reference)
  }
  @Test(arguments: ["selection", "background", "generation", "revision", "deleted"])
  func lateReplyCannotPublishOrNavigate(_ change: String) async throws {
    let h = try await live()
    let endpoint = path + "/run-1/reply-threads"
    await h.transport.set(endpoint, [.paused])
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "summary")
    let task = h.store.cronReplySnapshot(key)?.task
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(
      h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    switch change {
    case "selection": h.store.selectedThreadID = "other"
    case "background": await h.store.scenePhaseChanged(.background)
    case "generation": h.store.bootstrap?.agents[0].generation = "replacement"
    case "revision": h.store.invalidateAutomation(source)
    default: h.store.removeThread("thread-imported")
    }
    await h.transport.release(try receipt(h, operation: reference.operationID.uuidString))
    await task?.value
    #expect(h.store.cronReplyNavigation == nil && h.store.conversations["thread-imported"] == nil)
    #expect(!h.store.cronReplyRecovery.isActive(key, namespace: h.store.namespace))
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == nil)
    #expect(h.store.cronReplyPhase(key) != .retry)
    #expect(!h.store.automationIsAuthoritative(source))
  }
  @Test(arguments: ["selection", "background", "generation", "revision", "capability"])
  func dispatchGuardActuallyPreventsPOST(_ change: String) async throws {
    let h = try await live()
    h.store.replyToCronRun(sourceID: source, runID: "run-1", snapshotKind: "summary")
    let task = h.store.cronReplySnapshot(key)?.task
    // Prove admission already reserved an operation; the dispatch task has not run yet.
    #expect(h.store.cronReplyRecovery.isActive(key, namespace: h.store.namespace))
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) != nil)
    switch change {
    case "selection": h.store.selectedThreadID = "other"
    case "background": await h.store.scenePhaseChanged(.background)
    case "generation": h.store.bootstrap?.agents[0].generation = "replacement"
    case "revision": h.store.invalidateAutomation(source)
    default: h.store.bootstrap?.agents[0].cron?.read = false
    }
    await task?.value
    #expect(await h.transport.count(path + "/run-1/reply-threads", method: "POST") == 0)
    #expect(!h.store.cronReplyRecovery.isActive(key, namespace: h.store.namespace))
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == nil)
  }
  @Test func pendingCollisionAdoptsServerIdentityAndRetryConverges() async throws {
    let h = try await live()
    let endpoint = path + "/run-1/reply-threads"
    let serverLiteral = "a032b14a-bf26-4a48-91b6-8b052d571a39"
    let serverID = try #require(UUID(uuidString: serverLiteral))
    await h.transport.set(endpoint, [.paused, .paused])
    h.store.replyToCronRun(sourceID: source, runID: key.runID, snapshotKind: "summary")
    let state = try #require(h.store.cronReplySnapshot(key))
    let first = state.task
    await eventually { await h.transport.pauseCount() == 1 }
    let local = try #require(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    await h.transport.release(
      HTTPResponse(
        data: Data(
          """
          {"error":{"code":"cron_reply_pending","message":"Pending",
          "details":{"operationId":"\(serverLiteral)","pendingSince":"2030-01-02T12:00:00Z"}}}
          """.utf8), status: 409))
    await first?.value
    let adopted = try #require(
      h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace))
    #expect(adopted.operationID == serverID && adopted.operationID != local.operationID)
    #expect(adopted.snapshotKind == "summary" && state.phase == .retry)
    #expect(state.message?.contains("Another Reply for this result") == true)
    let since = try #require(ISO8601DateFormatter().date(from: "2030-01-02T12:00:00Z"))
    #expect(state.message?.hasSuffix(" (since " + since.formatted() + ")") == true)
    h.store.replyToCronRun(sourceID: source, runID: key.runID, snapshotKind: "detail")
    let retry = state.task
    await eventually { await h.transport.pauseCount() == 1 }
    let body = await AgentSettingsTests().body(h, endpoint)
    #expect(body?["operationId"] == .string(serverLiteral))
    #expect(body?["snapshotKind"] == .string("summary"))
    let request = try #require(await h.transport.requests.last { $0.url?.path == endpoint })
    // JSON object key order is unspecified; both complete encodings must have identical values.
    let expectedBodies = [
      "{\"operationId\":\"\(serverLiteral)\",\"snapshotKind\":\"summary\"}",
      "{\"snapshotKind\":\"summary\",\"operationId\":\"\(serverLiteral)\"}",
    ].map { Data($0.utf8) }
    #expect(expectedBodies.contains(try #require(request.httpBody)))
    await h.transport.release(try receipt(h, operation: serverLiteral))
    await retry?.value
    #expect(h.store.cronReplyNavigation?.threadID == "thread-imported")
    #expect(h.store.cronReplyRecovery.reference(key, namespace: h.store.namespace) == nil)
    #expect(state.phase == .idle)
  }

  @Test func coveredReplyFocusExpiresWhenSelectionLeavesImportedThread() async throws {
    let h = Harness()
    let request = CronReplyNavigation(id: UUID(), sourceID: source, threadID: "thread-imported")
    h.store.cronReplyNavigation = request
    await h.store.select(sourceID: source, threadID: request.threadID)
    #expect(h.store.cronReplyNavigation == request)
    // A covered composer does not consume focus. Reselecting its context preserves it.
    await h.store.select(sourceID: source, threadID: request.threadID)
    #expect(h.store.cronReplyNavigation == request)
    await h.store.select(sourceID: source, threadID: "thread-other")
    #expect(h.store.cronReplyNavigation == nil)
    await h.store.select(sourceID: source, threadID: request.threadID)
    #expect(h.store.cronReplyNavigation == nil)
    await h.store.stop()
  }

  @Test(arguments: ["thread", "message", "history"])
  func receiptCannotReplaceNewerConversation(_ change: String) async throws {
    let h = try await live()
    var thread = try sampleThread("thread-imported")
    thread.sourceId = source
    var original = try sampleMessage("message-imported", seq: 1)
    original.threadId = thread.id
    let stale = CachedConversation(thread: thread, messages: [original], savedAt: Date())
    var messages = [original]
    if change == "thread" { thread.revision += 1 }
    if change == "message" { messages[0].seq = 2 }
    if change == "history" {
      var later = try sampleMessage("message-later", seq: 2)
      later.threadId = thread.id
      messages.append(later)
    }
    let current = CachedConversation(thread: thread, messages: messages, savedAt: Date())
    h.store.hold(current)
    let held = try #require(h.store.conversations[thread.id])
    h.store.holdCronReply(stale)
    #expect(h.store.conversations[thread.id] === held)
    #expect(held.thread == thread && held.messages == messages)
  }

  @Test(arguments: ["direction", "older", "lifetime", "revision", "join"])
  func pageRequestWaitsThenReadmitsMismatchedFlight(_ change: String) async throws {
    let h = try await live()
    let job = try #require(h.store.automationState(source).job)
    job.runs.nextCursor = "older"
    job.runs.loaded = true
    await h.transport.set(
      path,
      [
        .paused,
        .response(
          try response(
            JSONValue.object([
              "runs": .array([]), "nextCursor": .null,
            ]))),
      ])
    let old = Task { await h.store.loadCronRuns(sourceID: source, older: change != "older") }
    await eventually { await h.transport.pauseCount() == 1 }
    if change == "lifetime" { h.store.resetCronJob(sourceID: source) }
    if change == "revision" { h.store.invalidateAutomation(source) }
    var entered = false
    let next = Task {
      entered = true
      await h.store.loadCronRuns(sourceID: source, older: change != "direction")
    }
    await eventually { entered }
    await h.transport.release(
      try response(
        JSONValue.object([
          "runs": .array([]), "nextCursor": .string("next"),
        ])))
    await old.value
    await next.value
    let requests = await h.transport.requests.filter { $0.url?.path == path }
    #expect(requests.count == (change == "join" ? 1 : 2))
    let query = requests.last?.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    }?.queryItems
    #expect(query?.contains { $0.name == "before" } == (change != "direction"))
    #expect(!job.runs.loading && job.runs.pageTask == nil)
  }

  @Test func detailRequestReadmitsAfterCancelledLifetime() async throws {
    let h = try await live()
    let endpoint = path + "/run-1"
    await h.transport.set(
      endpoint, [.paused, .response(try response(["message": message(text: "Current activity")]))])
    let old = Task { await h.store.loadCronRunActivity(sourceID: source, runID: key.runID) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.resetCronJob(sourceID: source)
    var entered = false
    let next = Task {
      entered = true
      await h.store.loadCronRunActivity(sourceID: source, runID: key.runID)
    }
    await eventually { entered }
    await h.transport.release(try response(["message": message(text: "Stale activity")]))
    await old.value
    await next.value
    #expect(await h.transport.count(endpoint) == 2)
    #expect(
      h.store.selectedConversation?.messages.first?.parts
        == (try message(text: "Current activity")).parts)
  }

}
