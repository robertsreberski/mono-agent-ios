// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Context/cost for a conversation. The composer dock mounts it beside the model selector
/// (web "Next turn settings" row): a compact trigger there, the full disclosure in a popover.
struct ConversationContextView: View {
  let state: ConversationState
  let store: ConsoleStore
  @State private var expanded: Bool
  init(state: ConversationState, store: ConsoleStore, expanded: Bool = false) {
    self.state = state
    self.store = store
    _expanded = State(initialValue: expanded)
  }
  static func content(_ state: ConversationState) -> ContextDisplayContent {
    let projection = UsagePresentation.context(messages: state.messages, thread: state.thread)
    let rows = UsagePresentation.rows(state.usage).map {
      ContextDisplayContent.Row($0.label, $0.value)
    }
    return .init(
      badge: projection.badge, figure: projection.figure,
      status: projection.status + (projection.model.map { " · " + $0 } ?? ""),
      percent: projection.percent, note: projection.note, rows: rows)
  }
  @State private var loading = false
  @State private var failed = false
  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      ContextDisplay(Self.content(state), expanded: $expanded)
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
