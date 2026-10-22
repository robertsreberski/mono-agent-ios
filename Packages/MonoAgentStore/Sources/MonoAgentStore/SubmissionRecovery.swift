// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum SubmissionError: Error {
  case notReady, busy, journalUnavailable, threadWriteFailed, threadWriteTimeout
  case rejected(String)
  case uncertain
}
extension ConsoleStore {
  /// Thread creation is outside recovery, and is never retried by lifecycle effects.
  @discardableResult
  public func createConversation(_ input: ApiCreateThread) async throws -> String {
    let generation = epoch
    let selected = selection
    let value = try await api.createThread(body: input)
    let now = await clock.wallNow()
    guard epoch == generation, selection == selected, !backgrounded else {
      throw CancellationError()
    }
    hold(.init(thread: value.thread, messages: [], savedAt: now))
    await select(sourceID: value.thread.sourceId, threadID: value.thread.id)
    return value.thread.id
  }
  /// Explicit user action only. A prepared reference is durable before POST begins.
  public func submit(
    sourceID: String, threadID: String, input: ApiStartSubmission,
    draftContext: DraftKey? = nil
  ) async throws -> WebSubmissionReceipt {
    pruneTombstones()
    guard hydrated, !backgrounded, tombstones[threadID] == nil else {
      throw SubmissionError.notReady
    }
    guard !submitting.contains(threadID) else { throw SubmissionError.busy }
    guard journalStorage != .memoryOnly else { throw SubmissionError.journalUnavailable }
    if conversations[threadID]?.thread.archivedAt != nil { throw SubmissionError.notReady }
    submitting.insert(threadID)
    defer { submitting.remove(threadID) }
    let generation = epoch
    let key =
      draftContext ?? DraftKey(profileID: profile.id, sourceID: sourceID, threadID: threadID)
    var payload = input
    payload.submissionId = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = ConsoleNamespace.digest(
      String(decoding: try encoder.encode(payload), as: UTF8.self))
    let pending = journal.pending.last {
      $0.threadID == threadID && $0.payloadDigest == digest
        && !completedSubmissions.contains($0.submissionID)
    }
    payload.submissionId = pending?.submissionID ?? UUID().uuidString.lowercased()
    let now = await clock.wallNow()
    guard epoch == generation, !backgrounded else { throw CancellationError() }
    var reference = SubmissionReference(
      threadID: threadID, submissionID: payload.submissionId,
      payloadDigest: digest, draftKey: key,
      draftVersion: authored.drafts.first { $0.key == key }?.version,
      dispatched: pending?.dispatched ?? false, createdAt: pending?.createdAt ?? now,
      attachmentIDs: payload.attachmentIds ?? [])
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
    } catch {
      // No POST in this attempt. Do not abandon a prior genuinely dispatched attempt on retry.
      if !reference.dispatched { await retire(reference) }
      throw error
    }
    // Dispatch boundary: no suspension between claiming attachments/marking the reference and POST.
    // If killed inside POST, the durable prepared reference is still recovered by GET (never resend).
    reference.dispatched = true
    if let index = journal.pending.firstIndex(where: { $0.submissionID == reference.submissionID })
    {
      journal.pending[index] = reference
      journalRevision &+= 1
    }
    let attachments = Set(reference.attachmentIDs)
    for file in stagedAttachments where attachments.contains(file.id) {
      inFlightAttachments[file.id] = file
    }
    stagedAttachments.removeAll { attachments.contains($0.id) }
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
            definitive = true
            await retire(reference)
            await releaseAttachments(reference, admitted: false)
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
  func retire(_ reference: SubmissionReference) async {
    recordRetirement(reference.submissionID)
    journal.pending.removeAll {
      $0.submissionID == reference.submissionID && $0.threadID == reference.threadID
    }
    // Keep the in-memory retirement even if disk is unavailable. The next send must save a new UUID.
    try? await persistJournal()
  }
  public func recoverSubmissions() async {
    let generation = epoch
    for reference in journal.pending {
      guard epoch == generation, !backgrounded, !Task.isCancelled else { return }
      guard !recoveries.contains(reference.submissionID), !submitting.contains(reference.threadID)
      else { continue }
      recoveries.insert(reference.submissionID)
      do {
        let result = try await api.submissionReceipt(
          id: reference.threadID, submissionId: reference.submissionID, etag: nil)
        guard epoch == generation, !backgrounded, !Task.isCancelled else { return }
        if case .modified(let receipt, _) = result {
          try await confirm(receipt, reference: reference)
        }
      } catch {
        if let missing = error as? APIError, missing.status == 404, !reference.dispatched,
          await clock.wallNow().timeIntervalSince(reference.createdAt)
            >= ConsoleBounds.preparationAge
        {
          await retire(reference)
          await releaseAttachments(reference, admitted: false)
        }
      }
      if epoch == generation { recoveries.remove(reference.submissionID) }
    }
  }
  func releaseAttachments(_ reference: SubmissionReference, admitted: Bool) async {
    let files = reference.attachmentIDs.compactMap { inFlightAttachments.removeValue(forKey: $0) }
    if !admitted { await UploadService(api: api).discard(files) }
  }
  func confirm(_ receipt: WebSubmissionReceipt, reference: SubmissionReference) async throws {
    guard receipt.submissionId == reference.submissionID, receipt.threadId == reference.threadID,
      ["turn", "live-input", "rejected"].contains(receipt.outcome)
    else { throw SubmissionError.uncertain }
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
      authored.drafts.removeAll { $0.key == reference.draftKey && $0.version == version }
      authoredChanged()
      await flushAuthored()
      draftClearStorage[reference.submissionID] = authoredStorage
      draftClearOrder.removeAll { $0 == reference.submissionID }
      draftClearOrder.append(reference.submissionID)
      while draftClearOrder.count > 200 { draftClearStorage[draftClearOrder.removeFirst()] = nil }
    }
    await retire(reference)
    await releaseAttachments(reference, admitted: admitted)
    if receipt.reason == "compaction_busy" {
      await refreshDetail(receipt.threadId)
      await refreshBootstrap()
    }
  }
  public func cancel(threadID: String) async throws {
    let generation = epoch
    _ = try await api.cancelTurn(id: threadID, body: .init(origin: "user"))
    guard epoch == generation else { return }
    await refreshDetail(threadID)
  }
}
