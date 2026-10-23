// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum SubmissionError: Error {
  case notReady, busy, journalUnavailable, threadWriteFailed, threadWriteTimeout
  case rejected(String)
  case uncertain, journalFull, acknowledgementRequired, threadWriteInterrupted
}
/// Frozen authored context: `.none` is for quick replies, never the visible draft.
public enum SubmissionDraftBinding: Sendable, Equatable {
  case current
  case none
  case version(DraftKey, UUID?)
}

extension ConsoleStore {
  /// Thread creation is outside recovery, and is never retried by lifecycle effects.
  /// `retainingAttachments` keeps the new-conversation composer's staged files across this
  /// command's own selection change, so the first submission can still reference them.
  @discardableResult
  public func createConversation(
    _ input: ApiCreateThread, retainingAttachments attachmentIDs: [String] = []
  ) async throws -> String {
    let generation = epoch
    let selected = selection
    let claim = UUID()
    attachmentClaims[claim] = Set(attachmentIDs)
    defer { attachmentClaims[claim] = nil }
    let value = try await api.createThread(body: input)
    let now = await clock.wallNow()
    guard epoch == generation, selection == selected, !backgrounded else {
      throw CancellationError()
    }
    hold(.init(thread: value.thread, messages: [], savedAt: now))
    await select(sourceID: value.thread.sourceId, threadID: value.thread.id)
    return value.thread.id
  }
  /// Allocates an identity owned by this explicit attempt, independent of journal retirement.
  public func prepareSubmission(_ input: ApiStartSubmission, threadID: String? = nil)
    -> ApiStartSubmission
  {
    var input = input
    input.submissionId = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = (try? encoder.encode(input)).map {
      ConsoleNamespace.digest(String(decoding: $0, as: UTF8.self))
    }
    input.submissionId =
      journal.pending.last {
        $0.threadID == threadID && $0.payloadDigest == digest
      }?.submissionID ?? UUID().uuidString.lowercased()
    return input
  }
  /// Explicit user action only. A prepared reference is durable before POST begins.
  public func submit(
    sourceID: String, threadID: String, input: ApiStartSubmission,
    draftContext: DraftKey? = nil, draftBinding: SubmissionDraftBinding = .current
  ) async throws -> WebSubmissionReceipt {
    if let known = knownSubmissionReceipts[input.submissionId], known.threadId == threadID {
      if known.outcome == "rejected" { throw SubmissionError.rejected(known.reason ?? "rejected") }
      return known
    }
    pruneTombstones()
    guard hydrated, !backgrounded, tombstones[threadID] == nil else {
      throw SubmissionError.notReady
    }
    guard !submitting.contains(threadID) else { throw SubmissionError.busy }
    guard journalStorage != .memoryOnly else { throw SubmissionError.journalUnavailable }
    if conversations[threadID]?.thread.archivedAt != nil { throw SubmissionError.notReady }
    trimJournal()
    submitting.insert(threadID)
    let claim = UUID()
    attachmentClaims[claim] = Set(input.attachmentIds ?? [])
    defer {
      submitting.remove(threadID)
      attachmentClaims[claim] = nil
    }
    let generation = epoch
    let key =
      draftContext ?? DraftKey(profileID: profile.id, sourceID: sourceID, threadID: threadID)
    var payload = input
    payload.submissionId = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = ConsoleNamespace.digest(
      String(decoding: try encoder.encode(payload), as: UTF8.self))
    let pending =
      journal.pending.last {
        $0.threadID == threadID && $0.payloadDigest == digest
          && (input.submissionId.isEmpty || $0.submissionID == input.submissionId)
          && !completedSubmissions.contains($0.submissionID)
      }
      ?? retryIdentities[threadID].flatMap {
        $0.payloadDigest == digest
          && (input.submissionId.isEmpty || $0.submissionID == input.submissionId)
          ? $0 : nil
      }
    payload.submissionId =
      input.submissionId.isEmpty
      ? pending?.submissionID ?? UUID().uuidString.lowercased() : input.submissionId
    let now = await clock.wallNow()
    guard epoch == generation, !backgrounded else { throw CancellationError() }
    let isLocalPreparation =
      pending == nil || retryIdentities[threadID]?.submissionID == pending?.submissionID
    if isLocalPreparation {
      try makeJournalRoom()
      preparedHere.insert(payload.submissionId)
      completedSubmissions.remove(payload.submissionId)
    }
    let boundKey: DraftKey
    let boundVersion: UUID?
    switch pending.map({ SubmissionDraftBinding.version($0.draftKey, $0.draftVersion) })
      ?? draftBinding
    {
    case .current:
      boundKey = pending?.draftKey ?? key
      boundVersion =
        pending == nil
        ? authored.drafts.first { $0.key == key }?.version : pending?.draftVersion
    case .none:
      boundKey = key
      boundVersion = nil
    case .version(let key, let version):
      boundKey = key
      boundVersion = version
    }
    var reference = SubmissionReference(
      threadID: threadID, submissionID: payload.submissionId,
      payloadDigest: digest, draftKey: boundKey,
      draftVersion: boundVersion,
      dispatched: pending?.dispatched ?? false,
      createdAt: isLocalPreparation ? now : pending?.createdAt ?? now,
      attachmentIDs: payload.attachmentIds ?? [],
      historicalPreparation: pending?.historicalPreparation ?? false,
      lastDispatchedAt: pending?.lastDispatchedAt, dispatchProtocol: pending?.dispatchProtocol ?? 1)
    journal.pending.removeAll { $0.submissionID == reference.submissionID }
    journal.pending.append(reference)
    do {
      do { try await persistJournal() } catch { throw SubmissionError.journalUnavailable }
      try Task.checkCancellation()
      guard epoch == generation, !backgrounded else { throw CancellationError() }
      await flushAuthored()
      guard authoredStorage != .writeFailed, authoredStorage != .superseded else {
        throw SubmissionError.notReady
      }
      try await settleThreadWrites(threadID)
      try Task.checkCancellation()
      guard epoch == generation, !backgrounded else { throw CancellationError() }
      // The durable checkpoint must say "possibly dispatched" before any POST can start.
      let dispatchTime = await clock.wallNow()
      try Task.checkCancellation()
      guard epoch == generation, !backgrounded else { throw CancellationError() }
      reference.dispatched = true
      reference.lastDispatchedAt = dispatchTime
      if let index = journal.pending.firstIndex(where: { $0.submissionID == reference.submissionID }
      ) {
        journal.pending[index] = reference
      }
      do { try await persistJournal() } catch { throw SubmissionError.journalUnavailable }
      try Task.checkCancellation()
      guard epoch == generation, !backgrounded else { throw CancellationError() }
    } catch {
      // Only this process can prove that its own fresh identity never reached POST.
      if preparedHere.contains(reference.submissionID) { await retire(reference, retryable: true) }
      throw error
    }
    preparedHere.remove(reference.submissionID)
    retryIdentities[threadID] = nil
    var definitive = false
    do {
      let receipt: WebSubmissionReceipt
      do {
        receipt = try await api.startSubmission(id: threadID, body: payload)
      } catch {
        let dispatchError = error
        try? await persistJournal()
        if let apiError = error as? APIError, apiError.code == "compaction_busy" {
          await refreshDetail(threadID)
          await refreshBootstrap()
        }
        do {
          receipt = try await api.submissionReceipt(
            id: threadID, submissionId: payload.submissionId, etag: nil
          ).valueRequired()
        } catch {
          if let missing = error as? APIError, missing.status == 404,
            let rejection = dispatchError as? APIError, (400...499).contains(rejection.status),
            ![408, 425, 429].contains(rejection.status)
          {
            // A definitive dispatch rejection plus authoritative absent receipt proves no admission.
            // This rejection says nothing about a previous ambiguous attempt with the same UUID.
            definitive = pending == nil || isLocalPreparation
            if definitive { await retire(reference, retryable: true) }
            throw dispatchError
          }
          throw error
        }
      }
      // A known receipt still owns journal cleanup when selection/background changed meanwhile.
      try await confirm(receipt, reference: reference)
      definitive = true
      if receipt.outcome == "rejected" {
        throw SubmissionError.rejected(receipt.reason ?? "rejected")
      }
      return receipt
    } catch {
      if epoch == generation {
        errorMessage =
          definitive
          ? "The console rejected this submission. Your draft is retained."
          : "Submission is uncertain. Recovery checks its receipt without sending again."
      }
      throw error
    }
  }
  func persistJournal() async throws {
    journalRevision &+= 1
    journal.revision &+= 1
    var savingRevision = journal.revision
    var retired = completedSubmissions
    do {
      var result = try await repository.saveJournal(journal, namespace: namespace)
      if case .superseded = result {
        let disk = try await repository.loadJournal(namespace)
        let ids = Set(journal.pending.map(\.submissionID))
        journal.pending += disk.pending.filter {
          !ids.contains($0.submissionID) && !completedSubmissions.contains($0.submissionID)
        }
        journal.revision = max(journal.revision, disk.revision) + 1
        savingRevision = journal.revision
        retired = completedSubmissions
        result = try await repository.saveJournal(journal, namespace: namespace)
      }
      guard result == .saved else {
        if journal.revision == savingRevision { journalStorage = .superseded }
        throw ConsoleStorageError.superseded
      }
      completedSubmissions.subtract(retired)
      retirementOrder.removeAll { !completedSubmissions.contains($0) }
      if journal.revision == savingRevision { journalStorage = .durable }
    } catch ConsoleStorageError.superseded { throw ConsoleStorageError.superseded } catch {
      journalStorage = .writeFailed
      errorMessage = "Submission journal is not durable; sending is disabled until it can be saved."
      throw error
    }
  }
  func recordRetirement(_ id: String) {
    completedSubmissions.insert(id)
    retirementOrder.removeAll { $0 == id }
    retirementOrder.append(id)
    while retirementOrder.count > 256 { completedSubmissions.remove(retirementOrder.removeFirst()) }
  }
  func retire(_ reference: SubmissionReference, retryable: Bool = false) async {
    preparedHere.remove(reference.submissionID)
    if retryable {
      var retry = reference
      retry.dispatched = false
      retryIdentities[reference.threadID] = retry
      if retryIdentities.count > ConsoleBounds.journalCount {
        let oldest = retryIdentities.min { $0.value.createdAt < $1.value.createdAt }?.key
        if let oldest { retryIdentities[oldest] = nil }
      }
    } else {
      retryIdentities[reference.threadID] = nil
    }
    recordRetirement(reference.submissionID)
    journal.pending.removeAll {
      $0.submissionID == reference.submissionID && $0.threadID == reference.threadID
    }
    // Keep the in-memory retirement even if disk is unavailable. The next send must save a new UUID.
    try? await persistJournal()
  }
  /// Never evict a historical prepared identity: a previous process may have sent it.
  func trimJournal(reserving: Int = 0) {
    let removable = journal.pending.filter {
      completedSubmissions.contains($0.submissionID)
        || ($0.provablyUndispatched && !submitting.contains($0.threadID)
          && !recoveries.contains($0.submissionID))
    }
    let ids = Set(removable.map(\.submissionID))
    for reference in removable { recordRetirement(reference.submissionID) }
    journal.pending.removeAll { ids.contains($0.submissionID) }
    if !ids.isEmpty { journalRevision &+= 1 }
    while journal.pending.count + reserving > ConsoleBounds.journalCount {
      guard
        let oldest = journal.pending.filter({
          $0.dispatched && !$0.historicalPreparation && !submitting.contains($0.threadID)
            && !recoveries.contains($0.submissionID)
        }).min(by: { $0.createdAt < $1.createdAt })
      else { return }
      errorMessage =
        "Recovery history reached its limit. Check the conversation before retrying older uncertain messages."
      recordRetirement(oldest.submissionID)
      journal.pending.removeAll { $0.submissionID == oldest.submissionID }
      journalRevision &+= 1
    }
  }
  func makeJournalRoom() throws {
    trimJournal(reserving: 1)
    guard journal.pending.count < ConsoleBounds.journalCount else {
      errorMessage =
        "Recovery journal is full. Check the conversation for earlier admissions, then explicitly forget an uncertain reference to make room. Forgetting cannot undo an admitted message."
      throw SubmissionError.journalFull
    }
  }
  /// Explicit user acknowledgement only. Never sends or deletes uploads; forgetting is not undo.
  public func forgetRecoveryReference(_ id: String, acknowledgingPossibleAdmission: Bool)
    async throws
  {
    guard acknowledgingPossibleAdmission else { throw SubmissionError.acknowledgementRequired }
    if let reference = journal.pending.first(where: { $0.submissionID == id }) {
      guard !submitting.contains(reference.threadID), !recoveries.contains(id) else {
        throw SubmissionError.busy
      }
      preparedHere.remove(id)
      retryIdentities[reference.threadID] = nil
      recordRetirement(id)
      journal.pending.removeAll { $0.submissionID == id }
      journalRevision &+= 1
    }
    if completedSubmissions.contains(id) { try await persistJournal() }
    errorMessage =
      "Recovery reference forgotten. Check the conversation before sending again; the earlier message may already be admitted."
  }
  public func recoverSubmissions() async {
    let generation = epoch
    for snapshot in journal.pending {
      guard epoch == generation, !backgrounded, !Task.isCancelled else { return }
      guard
        let reference = journal.pending.first(where: { $0.submissionID == snapshot.submissionID }),
        !recoveries.contains(reference.submissionID), !submitting.contains(reference.threadID)
      else { continue }
      recoveries.insert(reference.submissionID)
      do {
        let result = try await api.submissionReceipt(
          id: reference.threadID, submissionId: reference.submissionID, etag: nil)
        guard epoch == generation, !backgrounded, !Task.isCancelled else { return }
        if !submitting.contains(reference.threadID),
          let live = journal.pending.first(where: { $0.submissionID == reference.submissionID }),
          case .modified(let receipt, _) = result
        {
          try await confirm(receipt, reference: live)
        }
      } catch {
        let now = await clock.wallNow()
        guard epoch == generation, !backgrounded, !Task.isCancelled else { return }
        if !submitting.contains(reference.threadID),
          let live = journal.pending.first(where: { $0.submissionID == reference.submissionID }),
          live.lastDispatchedAt == reference.lastDispatchedAt,
          let missing = error as? APIError, missing.status == 404, live.dispatched,
          !live.historicalPreparation,
          now.timeIntervalSince(live.lastDispatchedAt ?? live.createdAt)
            >= ConsoleBounds.journal404Age
        {
          errorMessage =
            "An old uncertain reference expired. Check the conversation before sending again."
          await retire(live)
        }
      }
      if epoch == generation { recoveries.remove(reference.submissionID) }
    }
  }
  func confirm(_ receipt: WebSubmissionReceipt, reference: SubmissionReference) async throws {
    guard receipt.submissionId == reference.submissionID, receipt.threadId == reference.threadID,
      ["turn", "live-input", "rejected"].contains(receipt.outcome)
    else { throw SubmissionError.uncertain }
    knownSubmissionReceipts[receipt.submissionId] = receipt
    receiptOrder.removeAll { $0 == receipt.submissionId }
    receiptOrder.append(receipt.submissionId)
    while receiptOrder.count > 200 { knownSubmissionReceipts[receiptOrder.removeFirst()] = nil }
    let admitted = receipt.outcome != "rejected"
    // Known admission permanently retires retry identity, regardless of draft-clear durability.
    recordRetirement(reference.submissionID)
    if !backgrounded, let message = receipt.message, let state = conversations[receipt.threadId],
      tombstones[receipt.threadId] == nil
    {
      TranscriptMerge.insert(
        message, into: &state.record.messages, repaired: state.record.repairedToolCallIDs)
      if let turn = receipt.turn {
        state.record.thread.runState = turn
        state.runningConfirmed = true
      }
      state.publish()
      scheduleCache()
    }
    if admitted, let version = reference.draftVersion {
      noteDraftRemoval(version)
      authored.drafts.removeAll { $0.key == reference.draftKey && $0.version == version }
      authoredChanged()
      await flushAuthored()
      draftClearStorage[reference.submissionID] = authoredStorage
      draftClearOrder.removeAll { $0 == reference.submissionID }
      draftClearOrder.append(reference.submissionID)
      while draftClearOrder.count > 200 { draftClearStorage[draftClearOrder.removeFirst()] = nil }
    }
    await retire(reference)
    if admitted {
      let ids = Set(reference.attachmentIDs)
      stagedAttachments.removeAll { ids.contains($0.id) }
    }
    if receipt.reason == "compaction_busy" {
      await refreshDetail(receipt.threadId)
      await refreshBootstrap()
    }
  }
  /// The operator's Stop. `user-stop` is the contract's origin for it (web `cancelTurn`).
  public func cancel(threadID: String) async throws {
    let generation = epoch
    let value = try await api.cancelTurn(id: threadID, body: .init(origin: "user-stop"))
    guard epoch == generation else { return }
    patchSummary(value.thread)
    await refreshDetail(threadID)
  }
}
