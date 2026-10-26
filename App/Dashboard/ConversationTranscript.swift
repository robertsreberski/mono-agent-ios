// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentStore
import SwiftUI

struct ConversationTranscript<Header: View>: View {
  let state: ConversationState
  let store: ConsoleStore
  let jumpControl: TranscriptJumpControl
  let header: Header
  @State private var policy = TranscriptFollowPolicy()
  @State private var phase: ScrollPhase = .idle
  @State private var paging = false
  @State private var refreshing = false
  @State private var visibleIDs: [String] = []
  @State private var scrollPosition = ScrollPosition(idType: String.self)
  @State private var heldCompaction: String?
  @Environment(\.consoleTheme) private var theme
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var viewportWidth: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var mcpPool = McpHostPool()
  @State private var disclosures = TranscriptDisclosures()
  @Environment(\.scenePhase) private var scenePhase
  /// Web `--column-padding` plus whatever centres the 880 pt column on wide screens.
  private func inset(regular: Bool) -> CGFloat {
    let gutter = regular ? WebSpace.transcriptGutterRegular : WebSpace.transcriptGutter
    return gutter + max(0, (viewportWidth - WebMetrics.column) / 2)
  }
  init(
    state: ConversationState, store: ConsoleStore, jumpControl: TranscriptJumpControl,
    @ViewBuilder header: () -> Header
  ) {
    self.state = state
    self.store = store
    self.header = header()
    self.jumpControl = jumpControl
  }
  // Messages carry no relative ages (web parity), so nothing schedules a transcript-wide tick;
  // only running leaves read the clock (`RunningTimeline`).
  var body: some View { transcript }
  @ViewBuilder private var transcript: some View {
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
              Text(paging ? "Loading history…" : "Load earlier messages")
                .webFont(.system).foregroundStyle(WebColor.textMuted.color)
                .frame(minHeight: DesignMetrics.minimumHitTarget)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(paging).accessibilityIdentifier("transcript-load-older").id(
              "paging-" + cursor
            )
            .padding(.horizontal, inset(regular: regular))
          }
          ForEach(state.transcriptMessageIDs, id: \.self) { id in
            if let row = state.messageStates[id] {
              TranscriptMessageView(row: row, store: store)
                .padding(.horizontal, inset(regular: regular))
                .id(id)
            }
          }
          if store.manualCompactions[state.thread.id] == .pending
            || (heldCompaction.map { !hasCompactionResult(since: $0) } ?? false)
          {
            CompactionMarkerRow(
              .init(label: "Compacting context…", trigger: "manual", running: true)
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
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      viewportWidth = $0.width
      viewportHeight = $0.height
    }
    .environment(\.mcpHostPool, mcpPool)
    .environment(\.transcriptDisclosures, disclosures)
    .environment(\.mcpViewport, CGSize(width: viewportWidth, height: viewportHeight))
    .modifier(McpConsentPresentation(presenter: mcpPool.consent))
    .onChange(of: scenePhase) { _, phase in mcpPool.sceneChanged(phase) }
    .onChange(of: state.orderedMessageIDs) { _, ids in mcpPool.retainMessages(ids) }
    .onChange(of: store.selectedThreadID) { _, thread in mcpPool.selectionChanged(thread) }
    .onDisappear { mcpPool.closeAll() }
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: UIApplication.didReceiveMemoryWarningNotification
      ).map({ _ in true }) {
        mcpPool.closeAll("The app was stopped to free memory. Reopen to load it again.")
      }
    }
    .scrollDismissesKeyboard(.immediately)
    .scrollPosition($scrollPosition)
    // Start at the reading edge. Bottom-follow is applied from measured geometry below;
    // an initial bottom anchor can retain a stale offset when the native dock first lays out.
    .defaultScrollAnchor(.top, for: .initialOffset)
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
      if phase == .idle && !refreshing && policy.shouldRestoreReadingEdge(next) {
        scrollPosition.scrollTo(edge: .top)
      } else if old.contentHeight != next.contentHeight && policy.shouldScrollAfterWrite(next)
        && phase == .idle
      {
        // Anchor to the realized bottom row, not the lazily estimated content edge: with a
        // short viewport (keyboard up) edge scrolling re-estimated rows and never settled.
        scrollPosition.scrollTo(id: "transcript-bottom", anchor: .bottom)
      }
    }
    .accessibilityIdentifier("conversation-transcript")
    .onChange(of: policy.shouldShowJump, initial: true) { _, available in
      jumpControl.available = available
      jumpControl.jump = {
        policy.jump()
        scrollPosition.scrollTo(edge: .bottom)
      }
    }
    .onDisappear {
      jumpControl.available = false
      jumpControl.jump = nil
    }
    .contentMargins(.bottom, DesignSpacing.xxl, for: .scrollContent)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(theme.palette.panel.color)
    .refreshable {
      refreshing = true
      defer { refreshing = false }
      await store.refreshDetail(state.thread.id)
    }
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
    // Web: no "up to date" marker; only a stale history says anything.
    if state.freshness != .fresh {
      TranscriptNotice(
        "History may be stale · pull to refresh", systemImage: "clock.arrow.circlepath"
      )
      .accessibilityIdentifier("transcript-stale")
    }
    if let error = store.errorMessage {
      ConnectionBanner(.problem, title: "Conversation update failed", message: error)
    }
  }
  private func hasCompactionResult(since at: String) -> Bool {
    // Only consult bodies while a manual hint exists. Automatic/older results never clear it.
    state.messageStates.values.contains { row in
      TranscriptPresentation.hasManualCompactionResult(row.message, since: at)
    }
  }

}
