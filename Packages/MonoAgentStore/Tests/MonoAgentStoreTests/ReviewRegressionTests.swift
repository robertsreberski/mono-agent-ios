// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

/// Uses only the pre-correction API so these regressions can also run against the old implementation.
@MainActor
struct ReviewRegressionTests {
  @Test func timeoutDoesNotReleasePhysicalWriteOrdering() async throws {
    let h = Harness()
    let gate = WriteGate()
    let order = WriteOrder()
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await gate.wait()
      await order.record("old")
    }
    await eventually { await gate.ready() }
    let first = Task { try await h.store.settleThreadWrites("thread-example") }
    await eventually { await h.clock.pending() == 1 }
    await h.clock.advance(15)
    do {
      try await first.value
      Issue.record("Expected deadline")
    } catch SubmissionError.threadWriteTimeout {}
    #expect(h.store.writeTasks.count == 1)
    h.store.enqueueThreadWrite(threadID: "thread-example") { await order.record("new") }
    await h.clock.advance(1)
    await gate.release()
    try await h.store.settleThreadWrites("thread-example")
    await eventually { await order.values.count == 2 }
    #expect(await order.values == ["old", "new"])
    await h.store.stop()
  }
  @Test func dispatchedCheckpointFailureMustPreventEveryPost() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.repository.failJournal([2])
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example",
      input: .init(submissionId: "", text: "Example"))
    #expect(await h.transport.count(submissionPath, method: "POST") == 0)
    #expect(h.store.pendingSubmissions.isEmpty)
    await h.store.stop()
  }
  @Test func uncertainFailureLeavesAttachmentsAvailableForIdenticalRetry() async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example",
      input: .init(submissionId: "", attachmentIds: ["upload-example"]))
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    await h.store.stop()
  }
  @Test func navigationDuringSettlementCannotDeleteClaimedAttachment() async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", attachmentIds: ["upload-example"]))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    await h.store.select(sourceID: "other-agent")
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await gate.release()
    _ = try? await send.value
    await h.store.stop()
  }
  @Test func repositoryRejectsFiftyOneJournalEntries() async throws {
    let h = Harness()
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = (0..<51).map { _ in
      prepared(profileID: h.profile.id, createdAt: Date(), dispatched: true)
    }
    do {
      try await h.repository.saveJournal(journal, namespace: h.store.namespace)
      Issue.record("Must enforce journal entry bound")
    } catch ConsoleStorageError.byteBudget {}
  }
  @Test func immediateRepair404sAreNotIndependentDeletionConfirmation() async throws {
    let h = Harness()
    try h.seed(revision: 5)
    await h.transport.set(
      "/api/v1/threads/thread-example", [.response(notFound()), .response(notFound())])
    await h.store.refreshDetail("thread-example")
    await h.store.refreshDetail("thread-example")
    #expect(h.store.conversations["thread-example"] != nil)
    #expect(h.store.tombstones.isEmpty)
    await h.store.stop()
  }
  @Test func supersededAuthoredWriterCannotEraseUnrelatedDraft() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", text: "Local draft")
    var disk = AuthoredRecord()
    disk.revision = 100
    disk.drafts = [
      .init(
        key: .init(profileID: h.profile.id, sourceID: "other-agent"), text: "Other writer draft",
        version: UUID(), updatedAt: Date())
    ]
    try await h.repository.saveAuthored(disk, namespace: h.store.namespace)
    await h.store.flushAuthored()
    #expect(
      Set(try await h.repository.loadAuthored(h.store.namespace).drafts.map(\.text)) == [
        "Local draft", "Other writer draft",
      ])
    await h.store.stop()
  }
  @Test func recoveryReplyCannotSettleAnIdentityWhileItsRetryIsPosting() async throws {
    let h = Harness()
    await h.store.hydrate()
    let input = ApiStartSubmission(submissionId: "", text: "Example")
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    let saved = try #require(h.store.pendingSubmissions.first)
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.paused])
    let recovery = Task { await h.store.recoverSubmissions() }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(submissionPath, [.paused])
    let retry = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 2 }
    await h.transport.release(try admission(saved, status: 200))
    await recovery.value
    #expect(h.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await h.transport.release(try admission(saved))
    _ = try await retry.value
    await h.store.stop()
  }
}
