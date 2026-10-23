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
  private let detailOnly: Bool
  init(state: ConversationState, store: ConsoleStore, expanded: Bool = false) {
    self.state = state
    self.store = store
    detailOnly = expanded
    _expanded = State(initialValue: expanded)
  }
  static func content(_ state: ConversationState) -> ContextDisplayContent {
    let projection = UsagePresentation.context(messages: state.messages, thread: state.thread)
    let rows = UsagePresentation.rows(state.usage).map {
      ContextDisplayContent.Row($0.label, $0.value)
    }
    var content = ContextDisplayContent(
      badge: projection.badge, figure: projection.figure,
      status: projection.status + (projection.model.map { " · " + $0 } ?? ""),
      percent: projection.percent, note: projection.note, rows: rows)
    if let usage = state.usage {
      for (label, slice) in [
        ("Total", Optional(usage.total)), ("incl. subagents", usage.subagents),
        ("Compaction", usage.compaction),
      ] {
        guard let slice else { continue }
        let prefix = slice.tokensPartial == true ? "≥" : ""
        content.tokens.append(
          .init(
            label,
            input: slice.tokens.map { prefix + UsagePresentation.tokens($0.input + $0.cacheWrite) }
              ?? "Not reported",
            cached: slice.tokens.map { prefix + UsagePresentation.tokens($0.cacheRead) }
              ?? "Not reported",
            output: slice.tokens.map { prefix + UsagePresentation.tokens($0.output) }
              ?? "Not reported"))
        content.costs.append(.init(label, UsagePresentation.cost(slice)))
      }
      for slice in usage.byModel where usage.byModel.count > 1 {
        content.costs.append(.init(slice.model ?? "Unknown model", UsagePresentation.cost(slice)))
      }
    }
    return content
  }
  @State private var loading = false
  @State private var failed = false
  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      ContextDisplay(Self.content(state), expanded: $expanded, detailOnly: detailOnly)
      if expanded {
        if state.usageRevision != nil && state.usageRevision != state.thread.revision {
          Text("Last reported totals; conversation has changed.").webFont(.contextNote)
        }
        if loading { ProgressView("Loading totals…").webFont(.contextNote) }
        if failed {
          Text("Totals could not be refreshed. Unknown values are not zero.").webFont(.contextNote)
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
