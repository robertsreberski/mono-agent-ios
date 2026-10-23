// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ConversationActivityHeader: View {
  let state: ConversationState
  let store: ConsoleStore
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      ConversationContextView(state: state, store: store)
      ConversationJobStack(state: state, store: store, onAnswerPeerQuestion: onAnswerPeerQuestion)
    }
  }
}

private struct ConversationContextView: View {
  let state: ConversationState
  let store: ConsoleStore
  @State private var expanded = false
  @State private var loading = false
  @State private var failed = false
  var body: some View {
    let projection = UsagePresentation.context(messages: state.messages, thread: state.thread)
    let rows = UsagePresentation.rows(state.usage).map {
      ContextDisplayContent.Row($0.label, $0.value)
    }
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      ContextDisplay(
        .init(
          badge: projection.badge, figure: projection.figure,
          status: projection.status + (projection.model.map { " · " + $0 } ?? ""),
          percent: projection.percent,
          note: projection.note, rows: rows), expanded: $expanded)
      if expanded {
        if state.usageRevision != nil && state.usageRevision != state.thread.revision {
          Text("Last reported totals; conversation has changed.").designFont(.caption)
        }
        if loading { ProgressView("Loading totals…").designFont(.caption) }
        if failed {
          Text("Totals could not be refreshed. Unknown values are not zero.").designFont(.caption)
          Button("Retry totals") { Task { await refresh() } }
        }
      }
    }
    .task(id: String(expanded) + ":" + String(state.thread.revision)) {
      if expanded { await refresh() }
    }
  }
  private func refresh() async {
    loading = true
    defer { loading = false }
    do {
      try await store.refreshUsage(threadID: state.thread.id)
      failed = false
    } catch is CancellationError {} catch { failed = true }
  }
}
