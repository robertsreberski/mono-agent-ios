// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public struct CronReplyNavigation: Equatable, Sendable {
  public let id: UUID
  public let sourceID: String
  public let threadID: String
}
public enum CronReplyPhase: String, Sendable { case idle, importing, retry, error }
@MainActor @Observable public final class CronReplyState {
  public internal(set) var phase: CronReplyPhase = .idle
  public internal(set) var message: String?
  @ObservationIgnored var task: Task<Void, Never>?
}

extension ConsoleStore {
  /// An import receipt is a snapshot, not an authoritative transcript window read.
  func holdCronReply(_ entry: CachedConversation) {
    if let held = conversations[entry.thread.id] {
      guard held.thread.revision <= entry.thread.revision else { return }
      // Receipts are not allowed to roll back live message history.
      let incoming = Dictionary(entry.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      guard
        !held.messages.contains(where: { message in
          guard let replacement = incoming[message.id] else { return true }
          return (message.seq ?? 0) > (replacement.seq ?? 0)
        })
      else { return }
    }
    hold(entry)
  }
  public func consumeCronReplyFocus(_ id: UUID) {
    if cronReplyNavigation?.id == id { cronReplyNavigation = nil }
  }
  public func cronReplySnapshot(_ key: CronReplyKey) -> CronReplyState? { cronReplies[key] }
  public func cronReplyPhase(_ key: CronReplyKey) -> CronReplyPhase {
    if cronReplyRecovery.isActive(key, namespace: namespace) { return .importing }
    if let state = cronReplies[key] { return state.phase }
    return cronReplyRecovery.reference(key, namespace: namespace) == nil ? .idle : .retry
  }
  public static func cronRunIsTerminal(_ status: String) -> Bool {
    ["succeeded", "failed", "cancelled", "skipped_overlap", "skipped_gate", "dropped"].contains(
      status)
  }
  /// Only explicit user activation calls this command. Hydration/foreground never replay it.
  public func replyToCronRun(sourceID: String, runID: String, snapshotKind: String) {
    let key: CronReplyKey
    guard let owner = automations[sourceID], let job = owner.job,
      let conversation = conversations[job.threadID],
      cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation),
      let status = cronRunStatus(job: job, conversation: conversation, runID: runID),
      Self.cronRunIsTerminal(status), ["summary", "detail"].contains(snapshotKind)
    else { return }
    key = .init(sourceID: sourceID, jobID: job.jobID, runID: runID)
    guard !cronReplyRecovery.isActive(key, namespace: namespace), cronReplies[key]?.task == nil
    else { return }
    if !cronReplyRecovery.isHydrated(namespace) {
      let state = cronReplies[key] ?? CronReplyState()
      cronReplies[key] = state
      state.phase = .importing
      let epoch = epoch
      let selected = selection
      let lifetime = job.lifetime
      let scope = cronScope(sourceID)
      let revision = owner.revision
      state.task = Task { [weak self, cronReplyRecovery, namespace] in
        await cronReplyRecovery.hydrate(namespace)
        state.task = nil
        guard let self, self.epoch == epoch, self.selection == selected,
          job.lifetime == lifetime, owner.revision == revision, self.cronScope(sourceID) == scope,
          self.cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation),
          !Task.isCancelled
        else {
          state.phase =
            cronReplyRecovery.reference(key, namespace: namespace) == nil ? .idle : .retry
          return
        }
        self.replyToCronRun(sourceID: sourceID, runID: runID, snapshotKind: snapshotKind)
      }
      return
    }
    let recovered = cronReplyRecovery.reference(key, namespace: namespace) != nil
    guard
      let reference = cronReplyRecovery.begin(key, snapshotKind: snapshotKind, namespace: namespace)
    else { return }
    let state = cronReplies[key] ?? CronReplyState()
    cronReplies[key] = state
    state.phase = .importing
    state.message = nil
    let epoch = epoch
    let selected = selection
    let lifetime = job.lifetime
    let scope = cronScope(sourceID)
    let revision = owner.revision
    state.task = Task { [weak self, cronReplyRecovery, namespace] in
      guard let self else {
        cronReplyRecovery.finish(key, namespace: namespace)
        return
      }
      defer {
        cronReplyRecovery.finish(key, namespace: namespace)
        state.task = nil
        if state.phase == .importing { state.phase = .retry }
      }
      @MainActor func current() -> Bool {
        self.epoch == epoch && self.selection == selected && job.lifetime == lifetime
          && self.cronScope(sourceID) == scope && owner.revision == revision
          && self.cronReplies[key] === state && !Task.isCancelled
          && self.cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation)
      }
      guard current(),
        Self.cronRunIsTerminal(
          self.cronRunStatus(
            job: job, conversation: conversation, runID: runID) ?? "")
      else {
        // No dispatch occurred. Only a newly allocated identity is provably safe to retire.
        if !recovered { cronReplyRecovery.forget(reference, namespace: namespace) }
        state.phase = recovered ? .retry : .idle
        return
      }
      do {
        let receipt = try await self.api.createCronReply(
          id: sourceID, jobId: key.jobID, runId: runID,
          body: .init(
            operationId: reference.operationID.uuidString.lowercased(),
            snapshotKind: reference.snapshotKind))
        guard UUID(uuidString: receipt.operationId) == reference.operationID,
          receipt.sourceId == sourceID, receipt.jobId == key.jobID, receipt.runId == runID,
          receipt.thread.sourceId == sourceID, !receipt.thread.id.isEmpty,
          receipt.thread.id != job.threadID, receipt.messages.count == 1,
          receipt.messages.allSatisfy({ $0.threadId == receipt.thread.id })
        else { throw APIError(status: 502, code: "mismatched_cron_reply_receipt") }
        let publish = current()
        self.cronOutcome(sourceID)
        let outcomeRevision = owner.revision
        // A known deletion always wins, even an equal/newer receipt must not navigate.
        guard self.tombstones[receipt.thread.id] == nil else {
          cronReplyRecovery.forget(reference, namespace: namespace)
          if publish {
            state.phase = .error
            state.message = "This imported conversation was deleted."
          }
          return
        }
        // A validated receipt settles identity even when its initiating view has left.
        cronReplyRecovery.forget(reference, namespace: namespace)
        state.phase = .idle
        state.message = nil
        guard publish else { return }
        let now = await self.clock.wallNow()
        // The clock is injectable and may suspend: recheck lifetime after that suspension.
        guard self.epoch == epoch, self.selection == selected, job.lifetime == lifetime,
          self.cronScope(sourceID) == scope, owner.revision == outcomeRevision,
          self.tombstones[receipt.thread.id] == nil,
          self.cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation)
        else { return }
        self.holdCronReply(.init(thread: receipt.thread, messages: receipt.messages, savedAt: now))
        self.patchSummary(receipt.thread)
        let bucket = BucketKey(sourceID: sourceID)
        if self.buckets[bucket] == nil {
          self.buckets[bucket] = ThreadBucket(key: bucket, threads: [], savedAt: now)
        }
        if self.buckets[bucket]?.threads.contains(where: { $0.id == receipt.thread.id }) != true {
          self.buckets[bucket]?.threads.insert(receipt.thread, at: 0)
        }
        self.noteSummary(receipt.thread)
        // Route owner handles navigation and composer focus; no caller-supplied IDs are used.
        self.cronReplyNavigation = .init(
          id: UUID(), sourceID: sourceID, threadID: receipt.thread.id)
        self.scheduleCache()
      } catch {
        let publish = current()
        self.cronOutcome(sourceID)
        let apiError = error as? APIError
        if let operationID = apiError?.cronReplyPendingOperationID {
          cronReplyRecovery.replace(reference, operationID: operationID, namespace: namespace)
        }
        let preflight = ["cron_reply_agent_offline", "cron_reply_unsupported"].contains(
          apiError?.code ?? "")
        let definitive =
          [
            "cron_reply_agent_offline", "cron_reply_conflict", "cron_reply_failed",
            "cron_reply_gone",
            "cron_reply_operation_conflict", "cron_reply_run_not_found", "cron_reply_unavailable",
            "cron_reply_detail_unavailable", "cron_reply_unsupported",
          ].contains(apiError?.code ?? "") && !(recovered && preflight)
        if definitive { cronReplyRecovery.forget(reference, namespace: namespace) }
        guard publish else { return }
        state.phase = definitive ? .error : .retry
        state.message =
          definitive
          ? apiError?.safeDetails ?? "Reply could not be imported."
          : apiError?.code == "cron_reply_pending"
            ? "Another Reply for this result is still being delivered. Use Retry Reply to continue it — no duplicate conversation will be created."
              + (apiError?.cronReplyPendingSince.map { " (since " + $0.formatted() + ")" } ?? "")
            : "Reply outcome is unknown. Retry Reply reuses the same operation and snapshot."
      }
    }
  }
}
