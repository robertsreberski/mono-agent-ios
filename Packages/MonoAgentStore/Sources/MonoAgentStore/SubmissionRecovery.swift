// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum SubmissionError: Error {
  case notReady, busy, journalUnavailable
  case rejected(String)
  case uncertain
}
extension ConsoleStore {
  /// Serializes thread-affecting writes. C8/C10 enqueue settings/project edits through this seam.
  public func enqueueThreadWrite(
    threadID: String, operation: @escaping @Sendable () async throws -> Void
  ) {
    let previous = writeTasks[threadID]
    writeTasks[threadID] = Task {
      _ = try? await previous?.value
      try Task.checkCancellation()
      try await operation()
    }
  }
  public func settleThreadWrites(_ threadID: String) async throws {
    try await writeTasks[threadID]?.value
  }
  /// A new conversation is created outside submission recovery: it is never re-created by GET recovery.
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
  /// Explicit user action only. No lifecycle/stream path calls this method.
  public func submit(
    sourceID: String, threadID: String, input: ApiStartSubmission, draftContext: DraftKey? = nil
  ) async throws -> WebSubmissionReceipt {
    guard hydrated, !backgrounded, !tombstones.contains(threadID) else {
      throw SubmissionError.notReady
    }
    guard !submitting.contains(threadID) else { throw SubmissionError.busy }
    guard journalStorage != .memoryOnly else { throw SubmissionError.journalUnavailable }
    if let thread = conversations[threadID]?.thread, thread.archivedAt != nil {
      throw SubmissionError.notReady
    }
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
    let pending = journal.pending.last { $0.threadID == threadID && $0.payloadDigest == digest }
    payload.submissionId = pending?.submissionID ?? UUID().uuidString.lowercased()
    let reference = SubmissionReference(
      threadID: threadID, submissionID: payload.submissionId,
      payloadDigest: digest, draftKey: key,
      draftVersion: authored.drafts.first { $0.key == key }?.version)
    journal.pending.removeAll { $0.submissionID == reference.submissionID }
    journal.pending.append(reference)
    // A failed pre-dispatch journal write prevents POST. Never claim memory-only recovery is durable.
    do { try await persistJournal() } catch { throw SubmissionError.journalUnavailable }
    guard epoch == generation, !backgrounded else { throw CancellationError() }
    await flushAuthored()
    guard authoredStorage == .durable else { throw SubmissionError.notReady }
    try await settleThreadWrites(threadID)
    guard epoch == generation, !backgrounded else { throw CancellationError() }
    do {
      let receipt: WebSubmissionReceipt
      do { receipt = try await api.startSubmission(id: threadID, body: payload) } catch {
        if let error = error as? APIError, error.code == "compaction_busy" {
          await refreshDetail(threadID)
          await refreshBootstrap()
        }
        // The request may have reached the server. Resolve through GET, never replay POST.
        receipt = try await api.submissionReceipt(
          id: threadID, submissionId: payload.submissionId, etag: nil
        ).valueRequired()
      }
      guard epoch == generation, !backgrounded else { throw CancellationError() }
      try await confirm(receipt, reference: reference)
      if receipt.outcome == "rejected" {
        errorMessage = "The console rejected this submission. Your draft is retained."
        throw SubmissionError.rejected(receipt.reason ?? "rejected")
      }
      let admitted = Set(payload.attachmentIds ?? [])
      stagedAttachments.removeAll { admitted.contains($0.id) }
      return receipt
    } catch {
      if epoch == generation {
        if let rejection = error as? SubmissionError, case .rejected = rejection {
          errorMessage = "The console rejected this submission. Your draft is retained."
        } else {
          errorMessage =
            "Submission is uncertain. Recovery checks its receipt without sending again."
        }
      }
      throw error
    }
  }
  func persistJournal() async throws {
    journalRevision &+= 1
    journal.revision &+= 1
    let record = journal
    do {
      try await repository.saveJournal(record, namespace: namespace)
      journalStorage = .durable
    } catch {
      journalStorage = .writeFailed
      errorMessage = "Submission journal is not durable; sending is disabled until it can be saved."
      throw error
    }
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
        guard epoch == generation, !backgrounded, !Task.isCancelled else {
          if epoch == generation { recoveries.remove(reference.submissionID) }
          return
        }
        if case .modified(let receipt, _) = result {
          try await confirm(receipt, reference: reference)
        }
      } catch {
        // Keep the durable reference. Unknown/not-found is not permission to resend.
      }
      if epoch == generation { recoveries.remove(reference.submissionID) }
    }
  }
  func confirm(_ receipt: WebSubmissionReceipt, reference: SubmissionReference) async throws {
    guard receipt.submissionId == reference.submissionID, receipt.threadId == reference.threadID,
      ["turn", "live-input", "rejected"].contains(receipt.outcome)
    else { throw SubmissionError.uncertain }
    if let message = receipt.message, let state = conversations[receipt.threadId],
      !tombstones.contains(receipt.threadId)
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
    // Persist draft removal before forgetting the journal. A crash between these is idempotent.
    if ["turn", "live-input"].contains(receipt.outcome), let version = reference.draftVersion {
      authored.drafts.removeAll { $0.key == reference.draftKey && $0.version == version }
      authoredChanged()
      await flushAuthored()
      guard authoredStorage == .durable else { return }
    }
    journal.pending.removeAll {
      $0.submissionID == reference.submissionID && $0.threadID == reference.threadID
    }
    do { try await persistJournal() } catch {
      // Preserve retry identity in memory too when the removal did not reach disk.
      if !journal.pending.contains(reference) { journal.pending.append(reference) }
      throw error
    }
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
