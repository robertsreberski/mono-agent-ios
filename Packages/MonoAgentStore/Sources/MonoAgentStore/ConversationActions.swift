// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum ConversationAction: String, Sendable, Identifiable {
  case archive, delete, compact
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .archive: "Archive conversation"
    case .delete: "Permanently delete"
    case .compact: "Compact context"
    }
  }
  public var confirmation: String {
    switch self {
    case .archive:
      "Archive this conversation? Empty conversations will be permanently removed. Conversations with messages remain available in Archived."
    case .delete:
      "Permanently delete this conversation and its attachments? This cannot be undone."
    case .compact: "Summarizes earlier turns to free space."
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

  public var text: String {
    switch self {
    case .pending: "Summarizing earlier turns…"
    case .failed: "Connection lost — the outcome is unknown. Refresh this conversation."
    case .result(let result):
      switch result.status {
      case "succeeded": "Compacted."
      case "skipped":
        result.reason == "model_changed"
          ? "Switch back to this conversation's model to compact this session."
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

extension ConsoleStore {
  public var canOrganize: Bool {
    started && !stopping && !stopped && !backgrounded && connection == .live
  }

  public func canDeleteConversation(_ thread: WebThread) -> Bool {
    thread.archivedAt != nil
      && (thread.trigger?.kind != "cron" || thread.trigger?.configured == false)
  }

  public func canCompactConversation(_ thread: WebThread) -> Bool {
    canOrganize && thread.archivedAt == nil && thread.trigger == nil
      && thread.runState.status != "running" && thread.runState.status != "queued"
      && thread.compaction?.status != "running"
      && manualCompactions[thread.id] != .pending
      && agents.first(where: { $0.sourceId == thread.sourceId })?.supportsManualCompaction == true
  }

  public func requestConversationAction(_ action: ConversationAction, threadID: String) {
    guard canOrganize, pendingConversationActions[threadID] == nil,
      let thread = conversations[threadID]?.thread,
      action != .delete || canDeleteConversation(thread),
      action != .compact || canCompactConversation(thread)
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
      queueConversationOperation(threadID: thread.id) { store, context in
        try await store.api.deleteThread(id: thread.id, query: .init())
        guard store.organizeContextIsCurrent(context, threadID: thread.id) else {
          throw CancellationError()
        }
        store.completeConversationDeletion(thread.id)
      }
    case .compact:
      guard canCompactConversation(thread) else { return }
      manualCompactions[thread.id] = .pending
      queueConversationOperation(threadID: thread.id) { store, context in
        let result = try await store.api.compact(id: thread.id, body: .init())
        guard store.organizeContextIsCurrent(context, threadID: thread.id) else {
          throw CancellationError()
        }
        store.manualCompactions[thread.id] = .result(result)
      }
    }
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
      store.patchSummary(saved)
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
        if outcome == .failed || outcome == .timedOut {
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
