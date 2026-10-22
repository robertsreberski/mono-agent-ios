// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

/// Raw JSON keeps the format-marker regression executable against the unmarked decoder too.
@MainActor
func seedMarkedPreparations(_ h: Harness, count: Int) async throws {
  var journal = JournalRecord()
  journal.revision = 1
  journal.pending = (0..<count).map { _ in prepared(profileID: h.profile.id, createdAt: Date()) }
  var object = try #require(
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
  var entries = try #require(object["pending"] as? [[String: Any]])
  for index in entries.indices { entries[index]["dispatchProtocol"] = 1 }
  object["pending"] = entries
  let directory = h.directory.appendingPathComponent(h.profile.id.uuidString)
    .appendingPathComponent(h.store.namespace.identity)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try JSONSerialization.data(withJSONObject: object).write(
    to: directory.appendingPathComponent("journal-v1.json"))
}
@MainActor
struct CheckpointQueueRegressionTests {
  @Test func markedNeverDispatchedEntriesAreRetiredAtHydrateWithoutReceiptPolling() async throws {
    let h = Harness()
    try await seedMarkedPreparations(h, count: 50)
    await h.store.hydrate()
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    await h.store.recoverSubmissions()
    #expect(await h.transport.requests.isEmpty)
    await h.store.stop()
  }

  @Test func supersededMergeRespectsAnotherWritersDeletionOfUnchangedBaselineDraft() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "Original draft")
    await h.store.flushAuthored()
    var disk = try await h.repository.loadAuthored(h.store.namespace)
    disk.drafts = []
    disk.revision += 10
    try await h.repository.saveAuthored(disk, namespace: h.store.namespace)
    await h.store.setDraft(sourceID: "other-agent", text: "Independent new edit")
    await h.store.flushAuthored()
    let saved = try await h.repository.loadAuthored(h.store.namespace)
    #expect(saved.drafts.map(\.text) == ["Independent new edit"])
    #expect(h.store.draft(sourceID: "agent-example", threadID: "thread-example") == nil)
    #expect(h.store.authoredStorage == .durable)
    await h.store.stop()
  }

  @Test func aged404CannotRetireAnIdentityWhoseCheckpointChangedDuringGet() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    let input = ApiStartSubmission(submissionId: "", text: "Example retry")
    let old = try reference(
      profileID: h.profile.id, input: input,
      createdAt: now.addingTimeInterval(-ConsoleBounds.journal404Age), dispatched: true)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [old]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    let path = submissionPath + "/" + old.submissionID
    await h.transport.set(path, [.paused])
    let recovery = Task { await h.store.recoverSubmissions() }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.clock.advance(1)
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    let refreshed = try #require(h.store.pendingSubmissions.first?.lastDispatchedAt)
    #expect(await h.clock.wallNow() == refreshed)
    // Even if this old GET is held longer than the new retention age, it cannot judge the retry.
    await h.clock.advance(ConsoleBounds.journal404Age + 1)
    await h.transport.release(notFound())
    await recovery.value
    #expect(h.store.pendingSubmissions.first?.submissionID == old.submissionID)
    #expect(
      try await h.repository.loadJournal(h.store.namespace).pending.first?.lastDispatchedAt
        == refreshed)
    await h.transport.set(path, [.response(notFound())])
    await h.store.recoverSubmissions()
    #expect(h.store.pendingSubmissions.isEmpty)
    await h.store.stop()
  }

  @Test func queuedWriteDeadlineStartsAtEnqueueAndExpiredWriteNeverStarts() async throws {
    let h = Harness()
    let gate = WriteGate()
    let order = WriteOrder()
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await gate.wait()
      await order.record("old")
    }
    await eventually {
      let ready = await gate.ready()
      return await h.clock.pending() == 1 && ready
    }
    await h.clock.advance(5)
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await order.record("expired queued write")
    }
    var finished = false
    var timedOut = false
    let caller = Task {
      do { try await h.store.settleThreadWrites("thread-example") } catch SubmissionError
        .threadWriteTimeout
      { timedOut = true } catch { Issue.record("Unexpected settlement error") }
      finished = true
    }
    await eventually { await h.clock.pending() == 2 }
    await h.clock.advance(14.99)
    #expect(!finished)
    await h.clock.advance(0.01)
    await eventually { finished }
    #expect(timedOut)
    #expect(h.store.writeTasks.count == 1)
    #expect(await order.values.isEmpty)
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    await caller.value
    #expect(await order.values == ["old"])
    h.store.enqueueThreadWrite(threadID: "thread-example") { await order.record("new") }
    try await h.store.settleThreadWrites("thread-example")
    #expect(await order.values == ["old", "new"])
    await h.store.stop()
  }

  @Test(arguments: [false, true]) func cancellingSettlementDoesNotWaitForResultOrPhysicalCompletion(
    afterTimeout: Bool
  ) async throws {
    let h = Harness()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually {
      let ready = await gate.ready()
      return await h.clock.pending() == 1 && ready
    }
    if afterTimeout {
      await h.clock.advance(15)
      do {
        try await h.store.settleThreadWrites("thread-example")
        Issue.record("Expected timeout")
      } catch SubmissionError.threadWriteTimeout {}
    }
    var entered = false
    var cancelled = false
    let caller = Task {
      entered = true
      do {
        try await h.store.settleThreadWrites("thread-example")
        Issue.record("Expected caller cancellation")
      } catch is CancellationError { cancelled = true } catch {
        Issue.record("Unexpected cancellation result")
      }
    }
    await eventually { entered }
    caller.cancel()
    await eventually { cancelled }
    #expect(h.store.writeTasks.count == 1)
    await h.store.stop()
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    await caller.value
  }

  @Test func retainedInterruptedWriteAfterRestartHasVisibleRetryGuidance() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    await h.store.stop()
    await h.store.start()
    h.store.errorMessage = nil
    do {
      try await h.store.settleThreadWrites("thread-example")
      Issue.record("Interrupted physical write must not be bypassed")
    } catch is CancellationError {
      Issue.record("Foreground retained state needs visible retry guidance")
    } catch {}
    #expect(h.store.errorMessage?.contains("previous edit") == true)
    #expect(h.store.writeTasks.count == 1)
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    await h.store.stop()
  }
}
