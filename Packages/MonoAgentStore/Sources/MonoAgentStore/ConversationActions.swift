// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum ConversationAction: String, Sendable, Identifiable {
  case archive, delete
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .archive: "Archive conversation"
    case .delete: "Permanently delete"
    }
  }
  public var confirmation: String {
    switch self {
    case .archive:
      "Archive this conversation? Empty conversations will be permanently removed. Conversations with messages remain available in Archived."
    case .delete:
      "Permanently delete this conversation and its attachments? This cannot be undone."
    }
  }
}

public struct ConversationActionConfirmation: Sendable, Identifiable {
  public let id: UUID
  public let threadID: String
  public let action: ConversationAction
  let epoch: UInt64
  let selection: UInt64
}

public enum ManualCompactionState: Sendable, Equatable {
  case pending
  case result(AgentManualCompactionResult)
  case failed
  case rejected

  public var text: String { statusText(measuredModel: nil) }
  public func statusText(measuredModel: String?) -> String {
    switch self {
    case .rejected: "Compaction failed."
    case .pending: "Summarizing earlier turns…"
    case .failed: "Connection lost — the outcome is unknown. Refresh this conversation."
    case .result(let result):
      switch result.status {
      case "succeeded":
        if let before = result.tokensBefore, let after = result.tokensAfter {
          "Compacted · \(UsagePresentation.tokens(before)) → \(result.tokenCountsExact == true ? "" : "≈")\(UsagePresentation.tokens(after))"
        } else {
          "Compacted."
        }
      case "skipped":
        result.reason == "model_changed"
          ? "Switch back to \(measuredModel ?? "this conversation's model") to compact this session."
          : "Nothing to compact yet."
      default: "Compaction failed."
      }
    }
  }
}

/// Captures the same lifetime, selection and held-row identity at enqueue AND dispatch.
struct OrganizeContext {
  let epoch: UInt64
  let selection: UInt64
  let held: ConversationState
}

@MainActor final class IndependentOrganizeOperation {
  var request: Task<Void, Never>?
  var deadline: Task<Void, Never>?
}

extension ConsoleStore {
  public var canOrganize: Bool {
    started && !stopping && !stopped && !backgrounded && connection == .live
  }

  public func canDeleteConversation(_ thread: WebThread) -> Bool {
    thread.archivedAt != nil
      && (thread.trigger?.kind != "cron" || thread.trigger?.configured == false)
  }

  public func canCompactConversation(_ thread: WebThread) -> Bool {
    canOrganize && thread.archivedAt == nil && thread.trigger?.kind != "cron" && thread.canSend
      && thread.runState.status != "running"
      && thread.compaction?.status != "running"
      && manualCompactions[thread.id] != .pending
      && agents.first(where: { $0.sourceId == thread.sourceId })?.supportsManualCompaction == true
      && agents.first(where: { $0.sourceId == thread.sourceId })?.status != "offline"
  }

  public func requestConversationAction(_ action: ConversationAction, threadID: String) {
    guard canOrganize, pendingConversationActions[threadID] == nil,
      let thread = conversations[threadID]?.thread,
      action != .delete || canDeleteConversation(thread)
    else { return }
    conversationActionConfirmation = .init(
      id: UUID(), threadID: threadID, action: action, epoch: epoch, selection: selection)
  }

  public func cancelConversationAction() { conversationActionConfirmation = nil }

  /// Consumes a one-shot confirmation; a stale/cancelled prompt cannot dispatch a mutation.
  public func confirmConversationAction(_ id: UUID) {
    guard let request = conversationActionConfirmation, request.id == id else { return }
    conversationActionConfirmation = nil
    guard request.epoch == epoch, request.selection == selection, canOrganize,
      let thread = conversations[request.threadID]?.thread
    else { return }
    switch request.action {
    case .archive: queueConversationPatch(threadID: thread.id, body: .init(archived: true))
    case .delete:
      guard canDeleteConversation(thread) else { return }
      runIndependentConversationOperation(
        threadID: thread.id, timeout: ConsoleBounds.threadWriteTimeout
      ) { store, context in
        try await store.api.deleteThread(id: thread.id, query: .init())
        guard store.organizeContextIsCurrent(context, threadID: thread.id) else {
          throw CancellationError()
        }
        store.completeConversationDeletion(thread.id)
      }

    }
  }

