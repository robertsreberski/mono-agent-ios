// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct WakeStoreTests {
  let path = "/api/v1/threads/thread-example/wake-schedule"
  func schedule(revision: Int = 1, state: String = "active", message: String = "Garden review")
    throws -> WebWakeSchedule
  {
    let value: JSONValue = .object([
      "scheduleId": .string("wake-example"), "threadId": .string("thread-example"),
      "sourceId": .string("agent-example"),
      "definition": .object([
        "kind": .string("weekly"), "timezone": .string("UTC"), "days": .array([.number(1)]),
        "times": .array([.string("09:00")]), "message": .string(message),
      ]), "state": .string(state), "revision": .number(Double(revision)), "nextFireAt": .null,
      "lastOutcome": .null, "createdAt": .string("2031-05-01T00:00:00Z"),
    ])
    return try JSONDecoder().decode(WebWakeSchedule.self, from: JSONEncoder().encode(value))
  }
  func opened(saved: WebWakeSchedule? = nil) async throws -> (Harness, UUID) {
    let h = try await ConversationActionTests().live()
    let id = try #require(h.store.openWakeEditor(threadID: "thread-example"))
    await h.transport.set(path, [.response(try response(["schedule": saved]))])
    await h.store.refreshWakeEditor(id)
    #expect(h.store.wakeEditor?.loaded == true)
    return (h, id)
  }
  @Test func initialReadFailureRetriesAndNewScheduleElsewhereKeepsDraft() async throws {
    let h = try await ConversationActionTests().live()
    let id = try #require(h.store.openWakeEditor(threadID: "thread-example"))
    await h.transport.set(
      path,
      [
        .failure, .response(try response(["schedule": Optional<WebWakeSchedule>.none])),
        .response(try response(["schedule": schedule()])),
      ])
    await h.store.refreshWakeEditor(id)
    #expect(h.store.wakeEditor?.loaded == false)
    #expect(h.store.wakeEditor?.failure != nil)
    await h.store.refreshWakeEditor(id)
    #expect(h.store.wakeEditor?.loaded == true)
    let original = h.store.wakeEditor?.draft
    await h.store.refreshWakeEditor(id)
    #expect(h.store.wakeEditor?.changedElsewhere == true)
    #expect(h.store.wakeEditor?.schedule == nil)
    #expect(h.store.wakeEditor?.draft == original)
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func lateReadCannotTouchReplacementOrSelection(replace: Bool)
    async throws
  {
    let (h, id) = try await opened(saved: schedule())
    await h.transport.set(path, [.paused])
    let read = Task { await h.store.refreshWakeEditor(id, explicit: true) }
    await eventually { await h.transport.pauseCount() == 1 }
    if replace {
      h.store.closeWakeEditor(id)
      _ = h.store.openWakeEditor(threadID: "thread-example")
    } else {
      h.store.selection += 1
    }
    await h.transport.release(try response(["schedule": schedule(revision: 2)]))
    await read.value
    #expect(h.store.wakeEditor?.schedule?.revision != 2)
    await h.store.stop()
  }
  @Test func expiredOnceCannotResumeAndArchivedPauseIsAllowed() async throws {
    var saved = try schedule(state: "paused")
    saved.definition = .init(kind: "once", timezone: "UTC", localAt: "2000-01-01T09:00")
    let (h, id) = try await opened(saved: saved)
    h.store.mutateWakeEditor(id, action: .resume)
    #expect(h.store.wakeEditor?.failure?.message.contains("time has passed") == true)
    #expect(await h.transport.count(path) == 1)
    h.store.conversations["thread-example"]?.thread.archivedAt = "2031-05-01T00:00:00Z"
    await h.transport.set(path, [.response(try response(["schedule": schedule(state: "paused")]))])
    h.store.mutateWakeEditor(id, action: .pause)
    try await h.store.settleThreadWrites("thread-example")
    #expect(await h.transport.count(path) == 2)
    await h.store.stop()
  }

  @Test func createsAndUpdatesOnlyAfterConfirmedQueuedResponse() async throws {
    let (h, id) = try await opened()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    await h.transport.set(path, [.paused])
    h.store.mutateWakeEditor(id, action: .save)
    #expect(h.store.wakeEditor?.busy == .save)
    #expect(h.store.conversations["thread-example"]?.thread.wakeSchedule == nil)
    #expect(await h.transport.count(path) == 1)
    await gate.release()
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(try response(["schedule": schedule()], status: 201))
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.wakeEditor == nil)
    #expect(h.store.conversations["thread-example"]?.thread.wakeSchedule?.revision == 1)
    await h.store.stop()
  }
  @Test func conflictRetainsDraftAndBaselineUntilExplicitReload() async throws {
    let saved = try schedule()
    let latest = try schedule(revision: 2, message: "Updated elsewhere")
    let (h, id) = try await opened(saved: saved)
    var draft = h.store.wakeEditor!.draft
    draft.message = "Unsaved edit"
    h.store.editWakeDraft(id, draft: draft)
    await h.transport.set(path, [.response(try response(["schedule": latest]))])
    await h.store.refreshWakeEditor(id)
    #expect(h.store.wakeEditor?.changedElsewhere == true)
    #expect(h.store.wakeEditor?.draft.message == "Unsaved edit")
    #expect(h.store.wakeEditor?.schedule?.revision == 1)
    await h.transport.set(
      path,
      [
        .response(
          .init(
            data: Data(#"{"error":{"code":"wake_revision_conflict","message":"Reload"}}"#.utf8),
            status: 409))
      ])
    h.store.mutateWakeEditor(id, action: .save)
    try? await h.store.settleThreadWrites("thread-example")
    await eventually { h.store.wakeEditor?.busy == nil }
    #expect(h.store.wakeEditor?.failure?.conflict == true)
    #expect(h.store.wakeEditor?.draft.message == "Unsaved edit")
    await h.transport.set(path, [.response(try response(["schedule": latest]))])
    await h.store.refreshWakeEditor(id, explicit: true)
    #expect(h.store.wakeEditor?.schedule?.revision == 2)
    #expect(h.store.wakeEditor?.draft.message == "Updated elsewhere")
    #expect(h.store.wakeEditor?.failure == nil)
    await h.store.stop()
  }
  @Test func deletedElsewhereReloadKeepsEditsForRecreate() async throws {
    let (h, id) = try await opened(saved: schedule())
    var draft = h.store.wakeEditor!.draft
    draft.message = "Keep edits"
    h.store.editWakeDraft(id, draft: draft)
    await h.transport.set(
      path, [.response(try response(["schedule": Optional<WebWakeSchedule>.none]))])
    await h.store.refreshWakeEditor(id, explicit: true)
    #expect(h.store.wakeEditor?.schedule == nil)
    #expect(h.store.wakeEditor?.draft.message == "Keep edits")
    await h.store.stop()
  }
  @Test func pauseFailureAndDeletionConfirmationAreNonDestructive() async throws {
    let (h, id) = try await opened(saved: schedule())
    await h.transport.set(
      path,
      [.failure, .response(try response(["schedule": schedule(revision: 2, state: "paused")]))])
    h.store.mutateWakeEditor(id, action: .pause)
    try? await h.store.settleThreadWrites("thread-example")
    await eventually { h.store.wakeEditor?.busy == nil }
    #expect(h.store.wakeEditor?.schedule?.state == "active")
    #expect(h.store.wakeEditor?.failure != nil)
    h.store.mutateWakeEditor(id, action: .pause)
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.wakeEditor?.schedule?.state == "paused")
    h.store.requestWakeDeletion(id)
    let cancelled = try #require(h.store.wakeEditor?.deletionConfirmation)
    h.store.cancelWakeDeletion(id)
    h.store.confirmWakeDeletion(id, confirmation: cancelled)
    h.store.mutateWakeEditor(id, action: .delete)
    #expect(await h.transport.count(path) == 3)
    await h.transport.set(path, [.failure, .response(.init(data: Data(), status: 204))])
    h.store.requestWakeDeletion(id)
    h.store.confirmWakeDeletion(
      id, confirmation: try #require(h.store.wakeEditor?.deletionConfirmation))
    try? await h.store.settleThreadWrites("thread-example")
    await eventually { h.store.wakeEditor?.busy == nil }
    #expect(h.store.wakeEditor?.schedule != nil)
    h.store.requestWakeDeletion(id)
    h.store.confirmWakeDeletion(
      id, confirmation: try #require(h.store.wakeEditor?.deletionConfirmation))
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.wakeEditor == nil)
    #expect(h.store.conversations["thread-example"] != nil)
    #expect(h.store.conversations["thread-example"]?.thread.wakeSchedule == nil)
    await h.store.stop()
  }
  @Test(arguments: [0, 1, 2, 3, 4]) func lateReadsAndWritesCannotReachAnotherLifetime(change: Int)
    async throws
  {
    let (h, id) = try await opened(saved: schedule())
    await h.transport.set(path, [.paused])
    h.store.mutateWakeEditor(id, action: .pause)
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case 0:
      h.store.closeWakeEditor(id)
      _ = h.store.openWakeEditor(threadID: "thread-example")
    case 1: h.store.selection += 1
    case 2: h.store.epoch += 1
    case 3: h.store.backgrounded = true
    default: h.store.connection = .offline
    }
    await h.transport.release(try response(["schedule": schedule(revision: 2, state: "paused")]))
    try? await h.store.settleThreadWrites("thread-example")
    #expect(h.store.conversations["thread-example"]?.thread.wakeSchedule?.revision == 1)
    #expect(h.store.wakeEditor?.schedule?.revision != 2)
    await h.store.stop()
  }
  @Test func overlappedReadDoesNotRewindMutationAndReruns() async throws {
    let (h, id) = try await opened(saved: schedule())
    await h.transport.set(
      path,
      [
        .paused, .response(try response(["schedule": schedule(revision: 2, state: "paused")])),
        .response(try response(["schedule": schedule(revision: 2, state: "paused")])),
      ])
    let read = Task { await h.store.refreshWakeEditor(id) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.mutateWakeEditor(id, action: .pause)
    try await h.store.settleThreadWrites("thread-example")
    await h.transport.release(try response(["schedule": schedule()]))
    await read.value
    await eventually { await h.transport.count(path) == 4 }
    #expect(h.store.wakeEditor?.schedule?.revision == 2)
    await h.store.stop()
  }
  @Test func guardArchivedExpiredInvalidUnavailableAndLatestRead() async throws {
    let (h, id) = try await opened(saved: schedule())
    h.store.conversations["thread-example"]?.thread.archivedAt = "2031-05-01T00:00:00Z"
    var draft = h.store.wakeEditor!.draft
    draft.message = "Edit"
    h.store.editWakeDraft(id, draft: draft)
    h.store.mutateWakeEditor(id, action: .save)
    h.store.mutateWakeEditor(id, action: .resume)
    #expect(await h.transport.count(path) == 1)
    h.store.conversations["thread-example"]?.thread.archivedAt = nil
    draft.times = ["09:00", "09:00"]
    h.store.editWakeDraft(id, draft: draft)
    h.store.mutateWakeEditor(id, action: .save)
    #expect(await h.transport.count(path) == 1)
    await h.transport.set(
      path, [.paused, .response(try response(["schedule": schedule(revision: 3)]))])
    let read = Task { await h.store.refreshWakeEditor(id, explicit: true) }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.refreshWakeEditor(id, explicit: true)
    await h.transport.release(try response(["schedule": schedule(revision: 2)]))
    await read.value
    #expect(h.store.wakeEditor?.schedule?.revision == 3)
    h.store.connection = .offline
    h.store.mutateWakeEditor(id, action: .pause)
    await h.store.refreshWakeEditor(id)
    #expect(await h.transport.count(path) == 3)
    await h.store.stop()
  }
}
