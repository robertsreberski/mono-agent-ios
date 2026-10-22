// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct DeltaCorrectionTests {
  @Test func cancellationKeepsPhysicalTailAcrossRestart() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    let order = WriteOrder()
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await gate.wait()
      await order.record("old landed")
    }
    await eventually { await gate.ready() }
    h.store.enqueueThreadWrite(threadID: "thread-example") {
      await order.record("cancelled queued write")
    }
    let waiting = Task { try await h.store.settleThreadWrites("thread-example") }
    await h.store.stop()
    do {
      try await waiting.value
      Issue.record("Lifecycle cancellation must release queued callers")
    } catch is CancellationError {}
    #expect(h.store.writeTasks.count == 1)
    await h.store.start()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await order.record("new landed") }
    #expect(await order.values.isEmpty)
    await gate.release()
    try await h.store.settleThreadWrites("thread-example")
    #expect(await order.values == ["old landed", "new landed"])
    #expect(h.store.writeTasks.isEmpty)
    await h.store.stop()
  }

  @Test func dispatchedCheckpointSurvivesRelaunchAndFailedRetryPreflight() async throws {
    let first = Harness()
    await first.store.hydrate()
    let input = ApiStartSubmission(submissionId: "", text: "Example")
    await first.transport.set(submissionPath, [.paused])
    let original = Task {
      try await first.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await first.transport.pauseCount() == 1 }
    let disk = try await first.repository.loadJournal(first.store.namespace)
    let saved = try #require(disk.pending.first)
    #expect(saved.dispatched)
    await first.store.stop()
    let next = Harness(profile: first.profile, directory: first.directory)
    await next.store.hydrate()
    next.store.enqueueThreadWrite(threadID: "thread-example") {
      throw ConsoleStorageError.unavailable
    }
    do {
      _ = try await next.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input)
      Issue.record("Expected preflight failure")
    } catch SubmissionError.threadWriteFailed {}
    #expect(next.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    #expect(
      try await next.repository.loadJournal(next.store.namespace).pending.first?.submissionID
        == saved.submissionID)
    await next.transport.set(submissionPath, [.paused])
    let retry = Task {
      try await next.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await next.transport.pauseCount() == 1 }
    #expect(next.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await next.transport.release(try admission(saved))
    _ = try await retry.value
    await first.transport.release(try admission(saved))
    _ = try await original.value
    await next.store.stop()
  }

  @Test func failedDispatchedCheckpointPreventsPostAndRetainsStagedFiles() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.repository.failJournal([2])
    h.store.stagedAttachments = [try exampleAttachment()]
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", attachmentIds: ["upload-example"]))
      Issue.record("POST requires a durable dispatched checkpoint")
    } catch SubmissionError.journalUnavailable {}
    #expect(await h.transport.count(submissionPath, method: "POST") == 0)
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    await h.store.stop()
  }

  @Test func historicalPreparedIdentitySurvivesPreflightFailureAnd404() async throws {
    let h = Harness()
    let input = ApiStartSubmission(submissionId: "", text: "Historical retry")
    let saved = try reference(
      profileID: h.profile.id, input: input, createdAt: .distantPast, dispatched: false)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [saved]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { throw ConsoleStorageError.unavailable }
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.response(notFound())])
    await h.store.recoverSubmissions()
    #expect(h.store.pendingSubmissions.map(\.submissionID) == [saved.submissionID])
    #expect(await h.transport.count(submissionPath, method: "POST") == 0)
    await h.store.stop()
  }

  @Test(arguments: [false, true]) func attachmentClaimPrecedesSlowSettlementAndNavigation(
    background: Bool
  ) async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", attachmentIds: ["upload-example"]))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    #expect(h.store.protectedAttachmentIDs == ["upload-example"])
    if background {
      await h.store.scenePhaseChanged(.background)
    } else {
      await h.store.select(sourceID: "other-agent")
    }
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await gate.release()
    if background {
      _ = try? await send.value
      #expect(h.store.protectedAttachmentIDs.isEmpty)
      #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    } else {
      await eventually { await h.transport.pauseCount() == 1 }
      await h.transport.release(try admission(#require(h.store.pendingSubmissions.first)))
      _ = try await send.value
    }
    await h.store.stop()
  }

  @Test(arguments: [false, true]) func attachmentClaimAlreadyExistsDuringFirstJournalSave(
    background: Bool
  ) async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    await h.repository.pauseNextJournalSave()
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", attachmentIds: ["upload-example"]))
    }
    await eventually { await h.repository.isJournalPaused() }
    if background {
      await h.store.scenePhaseChanged(.background)
    } else {
      await h.store.select(sourceID: "other-agent")
    }
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs == ["upload-example"])
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await h.repository.releaseJournal()
    if background {
      _ = try? await send.value
    } else {
      await eventually { await h.transport.pauseCount() == 1 }
      await h.transport.release(try admission(#require(h.store.pendingSubmissions.first)))
      _ = try await send.value
    }
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    await h.store.stop()
  }

  @Test func uncertainAttachmentRetryKeepsDigestUUIDAndStagingUntilAdmission() async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    let input = ApiStartSubmission(
      submissionId: "", text: "Example", attachmentIds: ["upload-example"])
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    let uncertain = try #require(h.store.pendingSubmissions.first)
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    await h.transport.set(submissionPath, [.paused])
    let retry = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.pendingSubmissions.first?.submissionID == uncertain.submissionID)
    #expect(h.store.pendingSubmissions.first?.payloadDigest == uncertain.payloadDigest)
    await h.transport.release(try admission(uncertain))
    _ = try await retry.value
    #expect(h.store.stagedAttachments.isEmpty)
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await h.store.stop()
  }

  @Test func compactionRejectionKeepsFilesAndUnchangedRetryIdentityUntilUserAbandons() async throws
  {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    let input = ApiStartSubmission(submissionId: "", attachmentIds: ["upload-example"])
    await h.transport.set(submissionPath, [.paused, .paused])
    let send = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let saved = try #require(h.store.pendingSubmissions.first)
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.response(notFound())])
    await h.transport.release(
      HTTPResponse(
        data: Data(#"{"error":{"code":"compaction_busy","message":"Fictional busy state"}}"#.utf8),
        status: 409))
    _ = try? await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    let retry = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await h.transport.release(
      try response(
        JSONValue.object([
          "submissionId": .string(saved.submissionID), "threadId": .string(saved.threadID),
          "outcome": .string("rejected"),
        ]), status: 202))
    _ = try? await retry.value
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    await h.store.discardStagedUploads()
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 1)
    await h.store.stop()
  }

  @Test func journalCapacityEvictsOldestUncertainButNeverHistoricalPreparedIdentity() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    var journal = JournalRecord()
    journal.revision = 1
    for index in 0..<ConsoleBounds.journalCount {
      var saved = prepared(
        profileID: h.profile.id, createdAt: now.addingTimeInterval(-Double(index)), dispatched: true
      )
      saved.threadID = "thread-old-\(index)"
      journal.pending.append(saved)
    }
    let oldest = try #require(journal.pending.last)
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "New example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.pendingSubmissions.count == ConsoleBounds.journalCount)
    #expect(!h.store.pendingSubmissions.contains { $0.submissionID == oldest.submissionID })
    #expect(
      try await h.repository.loadJournal(h.store.namespace).pending.count
        == ConsoleBounds.journalCount)
    await h.transport.release(try admission(#require(h.store.pendingSubmissions.last)))
    _ = try await send.value
    await h.store.stop()
    let protected = Harness()
    journal.pending = (0..<ConsoleBounds.journalCount).map { _ in
      prepared(profileID: protected.profile.id, createdAt: .distantPast)
    }
    try await protected.repository.saveJournal(journal, namespace: protected.store.namespace)
    await protected.store.hydrate()
    do {
      _ = try await protected.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Another example"))
      Issue.record("Protected historical identities fill capacity")
    } catch SubmissionError.journalFull {}
    #expect(protected.store.pendingSubmissions.count == ConsoleBounds.journalCount)
    #expect(await protected.transport.count(submissionPath, method: "POST") == 0)
    await protected.store.stop()
  }

  @Test func backToBack404sCountOnceAndEqualRevisionFreshFetchLiftsNotFoundBarrier() async throws {
    let h = Harness()
    try h.seed(revision: 5)
    await h.transport.set(
      "/api/v1/threads/thread-example", Array(repeating: .response(notFound()), count: 4))
    await h.store.refreshDetail("thread-example")
    await h.store.refreshDetail("thread-example")
    #expect(h.store.tombstones.isEmpty)
    await h.clock.advance(4.99)
    await h.store.refreshDetail("thread-example")
    #expect(h.store.tombstones.isEmpty)
    await h.clock.advance(0.01)
    await h.store.refreshDetail("thread-example")
    let removed = try #require(h.store.tombstones["thread-example"])
    #expect(removed.origin == .notFound)
    #expect(await h.clock.wallNow() == removed.removedAt)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 5)], cursor: nil,
      older: false, fresh: true, fetchedAt: removed.removedAt.addingTimeInterval(-1))
    #expect(h.store.tombstones["thread-example"] != nil)
    await h.clock.advance(0.001)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 5)], cursor: nil,
      older: false, fresh: true, fetchedAt: await h.clock.wallNow())
    #expect(h.store.tombstones.isEmpty)
    h.store.removeThread("thread-example", now: await h.clock.wallNow())
    await h.clock.advance(1)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 5)], cursor: nil,
      older: false, fresh: true, fetchedAt: await h.clock.wallNow())
    #expect(h.store.tombstones["thread-example"]?.origin == .removed)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 6)], cursor: nil,
      older: false, fresh: true, fetchedAt: await h.clock.wallNow())
    #expect(h.store.tombstones.isEmpty)
    await h.store.stop()
  }

  @Test func legacyTombstoneWithoutOriginCanBeRepairedByFreshEqualRevisionRow() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    let legacy: ThreadTombstone = try JSONDecoder().decode(
      ThreadTombstone.self,
      from: JSONEncoder().encode(
        JSONValue.object([
          "revision": .number(5), "removedAt": .number(now.timeIntervalSinceReferenceDate),
        ])))
    #expect(legacy.origin == .legacyUnknown)
    h.store.tombstones["thread-example"] = legacy
    await h.clock.advance(0.001)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 5)], cursor: nil,
      older: false, fresh: true, fetchedAt: await h.clock.wallNow())
    #expect(h.store.tombstones.isEmpty)
    await h.store.stop()
  }

  @Test func freshBucketHTTPReadLiftsEqualRevisionNotFoundIncludingCacheRebase() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    h.store.tombstones["thread-example"] = .init(revision: 5, removedAt: now, origin: .notFound)
    let row = try sampleThread(revision: 5)
    let body = JSONValue.object([
      "threads": .array([try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(row))]
      ), "nextCursor": .null,
    ])
    await h.clock.advance(0.001)
    await h.transport.set("/api/v1/threads", [.response(try response(body))])
    await h.store.refreshBucket(.init(sourceID: "agent-example"))
    #expect(h.store.tombstones.isEmpty)
    #expect(h.store.buckets[.init(sourceID: "agent-example")]?.threads.first?.id == row.id)
    var disk = CacheRecord()
    disk.tombstones["thread-example"] = .init(revision: 5, removedAt: now, origin: .notFound)
    var local = CacheRecord()
    local.buckets = Array(h.store.buckets.values)
    #expect(CacheMerge.rebase(local, onto: disk).tombstones.isEmpty)
    disk.tombstones["thread-example"]?.origin = .removed
    #expect(CacheMerge.rebase(local, onto: disk).tombstones["thread-example"] != nil)
    await h.store.stop()
  }

  @Test func headlessFreshBootstrapLiftsEqualRevisionNotFoundBarrier() async throws {
    let h = Harness()
    let now = await h.clock.wallNow()
    var cache = CacheRecord()
    cache.revision = 1
    cache.tombstones["thread-example"] = .init(
      revision: try sampleThread().revision, removedAt: now, origin: .notFound)
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    await h.clock.advance(0.001)
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    let api = APIClient(endpoint: Scenario.endpoint, transport: h.transport)
    let service = ReconciliationService(
      repository: h.repository, clock: h.clock, client: { _ in api })
    let summary = try await service.refresh(profile: h.profile, budget: .init())
    #expect(summary.persisted)
    #expect(try await h.repository.loadCache(h.store.namespace).tombstones.isEmpty)
  }

  @Test func legacyReferenceWithoutDispatchMetadataCannotBeAgeEvictedAfter404() async throws {
    let h = Harness()
    let saved = prepared(profileID: h.profile.id, createdAt: Date(), dispatched: true)
    var fields = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    for key in ["dispatched", "createdAt", "historicalPreparation", "lastDispatchedAt"] {
      fields[key] = nil
    }
    let legacy = try JSONDecoder().decode(
      SubmissionReference.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(legacy.dispatched && legacy.historicalPreparation)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [legacy]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.response(notFound())])
    await h.store.recoverSubmissions()
    #expect(h.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await h.store.stop()
  }

  @Test func historicalPreparationStaysProtectedAfterDurableRetryCheckpointAndRejection()
    async throws
  {
    let h = Harness()
    let input = ApiStartSubmission(submissionId: "", text: "Historical example")
    let saved = try reference(
      profileID: h.profile.id, input: input, createdAt: .distantPast, dispatched: false)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [saved]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.store.hydrate()
    await h.transport.set(submissionPath, [.paused])
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.response(notFound())])
    let send = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let checkpoint = try #require(
      try await h.repository.loadJournal(h.store.namespace).pending.first)
    #expect(checkpoint.dispatched && checkpoint.historicalPreparation)
    await h.transport.release(
      HTTPResponse(
        data: Data(#"{"error":{"code":"compaction_busy","message":"Fictional busy state"}}"#.utf8),
        status: 409))
    _ = try? await send.value
    #expect(h.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await h.store.stop()
    let next = Harness(profile: h.profile, directory: h.directory)
    await next.store.hydrate()
    await next.clock.advance(ConsoleBounds.journal404Age + 1)
    await next.transport.set(submissionPath + "/" + saved.submissionID, [.response(notFound())])
    await next.store.recoverSubmissions()
    #expect(next.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    await next.store.stop()
  }

  @Test func repositoryRejectsOversizedJournalWithoutReplacingOriginal() async throws {
    let h = Harness()
    var journal = JournalRecord()
    journal.revision = 1
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    journal.revision = 2
    journal.pending = (0...ConsoleBounds.journalCount).map { _ in
      prepared(profileID: h.profile.id, createdAt: Date(), dispatched: true)
    }
    do {
      try await h.repository.saveJournal(journal, namespace: h.store.namespace)
      Issue.record("Entry count is a storage bound")
    } catch ConsoleStorageError.byteBudget {}
    #expect(try await h.repository.loadJournal(h.store.namespace).revision == 1)
  }

  @Test func supersededAuthoredMergePreservesOtherDraftsAndHighestSeenRevision() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Original")
    await h.store.flushAuthored()
    var disk = try await h.repository.loadAuthored(h.store.namespace)
    let original = try #require(disk.drafts.first)
    await h.store.setDraft(sourceID: "agent-example", text: "Local new draft")
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "")
    h.store.setSeen("thread-shared", revision: 2)
    h.store.setSeen("thread-local", revision: 10)
    var other = original
    other.version = UUID()
    other.text = "Other writer newer draft"
    other.updatedAt = original.updatedAt.addingTimeInterval(1)
    disk.drafts = [
      other,
      .init(
        key: .init(profileID: h.profile.id, sourceID: "other-agent"), text: "Other source draft",
        version: UUID(), updatedAt: other.updatedAt),
    ]
    disk.seen = [.init(id: "thread-shared", revision: 9), .init(id: "thread-other", revision: 8)]
    disk.revision = 100
    try await h.repository.saveAuthored(disk, namespace: h.store.namespace)
    await h.store.flushAuthored()
    let saved = try await h.repository.loadAuthored(h.store.namespace)
    #expect(
      Set(saved.drafts.map(\.text)) == [
        "Local new draft", "Other writer newer draft", "Other source draft",
      ])
    #expect(saved.seen.first { $0.id == "thread-shared" }?.revision == 9)
    #expect(saved.seen.first { $0.id == "thread-local" }?.revision == 10)
    #expect(saved.seen.first { $0.id == "thread-other" }?.revision == 8)
    #expect(h.store.authoredStorage == .durable)
    await h.store.stop()
  }

  @Test func lateAdmissionOnStoppedStoreCannotOverwriteRecreatedStoresDrafts() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Example")
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let saved = try #require(h.store.pendingSubmissions.first)
    await h.store.stop()
    let next = Harness(profile: h.profile, directory: h.directory)
    await next.store.hydrate()
    await next.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "New instance draft")
    await next.store.flushAuthored()
    let before = try await next.repository.loadAuthored(next.store.namespace)
    let writes = await h.repository.authoredSaves
    await h.transport.release(try admission(saved))
    _ = try await send.value
    let after = try await next.repository.loadAuthored(next.store.namespace)
    #expect(after.drafts == before.drafts)
    #expect(after.revision == before.revision)
    #expect(await h.repository.authoredSaves == writes)
    #expect(h.store.draftClearStorage[saved.submissionID] == .superseded)
    await next.store.stop()
  }

  @Test(arguments: [false, true])
  func recoveryCannotRetireOrReleaseAfterSameIdentityStartsSubmitting(receiptFound: Bool)
    async throws
  {
    let h = Harness()
    await h.store.hydrate()
    h.store.stagedAttachments = [try exampleAttachment()]
    let input = ApiStartSubmission(submissionId: "", attachmentIds: ["upload-example"])
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    h.store.journal.pending[0].createdAt = .distantPast
    h.store.journal.pending[0].lastDispatchedAt = nil
    try await h.store.persistJournal()
    let saved = try #require(h.store.pendingSubmissions.first)
    await h.transport.set(submissionPath + "/" + saved.submissionID, [.paused])
    let recovery = Task { await h.store.recoverSubmissions() }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(submissionPath, [.paused])
    let send = Task {
      try await h.store.submit(sourceID: "agent-example", threadID: "thread-example", input: input)
    }
    await eventually { await h.transport.pauseCount() == 2 }
    await h.transport.release(receiptFound ? try admission(saved, status: 200) : notFound())
    await recovery.value
    #expect(h.store.pendingSubmissions.first?.submissionID == saved.submissionID)
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(h.store.protectedAttachmentIDs == ["upload-example"])
    await h.transport.release(try admission(saved))
    _ = try await send.value
    #expect(h.store.pendingSubmissions.isEmpty)
    #expect(h.store.protectedAttachmentIDs.isEmpty)
    await h.store.stop()
  }
}