  /// One-click, context-popover-only command, matching the web CompactFooter.
  public func compactConversation(threadID: String) {
    guard let thread = conversations[threadID]?.thread, canCompactConversation(thread),
      pendingConversationActions[threadID] == nil
    else { return }
    manualCompactions[threadID] = .pending
    runIndependentConversationOperation(
      threadID: threadID, timeout: APIClient.manualCompactionTimeout
    ) { store, context in
      let result: ApiCompaction
      do { result = try await store.api.compact(id: threadID, body: .init()) } catch {
        if store.organizeContextIsCurrent(context, threadID: threadID) {
          store.manualCompactions[threadID] = error is APIError ? .rejected : .failed
        }
        throw error
      }
      guard store.organizeContextIsCurrent(context, threadID: threadID) else {
        throw CancellationError()
      }
      store.manualCompactions[threadID] = .result(result)
    }
  }

  public func clearCompactionResult(threadID: String) {
    if manualCompactions[threadID] != .pending { manualCompactions[threadID] = nil }
  }

  public func renameConversation(threadID: String, title: String) {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    queueConversationPatch(threadID: threadID, body: .init(title: value))
  }

  public func restoreConversation(threadID: String) {
    queueConversationPatch(threadID: threadID, body: .init(archived: false))
  }

  func organizeContextIsCurrent(_ context: OrganizeContext, threadID: String) -> Bool {
    canOrganize && epoch == context.epoch && selection == context.selection
      && conversations[threadID] === context.held && !Task.isCancelled
  }

  func queueConversationPatch(threadID: String, body: ApiPatchThread) {
    queueConversationOperation(threadID: threadID) { store, context in
      let saved = try await store.api.patchThread(id: threadID, body: body).thread
      guard store.organizeContextIsCurrent(context, threadID: threadID) else {
        throw CancellationError()
      }
      store.observe(threadID)
      store.patchSummary(saved)
      if body.archived != nil {
        let archived = saved.archivedAt != nil
        for key in store.buckets.keys where key.sourceID == saved.sourceId {
          if key.archived != archived {
            store.buckets[key]?.threads.removeAll { $0.id == saved.id }
          } else if store.buckets[key]?.threads.contains(where: { $0.id == saved.id }) == false {
            store.buckets[key]?.threads.insert(saved, at: 0)
          }
        }
      }
      for id in store.projectMembers.keys {
        store.projectMembers[id]?.threads.removeAll { $0.id == saved.id }
        if saved.projectId == id, saved.archivedAt == nil {
          store.projectMembers[id]?.threads.insert(saved, at: 0)
        }
      }
      // The web archive confirmation explicitly includes removal of empty conversations.
      if body.archived == true, saved.trigger == nil, saved.messageCount == 0 {
        do {
          try await store.api.deleteThread(id: threadID, query: .init(emptyOnly: true))
          guard store.organizeContextIsCurrent(context, threadID: threadID) else {
            throw CancellationError()
          }
          store.completeConversationDeletion(threadID)
        } catch let error as APIError where error.code == "thread_not_empty" {
          // Activity arrived after the archive: the successful archive still stands.
        }
      }
      store.scheduleCache()
      if body.archived != nil, store.selectedThreadID == threadID {
        store.selectedThreadID = nil
        store.selection &+= 1
        store.visible = false
      }
    }
  }

