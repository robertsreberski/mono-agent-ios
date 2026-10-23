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
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var viewportWidth: CGFloat = 0
  /// Web `--column-padding` plus whatever centres the 880 pt column on wide screens.
  private func inset(regular: Bool) -> CGFloat {
    let gutter = regular ? WebSpace.transcriptGutterRegular : WebSpace.transcriptGutter
    return gutter + max(0, (viewportWidth - WebMetrics.column) / 2)
  }
  init(state: ConversationState, store: ConsoleStore, @ViewBuilder header: () -> Header) {
    self.state = state
    self.store = store
    self.header = header()
  }
  var body: some View {
    let regular = sizeClass == .regular
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Keep the header eager: lazy offscreen headers can disappear from the AX hierarchy.
        header
        // Web `.message-list`: 23 pt rhythm on phones, 28 on tablets; no avatar rail.
        LazyVStack(
          alignment: .leading, spacing: regular ? WebSpace.sectionGapRegular : WebSpace.sectionGap
        ) {
          historyStatus.padding(.horizontal, inset(regular: regular))
          if let cursor = state.nextCursor {
            Button {
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
            } label: {
              Label(
                paging ? "Loading history…" : "Load older messages",
                systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(WebQuietPillStyle())
            .frame(maxWidth: .infinity)
            .disabled(paging).accessibilityIdentifier("transcript-load-older").id(
              "paging-" + cursor
            )
            .padding(.horizontal, inset(regular: regular))
          }
          ForEach(Array(state.orderedMessageIDs.enumerated()), id: \.element) { index, id in
            if let row = state.messageStates[id] {
              TranscriptMessageView(row: row, store: store, startsTurn: startsTurn(index, id: id))
                .padding(.horizontal, inset(regular: regular))
                .id(id)
            }
          }
          if let pending = heldCompaction, !hasCompactionResult(since: pending) {
            TranscriptMarkerRow(
              "Compacting context… · manual", systemImage: "arrow.triangle.2.circlepath"
            )
            .accessibilityIdentifier("manual-compaction-running")
            .padding(.horizontal, inset(regular: regular))
          }
          if state.orderedMessageIDs.isEmpty {
            Text("This conversation has no loaded messages.")
              .webFont(.system).foregroundStyle(WebColor.textMuted.color)
              .frame(maxWidth: .infinity)
          }
          Color.clear.frame(height: DesignSpacing.sm).id("transcript-bottom")
        }
        .scrollTargetLayout()
      }
      // Web `--column-padding`: 24/12/8 on phones, 38/24/20 on tablets, column ≤ 880.
      .padding(.top, regular ? 38 : 24)
      .padding(.bottom, regular ? 20 : 8)
      // The scroll target layout spans the viewport and every row carries the gutter (the
      // ≤ 880 column is centred by the inset). Anchored scrolls to a row then never offset the
      // column sideways, which an inset target layout did.
      .frame(maxWidth: .infinity)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      viewportWidth = $0
    }
    .scrollDismissesKeyboard(.immediately)
    .scrollPosition($scrollPosition)
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    // Short transcripts sit at the top; bottom alignment left a gap that revealed the refresh
    // control above the first row once the composer dock enlarged the bottom inset.
    .defaultScrollAnchor(.top, for: .alignment)
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
        if next.contentHeight > next.viewportHeight {
          // Anchor to the realized bottom row, not the lazily estimated content edge: with a
          // short viewport (keyboard up) edge scrolling re-estimated rows and never settled.
          scrollPosition.scrollTo(id: "transcript-bottom", anchor: .bottom)
        } else {
          // Content shorter than the viewport: the clamped edge scroll never over-pulls into
          // the refresh control.
          scrollPosition.scrollTo(edge: .bottom)
        }
      }
    }
    .accessibilityIdentifier("conversation-transcript")
    .safeAreaBar(edge: .bottom) {
      if policy.shouldShowJump {
        HStack {
          Spacer()
          // Web `.scroll-bottom`: a 36 pt circle floating above the dock edge (glass here).
          Button {
            policy.jump()
            scrollPosition.scrollTo(edge: .bottom)
          } label: {
            Label("Jump to latest", systemImage: "arrow.down")
              .labelStyle(.iconOnly)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(WebColor.textSoft.color)
              .frame(width: WebMetrics.tile, height: WebMetrics.tile)
              .floatingGlass(in: Circle(), opaqueFill: WebColor.surfaceRaised.color)
              .frame(
                minWidth: DesignMetrics.minimumHitTarget,
                minHeight: DesignMetrics.minimumHitTarget
              )
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("jump-to-latest")
          Spacer()
        }.padding(.bottom, 4)
      }
    }
    .contentMargins(.bottom, DesignSpacing.xxl, for: .scrollContent)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(theme.palette.panel.color)
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
      TranscriptNotice(
        "History may be stale · pull to refresh", systemImage: "clock.arrow.circlepath"
      )
      .accessibilityIdentifier("transcript-stale")
    } else {
      TranscriptNotice("History up to date", systemImage: "checkmark")
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
