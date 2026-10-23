// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentStore
import SwiftUI

struct ConversationTranscript<Header: View>: View {
  let state: ConversationState
  let store: ConsoleStore
  let header: Header
  @State private var policy = TranscriptFollowPolicy()
  @State private var phase: ScrollPhase = .idle
  @State private var paging = false
  @State private var visibleIDs: [String] = []
  @State private var scrollPosition = ScrollPosition(idType: String.self)
  @State private var heldCompaction: String?
  @Environment(\.consoleTheme) private var theme
  init(state: ConversationState, store: ConsoleStore, @ViewBuilder header: () -> Header) {
    self.state = state
    self.store = store
    self.header = header()
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignSpacing.lg) {
        // Keep the header eager: lazy offscreen headers can disappear from the AX hierarchy.
        header
        LazyVStack(alignment: .leading, spacing: DesignSpacing.lg) {
          historyStatus
          if let cursor = state.nextCursor {
            Button(
              paging ? "Loading history…" : "Load older messages",
              systemImage: "clock.arrow.circlepath"
            ) {
              let anchor =
                state.orderedMessageIDs.first { visibleIDs.contains($0) }
                ?? state.orderedMessageIDs.first
              paging = true
              policy.beginPaging()
              Task {
                await store.loadOlder()
                if let anchor { scrollPosition.scrollTo(id: anchor, anchor: .top) }
                paging = false
                policy.paging = false
              }
            }.disabled(paging).accessibilityIdentifier("transcript-load-older").id(
              "paging-" + cursor)
          }
          ForEach(Array(state.orderedMessageIDs.enumerated()), id: \.element) { index, id in
            if let row = state.messageStates[id] {
              TranscriptMessageView(row: row, store: store, startsTurn: startsTurn(index, id: id))
                .id(id)
            }
          }
          if let pending = heldCompaction, !hasCompactionResult(since: pending) {
            Label("Compacting context… · manual", systemImage: "arrow.triangle.2.circlepath")
              .designFont(.supporting).accessibilityIdentifier("manual-compaction-running")
          }
          if state.orderedMessageIDs.isEmpty {
            EmptyStateView(
              "No messages yet", systemImage: "text.bubble",
              message: "This conversation has no loaded messages.")
          }
          Color.clear.frame(height: DesignSpacing.sm).id("transcript-bottom")
        }
        .scrollTargetLayout()
      }
      .padding(DesignSpacing.lg)
      .frame(maxWidth: DesignMetrics.readableWidth)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition($scrollPosition)
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .onScrollPhaseChange { _, next in phase = next }
    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { visibleIDs = $0 }
    .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
      TranscriptScrollMetrics(
        contentHeight: geometry.contentSize.height,
        viewportHeight: geometry.containerSize.height, contentOffset: geometry.contentOffset.y,
        topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
    } action: { old, next in
      policy.update(next, userDriven: phase == .interacting || phase == .decelerating)
      if old.contentHeight != next.contentHeight && policy.shouldScrollAfterWrite(next)
        && phase == .idle
      {
        scrollPosition.scrollTo(edge: .bottom)
      }
    }
    .accessibilityIdentifier("conversation-transcript")
    .safeAreaBar(edge: .bottom) {
      if policy.shouldShowJump {
        HStack {
          Spacer()
          Button("Jump to latest", systemImage: "arrow.down") {
            policy.jump()
            scrollPosition.scrollTo(edge: .bottom)
          }.designButtonStyle(.secondary, placement: .floating)
            .accessibilityIdentifier("jump-to-latest")
          Spacer()
        }.padding(DesignSpacing.sm)
      }
    }
    .contentMargins(.bottom, DesignSpacing.xxl, for: .scrollContent)
    .scrollEdgeEffectStyle(.hard, for: .bottom)
    .background(theme.palette.canvas.color)
    .refreshable { await store.refreshDetail(state.thread.id) }
    .task(id: state.thread.compaction?.startedAt) {
      if let value = state.thread.compaction, value.status == "running", value.trigger == "manual",
        TranscriptPresentation.date(value.startedAt) != nil
      {
        heldCompaction = value.startedAt
      } else {
        try? await Task.sleep(for: .seconds(3))
        if !Task.isCancelled { heldCompaction = nil }
      }
    }
  }
  @ViewBuilder private var historyStatus: some View {
    if state.truncated {
      ConnectionBanner(
        .notice, title: "History truncated",
        message: "Only a bounded cached window is available. Refresh to recover paging."
      )
      .accessibilityIdentifier("history-truncated")
    }
    if state.freshness != .fresh {
      StatusIndicator(.stale, label: "History may be stale · pull to refresh")
        .accessibilityIdentifier("transcript-stale")
    } else {
      Label("History up to date", systemImage: "checkmark.circle").designFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("transcript-fresh")
    }
    if let error = store.errorMessage {
      ConnectionBanner(.problem, title: "Conversation update failed", message: error)
    }
  }
  private func startsTurn(_ index: Int, id: String) -> Bool {
    guard index > 0 else { return false }
    let previous = state.orderedMessageIDs[index - 1]
    return state.messageStates[id]?.turnID != state.messageStates[previous]?.turnID
  }
  private func hasCompactionResult(since at: String) -> Bool {
    // Only consult bodies while a manual hint exists. Automatic/older results never clear it.
    state.messageStates.values.contains { row in
      TranscriptPresentation.hasManualCompactionResult(row.message, since: at)
    }
  }

}
