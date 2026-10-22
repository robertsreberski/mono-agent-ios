// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor
struct RecoveryControlTests {
  @Test func fullLegacyJournalHasVisibleGuidanceAndExplicitAcknowledgedWayOut() async throws {
    let h = Harness()
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = (0..<ConsoleBounds.journalCount).map { index in
      var entry = prepared(profileID: h.profile.id, createdAt: .distantPast)
      entry.threadID = "thread-old-\(index)"
      return entry
    }
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
      Issue.record("Capacity must not silently forget legacy uncertainty")
    } catch SubmissionError.journalFull {}
    #expect(h.store.errorMessage?.contains("explicitly forget") == true)
    let id = try #require(h.store.pendingSubmissions.first?.submissionID)
    do {
      try await h.store.forgetRecoveryReference(id, acknowledgingPossibleAdmission: false)
      Issue.record("Risk acknowledgement is required")
    } catch SubmissionError.acknowledgementRequired {}
    #expect(h.store.pendingSubmissions.count == ConsoleBounds.journalCount)
    try await h.store.forgetRecoveryReference(id, acknowledgingPossibleAdmission: true)
    #expect(
      try await h.repository.loadJournal(h.store.namespace).pending.count == ConsoleBounds
        .journalCount - 1)
    #expect(await h.transport.requests.isEmpty)
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let current = try #require(h.store.pendingSubmissions.last)
    do {
      try await h.store.forgetRecoveryReference(
        current.submissionID, acknowledgingPossibleAdmission: true)
      Issue.record("An in-flight identity cannot be forgotten")
    } catch SubmissionError.busy {}
    await h.transport.release(try admission(current))
    _ = try await send.value
    await h.store.stop()
  }
  @Test func failedExplicitForgetIsNotReportedDurableAndCanBeRetried() async throws {
    let h = CorrectionHarness()
    var journal = JournalRecord()
    journal.revision = 1
    let entry = prepared(profileID: h.profile.id, createdAt: .distantPast)
    journal.pending = [entry]
    try await h.repository.base.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    await h.repository.failJournal([1])
    do {
      try await h.store.forgetRecoveryReference(
        entry.submissionID, acknowledgingPossibleAdmission: true)
      Issue.record("Forget must report a failed durable checkpoint")
    } catch ConsoleStorageError.unavailable {}
    #expect(h.store.journalStorage == .writeFailed)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.count == 1)
    try await h.store.forgetRecoveryReference(
      entry.submissionID, acknowledgingPossibleAdmission: true)
    #expect(h.store.journalStorage == .durable)
    #expect(try await h.repository.loadJournal(h.store.namespace).pending.isEmpty)
    await h.store.stop()
  }
  @Test func idleMarkedAndResolvedEntriesDoNotConsumeAdmissionCapacity() async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.journal.pending = (0..<ConsoleBounds.journalCount).map { _ in
      prepared(profileID: h.profile.id, createdAt: Date(), dispatchProtocol: 1)
    }
    let resolved = try #require(h.store.journal.pending.first)
    h.store.recordRetirement(resolved.submissionID)
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.pendingSubmissions.count == 1)
    let current = try #require(h.store.pendingSubmissions.first)
    #expect(current.dispatchProtocol == 1 && current.dispatched)
    await h.transport.release(try admission(current))
    _ = try await send.value
    await h.store.stop()
  }
}