  /// Delete has no row snapshot to serialize; compaction has its own longer budget.
  /// Neither waits out an unrelated queued write before dispatching.
  private func runIndependentConversationOperation(
    threadID: String, timeout: TimeInterval,
    operation: @escaping @MainActor @Sendable (ConsoleStore, OrganizeContext) async throws -> Void
  ) {
    guard canOrganize, pendingConversationActions[threadID] == nil,
      let held = conversations[threadID]
    else { return }
    let context = OrganizeContext(epoch: epoch, selection: selection, held: held)
    let token = UUID()
    let state = IndependentOrganizeOperation()
    pendingConversationActions[threadID] = token
    independentOrganizeOperations[threadID] = state
    state.request = Task { [weak self] in
      guard let self else { return }
      var failed = false
      do {
        guard self.organizeContextIsCurrent(context, threadID: threadID) else {
          throw CancellationError()
        }
        try await operation(self, context)
      } catch { failed = !(error is CancellationError) }
      guard self.pendingConversationActions[threadID] == token else { return }
      state.deadline?.cancel()
      self.independentOrganizeOperations[threadID] = nil
      self.pendingConversationActions[threadID] = nil
      if self.manualCompactions[threadID] == .pending { self.manualCompactions[threadID] = nil }
      guard self.organizeContextIsCurrent(context, threadID: threadID) else { return }
      self.errorMessage =
        failed && self.manualCompactions[threadID] == nil
        ? "The conversation change was not confirmed. Refresh before retrying." : nil
    }
    state.deadline = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: timeout) } catch { return }
      guard let self, self.pendingConversationActions[threadID] == token else { return }
      state.request?.cancel()
      self.independentOrganizeOperations[threadID] = nil
      self.pendingConversationActions[threadID] = nil
      guard self.organizeContextIsCurrent(context, threadID: threadID) else {
        if self.manualCompactions[threadID] == .pending { self.manualCompactions[threadID] = nil }
        return
      }
      if self.manualCompactions[threadID] == .pending {
        self.manualCompactions[threadID] = .failed
      } else {
        self.errorMessage = "The conversation change was not confirmed. Refresh before retrying."
      }
    }
  }

  func queueConversationOperation(
    threadID: String,
    operation: @escaping @MainActor @Sendable (ConsoleStore, OrganizeContext) async throws -> Void
  ) {
    guard canOrganize, pendingConversationActions[threadID] == nil,
      let held = conversations[threadID]
    else {
      errorMessage = "Conversation changes are unavailable. Reconnect and try again."
      return
    }
    let context = OrganizeContext(epoch: epoch, selection: selection, held: held)
    let token = UUID()
    pendingConversationActions[threadID] = token
    enqueueThreadWrite(
      threadID: threadID,
      onFinish: { [weak self] outcome in
        guard let self, self.pendingConversationActions[threadID] == token else { return }
        self.pendingConversationActions[threadID] = nil
        if self.manualCompactions[threadID] == .pending {
          self.manualCompactions[threadID] = outcome == .cancelled ? nil : .failed
        }
        guard self.organizeContextIsCurrent(context, threadID: threadID) else { return }
        if outcome == .failed || outcome == .timedOut, self.manualCompactions[threadID] == nil {
          self.errorMessage = "The conversation change was not confirmed. Refresh before retrying."
        } else if outcome == .success {
          self.errorMessage = nil
        }
      },
      operation: { [weak self] in
        guard let self, await self.organizeContextIsCurrent(context, threadID: threadID) else {
          throw CancellationError()
        }
        try await operation(self, context)
      }
    )
  }

  private func completeConversationDeletion(_ threadID: String) {
    removeThread(threadID)
    for draft in authored.drafts where draft.key.threadID == threadID {
      noteDraftRemoval(draft.version)
    }
    authored.drafts.removeAll { $0.key.threadID == threadID }
    authored.seen.removeAll { $0.id == threadID }
    authoredChanged()
    if selectedThreadID == threadID {
      selectedThreadID = nil
      selection &+= 1
      visible = false
    }
  }
}
