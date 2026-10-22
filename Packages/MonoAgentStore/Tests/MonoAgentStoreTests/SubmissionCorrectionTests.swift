// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor
struct SubmissionCorrectionTests {
  @Test func failedWriteIsReportedOnceThenLaterSubmitSucceedsAndTailDrains() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await gate.wait()
      throw ConsoleStorageError.unavailable
    }
    await eventually { await gate.ready() }
    let first = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    #expect(h.store.pendingSubmissions.first?.dispatched == false)
    await gate.release()
    do {
      _ = try await first.value
      Issue.record("Failed write must prevent this send")
    } catch SubmissionError.threadWriteFailed {}
    #expect(h.store.writeTasks.isEmpty)
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    await h.transport.set(submissionPath, [.paused])
    let second = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(try admission(#require(h.store.pendingSubmissions.first)))
    _ = try await second.value
    #expect(await h.transport.count(submissionPath, method: "POST") == 1)
    await h.store.stop()
  }
  @Test func hungThreadWriteReportsDeadlineButRetainsOrderingUntilActualCompletion() async throws {
    let h = Harness()
    let gate = WriteGate()
    let order = WriteOrder()
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await gate.wait()
      await order.record("old landed")
    }
    await eventually { await gate.ready() }
    let settle = Task { try await h.store.settleThreadWrites("thread-example") }
    await eventually { await h.clock.pending() == 1 }
    await h.clock.advance(14.99)
    #expect(h.store.writeTasks.count == 1)
    await h.clock.advance(0.01)
    do {
      try await settle.value
      Issue.record("Deadline must fail settlement")
    } catch SubmissionError.threadWriteTimeout {}
    #expect(h.store.writeTasks.count == 1)
    h.store.enqueueThreadWrite(threadID: "thread-example") { await order.record("new landed") }
    await h.clock.advance(0.01)
    #expect(await order.values.isEmpty)
    await gate.release()
    try await h.store.settleThreadWrites("thread-example")
    #expect(await order.values == ["old landed", "new landed"])
    #expect(h.store.writeTasks.isEmpty)
    h.store.enqueueThreadWrite(threadID: "thread-example") { await order.record("last landed") }
    try await h.store.settleThreadWrites("thread-example")
    #expect(await order.values == ["old landed", "new landed", "last landed"])
    await h.store.stop()
  }
  @Test func failedPreDispatchAuthoredFlushLeavesNoDurableGhost() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.repository.failAuthored([1])
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
      Issue.record("Expected write failure")
    } catch SubmissionError.notReady {}
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    #expect(await h.transport.count(submissionPath) == 0)
    await h.store.stop()
  }
  @Test func backgroundDuringPreDispatchSettlementRemovesPreparedReference() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    await h.store.scenePhaseChanged(.background)
    _ = try? await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    #expect(await h.transport.count(submissionPath) == 0)
    await gate.release()
    await h.store.stop()
  }
  @Test func callerCancellationBeforePostRemovesPreparedJournalEntry() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    send.cancel()
    await gate.release()
    _ = try? await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    #expect(await h.transport.count(submissionPath) == 0)
    await h.store.stop()
  }
  @Test func markedUndispatchedRetiresAtHydrateWhileLegacyAndRecentDispatchedRemain() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    let historical = prepared(profileID: h.profile.id, createdAt: .distantPast)
    let marked = prepared(profileID: h.profile.id, createdAt: now, dispatchProtocol: 1)
    let recent = prepared(profileID: h.profile.id, createdAt: now, dispatched: true)
    let expired = prepared(
      profileID: h.profile.id, createdAt: now.addingTimeInterval(-ConsoleBounds.journal404Age),
      dispatched: true)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [historical, marked, recent, expired]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    for reference in journal.pending {
      await h.transport.set(submissionPath + "/" + reference.submissionID, [.response(notFound())])
    }
    await h.store.hydrate()
    #expect(!h.store.pendingSubmissions.contains { $0.submissionID == marked.submissionID })
    await h.store.recoverSubmissions()
    #expect(await h.transport.count(submissionPath + "/" + marked.submissionID) == 0)
    #expect(
      Set(h.store.pendingSubmissions.map(\.submissionID)) == [
        historical.submissionID, recent.submissionID,
      ])
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.count == 2)
    #expect(await h.transport.count(submissionPath, method: "POST") == 0)
    await h.store.stop()
  }
  @Test func compactionRejectionWith404ReceiptRetiresJournal() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(h.store.pendingSubmissions.first)
    #expect(reference.dispatched)
    await h.transport.set(submissionPath + "/" + reference.submissionID, [.response(notFound())])
    await h.transport.release(
      HTTPResponse(
        data: Data(#"{"error":{"code":"compaction_busy","message":"Fictional busy state"}}"#.utf8),
        status: 409))
    _ = try? await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    #expect(await h.transport.count("/api/v1/bootstrap") == 1)
    #expect(await h.transport.count("/api/v1/threads/thread-example") == 1)
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func onlyAuthoredFileCorruptionDoesNotDisableSending(newer: Bool)
    async throws
  {
    let h = Harness()
    let directory = h.directory.appendingPathComponent(h.profile.id.uuidString)
      .appendingPathComponent(h.store.namespace.identity)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      (newer ? #"{"version":999,"revision":1,"dataMode":"auto","drafts":[],"seen":[]}"# : "broken")
        .utf8
    ).write(to: directory.appendingPathComponent("authored-v1.json"))
    await h.store.hydrate()
    #expect(h.store.authoredStorage == .memoryOnly)
    #expect(h.store.journalStorage == .durable)
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Example")
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(h.store.pendingSubmissions.first)
    await h.transport.release(try admission(reference))
    _ = try await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(h.store.draftClearStorage[reference.submissionID] == .memoryOnly)
    await h.store.stop()
  }
  @Test func knownAdmissionRetiresUUIDWhenDraftClearWriteFails() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.repository.failAuthored([2])
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "continue")
    await h.transport.set(submissionPath, [.paused, .paused])
    var ids: [String] = []
    for _ in 0..<2 {
      let send = Task {
        try await h.store.submit(
          sourceID: "agent-example", threadID: "thread-example",
          input: .init(submissionId: "", text: "continue"))
      }
      await eventually { await h.transport.pauseCount() == 1 }
      let reference = try #require(h.store.pendingSubmissions.first)
      ids.append(reference.submissionID)
      await h.transport.release(try admission(reference))
      _ = try await send.value
      #expect(h.store.pendingSubmissions.isEmpty)
      await h.store.setDraft(
        sourceID: "agent-example", threadID: "thread-example", text: "continue")
    }
    #expect(ids[0] != ids[1])
    #expect(h.store.draftClearStorage[ids[0]] == .writeFailed)
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func attachmentsAreNotDeletedWhilePostIsInFlight(background: Bool)
    async throws
  {
    let h = Harness()
    await h.store.hydrate()
    let attachment = try decode(
      #"{"id":"upload-example","name":"sample.txt","contentType":"text/plain","sizeBytes":4,"kind":"file","status":"ready","uploaded":true,"createdAt":"2030-01-02T12:00:00Z"}"#,
      as: WebAttachment.self)
    h.store.stagedAttachments = [attachment]
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", attachmentIds: [attachment.id]))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(h.store.pendingSubmissions.first)
    if background {
      await h.store.scenePhaseChanged(.background)
    } else {
      await h.store.select(sourceID: "other-agent")
    }
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    #expect(h.store.inFlightAttachments.count == 1)
    await h.transport.release(try admission(reference))
    _ = try await send.value
    #expect(h.store.inFlightAttachments.isEmpty)
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await h.store.stop()
  }
}
