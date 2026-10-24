// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct OrganizeReviewTests {
  func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
  func seedConsumers(_ h: Harness, thread: WebThread) throws {
    h.store.conversations[thread.id]?.thread = thread
    h.store.conversations[thread.id]?.record.thread = thread
    let key = BucketKey(sourceID: thread.sourceId)
    h.store.buckets[key] = .init(key: key, threads: [thread], savedAt: Date())
    h.store.activeFleet = try JSONDecoder().decode(
      WebActiveThreads.self,
      from: JSONEncoder().encode(
        JSONValue.object([
          "threads": .array([try json(thread)]), "total": .number(1), "truncated": .bool(false),
          "runningCounts": .object([:]),
        ])))
    h.store.bootstrap?.threads = [thread]
    h.store.projectMembers["other-page"] = .init()
    h.store.projectMembers["other-page"]?.threads = [thread]
  }
  func rows(_ h: Harness) -> [WebThread] {
    Array(h.store.conversations.values.map(\.thread)) + h.store.buckets.values.flatMap(\.threads)
      + (h.store.activeFleet?.threads ?? []) + (h.store.bootstrap?.threads ?? [])
      + h.store.projectMembers.values.flatMap(\.threads)
  }
  @Test func fractionalInstantsAndCanonicalLinks() {
    let iso = "2031-05-12T12:30:00.123Z"
    let text = WakeScheduleModel.instant(iso, zone: "UTC", locale: Locale(identifier: "en_GB"))
    #expect(!text.contains("T12:30"))
    #expect(text.contains("12:30"))
    let next = WakeScheduleModel.nextFire(
      iso, scheduleZone: "America/Chicago", deviceZone: "Europe/Lisbon",
      locale: Locale(identifier: "en_GB"))
    #expect(next.scheduled.contains("07:30"))
    #expect(next.local == "13:30")
    for _ in 0..<10 { #expect(WakeScheduleModel.normalizeTimeZone("GB") == "Europe/London") }
    #expect(WakeScheduleModel.normalizeTimeZone("Europe/Guernsey") == "Europe/Guernsey")
  }
  @Test func backgroundClosesEpochBoundEditorsAndConfirmations() async throws {
    let h = try await ProjectTests().live()
    h.store.tags = h.store.bootstrap!.tags
    let id = try #require(h.store.openWakeEditor(threadID: "thread-example"))
    await h.transport.set(
      WakeStoreTests().path, [.response(try response(["schedule": WakeStoreTests().schedule()]))])
    await h.store.refreshWakeEditor(id)
    h.store.requestWakeDeletion(id)
    h.store.requestTagDeletion(id: h.store.tags[0].id)
    h.store.requestProjectConfirmation(id: h.store.projects[0].id)
    h.store.requestConversationAction(.archive, threadID: "thread-example")
    await h.store.scenePhaseChanged(.background)
    #expect(h.store.wakeEditor == nil)
    #expect(h.store.tagDeletionConfirmation == nil)
    #expect(h.store.projectConfirmation == nil)
    #expect(h.store.conversationActionConfirmation == nil)
    await h.store.scenePhaseChanged(.active)
    h.store.connection = .live
    let replacement = try #require(h.store.openWakeEditor(threadID: "thread-example"))
    await h.transport.set(
      WakeStoreTests().path, [.response(try response(["schedule": Optional<WebWakeSchedule>.none]))]
    )
    await h.store.refreshWakeEditor(replacement)
    var draft = try #require(h.store.wakeEditor?.draft)
    draft.message = "After foreground"
    h.store.editWakeDraft(replacement, draft: draft)
    #expect(h.store.wakeEditor?.draft.message == "After foreground")
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func confirmedAndSseLabelRemovalDetachEveryConsumer(sse: Bool)
    async throws
  {
    let h = try await ProjectTests().live()
    h.store.tags = h.store.bootstrap!.tags
    let project = h.store.projects[0]
    let tag = h.store.tags[0]
    var thread = try sampleThread()
    thread.projectId = project.id
    thread.projectName = project.name
    thread.tagIds = [tag.id]
    try seedConsumers(h, thread: thread)
    if sse {
      await h.store.receive(
        .event(
          generation: 1, gap: .initial,
          try event(
            "tags.changed", thread: nil,
            payload: .object(["tagId": .string(tag.id), "removed": .bool(true)]))))
      await h.store.receive(
        .event(
          generation: 1, gap: .initial,
          try event(
            "projects.changed", thread: nil,
            payload: .object(["projectId": .string(project.id), "removed": .bool(true)]))))
    } else {
      await h.transport.set("/api/v1/tags/" + tag.id, [.response(.init(data: Data(), status: 204))])
      h.store.requestTagDeletion(id: tag.id)
      try await h.store.confirmTagDeletion(try #require(h.store.tagDeletionConfirmation).id)
      await h.transport.set(
        "/api/v1/projects/" + project.id, [.response(.init(data: Data(), status: 204))])
      h.store.requestProjectConfirmation(id: project.id)
      try await h.store.confirmProjectAction(try #require(h.store.projectConfirmation).id)
    }
    let all = rows(h)
    #expect(all.count == 5)
    #expect(
      all.allSatisfy { $0.projectId == nil && $0.projectName == nil && !$0.tagIds.contains(tag.id) }
    )
    await h.store.stop()
  }
  @Test func streamingDuringRegistryAndMemberReadsDoesNotStarveOrReattach() async throws {
    let h = try await ProjectTests().live()
    h.store.tags = h.store.bootstrap!.tags
    let project = h.store.projects[0]
    var original = try sampleThread()
    original.projectId = project.id
    try seedConsumers(h, thread: original)
    var other = original
    other.id = "streaming-other"
    other.revision += 1
    h.store.hold(.init(thread: other, messages: [], savedAt: Date()))
    await h.transport.set("/api/v1/threads", [.paused])
    let members = Task { await h.store.loadProjectMembers(id: project.id) }
    await eventually { await h.transport.pauseCount() == 1 }
    var moved = original
    moved.projectId = nil
    moved.revision += 1
    await h.store.receive(
      .event(
        generation: 1, gap: .initial,
        try event("thread.changed", payload: .object(["thread": try json(moved)]))))
    await h.store.receive(
      .event(
        generation: 1, gap: .initial,
        try event("thread.changed", thread: other.id, payload: .object(["thread": try json(other)]))
      ))
    var newer = other
    newer.revision += 1
    newer.title = "Newest member title"
    await h.transport.release(
      try response(
        JSONValue.object([
          "threads": .array([try json(original), try json(newer)]), "nextCursor": .null,
        ])))
    await members.value
    #expect(h.store.projectMembers[project.id]?.threads.map(\.id) == [other.id])
    #expect(h.store.projectMembers[project.id]?.threads.first?.title == "Newest member title")
    let tag = h.store.tags[0]
    var fetched = tag
    fetched.id = "new-registry-tag"
    await h.transport.set("/api/v1/tags", [.paused])
    await h.transport.set("/api/v1/projects", [.response(try response(["projects": [project]]))])
    let registry = Task { await h.store.refreshOrganizeLabels(sourceID: tag.sourceId) }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.receive(
      .event(
        generation: 1, gap: .initial,
        try event(
          "tags.changed", thread: nil,
          payload: .object(["tagId": .string(tag.id), "removed": .bool(true)]))))
    await h.store.receive(
      .event(
        generation: 1, gap: .initial,
        try event("thread.changed", thread: other.id, payload: .object(["thread": try json(other)]))
      ))
    await h.transport.release(try response(["tags": [tag, fetched]]))
    await registry.value
    #expect(h.store.tags.contains { $0.id == fetched.id })
    #expect(!h.store.tags.contains { $0.id == tag.id })
    await h.store.stop()
  }
  @Test func compactionBypassesQueueAndOutlivesShortWriteDeadline() async throws {
    let h = try await ConversationActionTests().live()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    await h.transport.set("/api/v1/threads/thread-example/compact", [.paused])
    h.store.compactConversation(threadID: "thread-example")
    await eventually { await h.transport.pauseCount() == 1 }
    await h.clock.advance(16)
    #expect(h.store.manualCompactions["thread-example"] == .pending)
    await h.transport.release(
      .init(
        data: Data(
          #"{"status":"succeeded","operationId":"compact-example","trigger":"manual"}"#.utf8)))
    await h.store.independentOrganizeOperations["thread-example"]?.request?.value
    if case .result = h.store.manualCompactions["thread-example"] {
    } else {
      Issue.record("Compaction did not complete")
    }
    await gate.release()
    await h.store.stop()
  }
  @Test func deleteBypassesQueueAndOnlyConfirmedDeleteClearsBoundDraft() async throws {
    let h = try await ConversationActionTests().live(archived: true)
    let gate = WriteGate()
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "Keep until confirmed")
    await h.store.setDraft(sourceID: "agent-example", text: "Unrelated new conversation")
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    await h.transport.set("/api/v1/threads/thread-example", [.failure, .paused])
    h.store.requestConversationAction(.delete, threadID: "thread-example")
    h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    await h.store.independentOrganizeOperations["thread-example"]?.request?.value
    #expect(h.store.draft(sourceID: "agent-example", threadID: "thread-example") != nil)
    h.store.requestConversationAction(.delete, threadID: "thread-example")
    h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(.init(data: Data(), status: 204))
    await h.store.independentOrganizeOperations["thread-example"]?.request?.value
    #expect(h.store.draft(sourceID: "agent-example", threadID: "thread-example") == nil)
    #expect(h.store.draft(sourceID: "agent-example")?.text == "Unrelated new conversation")
    await gate.release()
    await h.store.stop()
  }
  @Test func compactionOwnDeadlineDoesNotPublishLateSuccess() async throws {
    let h = try await ConversationActionTests().live()
    await h.transport.set("/api/v1/threads/thread-example/compact", [.paused])
    h.store.compactConversation(threadID: "thread-example")
    await eventually { await h.transport.pauseCount() == 1 }
    let request = h.store.independentOrganizeOperations["thread-example"]?.request
    await h.clock.advance(APIClient.manualCompactionTimeout + 1)
    await eventually { h.store.pendingConversationActions.isEmpty }
    #expect(h.store.manualCompactions["thread-example"] == .failed)
    await h.transport.release(
      .init(
        data: Data(
          #"{"status":"succeeded","operationId":"compact-example","trigger":"manual"}"#.utf8)))
    await request?.value
    #expect(h.store.manualCompactions["thread-example"] == .failed)
    await h.store.stop()
  }
  @Test func renameUsesWebTrimRuleNotProjectNameLimit() async throws {
    let h = try await ConversationActionTests().live()
    var renamed = try sampleThread()
    renamed.title = String(repeating: "x", count: 121)
    renamed.revision += 1
    await h.transport.set(
      "/api/v1/threads/thread-example", [.response(try response(["thread": renamed]))])
    h.store.renameConversation(threadID: renamed.id, title: "  " + renamed.title + "  ")
    try await h.store.settleThreadWrites(renamed.id)
    #expect(h.store.conversations[renamed.id]?.thread.title == renamed.title)
    await h.store.stop()
  }

  @Test func deleteCanOvertakeAnActualPendingRenameWithoutResurrection() async throws {
    let h = try await ConversationActionTests().live(archived: true)
    await h.transport.set(
      "/api/v1/threads/thread-example", [.paused, .response(.init(data: Data(), status: 204))])
    h.store.renameConversation(threadID: "thread-example", title: "Pending title")
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.requestConversationAction(.delete, threadID: "thread-example")
    h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    await h.store.independentOrganizeOperations["thread-example"]?.request?.value
    #expect(h.store.conversations["thread-example"] == nil)
    await h.transport.release(try response(["thread": sampleThread(revision: 9)]))
    await h.store.writeTasks["thread-example"]?.value
    #expect(h.store.conversations["thread-example"] == nil)
    await h.store.stop()
  }

  @Test func createdThreadSurvivesSseDropDuringPost() async throws {
    let h = try await ConversationActionTests().live()
    var created = try sampleThread()
    created.id = "created-example"
    await h.transport.set("/api/v1/threads", [.paused])
    let create = Task { try await h.store.createConversation(.init(sourceId: created.sourceId)) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.connection = .offline
    await h.transport.release(try response(["thread": created], status: 201))
    #expect(try await create.value == created.id)
    #expect(h.store.conversations[created.id] != nil)
    #expect(await h.transport.count("/api/v1/threads", method: "POST") == 1)
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func recreatedWakeCanRestartRevision(dirty: Bool) async throws {
    let helper = WakeStoreTests()
    var old = try helper.schedule(revision: 7)
    old.scheduleId = "old-schedule"
    let (h, id) = try await helper.opened(saved: old)
    if dirty {
      var draft = h.store.wakeEditor!.draft
      draft.message = "Unsaved"
      h.store.editWakeDraft(id, draft: draft)
    }
    var recreated = try helper.schedule()
    recreated.scheduleId = "new-schedule"
    await h.transport.set(
      helper.path,
      [
        .response(try response(["schedule": recreated])),
        .response(try response(["schedule": recreated])),
      ])
    await h.store.refreshWakeEditor(id)
    if dirty {
      #expect(h.store.wakeEditor?.changedElsewhere == true)
      #expect(h.store.wakeEditor?.schedule?.scheduleId == old.scheduleId)
      await h.store.refreshWakeEditor(id, explicit: true)
    }
    #expect(h.store.wakeEditor?.schedule?.scheduleId == recreated.scheduleId)
    #expect(h.store.conversations["thread-example"]?.thread.wakeSchedule?.revision == 1)
    await h.store.stop()
  }
}
