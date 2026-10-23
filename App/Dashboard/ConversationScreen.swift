// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Store-only conversation destination. Visibility remains owned by the route lifecycle.
struct ConversationScreen: View {
  let model: AppModel
  let store: ConsoleStore
  let route: AppRoute
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.consoleTheme) private var theme
  @State private var onScreen = false
  /// A new conversation created by this screen's composer (C8); the route stays unchanged.
  @State private var createdThreadID: String?
  @State private var screenWidth: CGFloat = 402

  private var threadID: String? { route.threadID ?? createdThreadID }
  private var sourceID: String { route.sourceID ?? "" }

  private var thread: WebThread? {
    guard let threadID else { return nil }
    return store.conversations[threadID]?.thread
      ?? store.buckets.values.lazy.flatMap(\.threads).first { $0.id == threadID }
      ?? store.activeFleet?.threads.first { $0.id == threadID }
  }

  private var agent: WebAgentSummary? { store.agents.first { $0.sourceId == sourceID } }

  private var title: String {
    guard threadID != nil else { return "New conversation" }
    guard let title = thread?.title, !title.isEmpty else { return "Untitled conversation" }
    return title
  }

  var body: some View {
    VStack(spacing: 0) {
      if let threadID, let state = store.conversations[threadID] {
        ConversationTranscript(state: state, store: store) { EmptyView() }
      } else {
        ScrollView {
          placeholder
            .padding(.horizontal, WebSpace.transcriptGutter)
            .padding(.top, 24)
            .frame(maxWidth: WebMetrics.column)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
      }
    }
    .conversationComposer(
      store: store, route: route, createdThreadID: $createdThreadID,
      sampleAttachments: model.offersSampleAttachments
    )
    .background(theme.palette.panel.color.ignoresSafeArea())
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      screenWidth = $0
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { headerToolbar }
    // Web chat header: panel at 94% over the transcript; the system bar keeps its glass back.
    .toolbarBackground(theme.palette.panel.color.opacity(0.94), for: .navigationBar)
    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      model.isReady && store.hydrated ? "scenario-ready" : "conversation-loading"
    )
    .task(id: route) {
      await store.select(
        sourceID: sourceID, archived: archived, threadID: threadID)
      applyVisibility()
    }
    .onAppear {
      onScreen = true
      applyVisibility()
    }
    .onDisappear {
      onScreen = false
      applyVisibility()
    }
    .onChange(of: scenePhase) { applyVisibility() }
    .onChange(of: store.selectedThreadID) { applyVisibility() }
    .onChange(of: store.selectedBucket) { applyVisibility() }
  }

  /// A conversation opens in its own bucket; a new conversation keeps the shelf on screen.
  private var archived: Bool {
    if case .conversation(_, _, _, let archived) = route { return archived }
    return store.selectedBucket?.sourceID == sourceID && store.selectedBucket?.archived == true
  }

  /// `select` resets the Store's visibility; re-assert it whenever selection or scene changes.
  private func applyVisibility() {
    if let visible = TranscriptVisibility.command(
      onScreen: onScreen, sceneActive: scenePhase == .active,
      selectedThreadID: store.selectedThreadID, threadID: threadID)
    {
      store.markVisible(visible)
    }
  }

  private var runStatus: (kind: StatusKind, label: String)? {
    guard let thread else { return nil }
    return ConversationHeaderModel.status(
      thread, confirmed: store.isRunningConfirmed(threadID: thread.id))
  }

  private var knownRoute: ConversationHeaderModel.Route? {
    guard let thread else { return nil }
    let state = store.conversations[thread.id]
    let latest = state?.orderedMessageIDs.reversed().lazy.compactMap {
      state?.messageStates[$0]?.message.attribution
    }.first(where: ConversationHeaderModel.hasReportedModel)
    return ConversationHeaderModel.route(thread, agent: agent, latest: latest)
  }

  // MARK: Header (web `.chat-header`)

  @ToolbarContentBuilder private var headerToolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      // The system centres the principal item; giving it all the room between the 44 pt back
      // button and the trailing tile keeps the web's leading-aligned title block.
      header.frame(width: max(120, screenWidth - 2 * (16 + 44 + 6)), alignment: .leading)
    }
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .topBarTrailing) { detailsMenu }
      .sharedBackgroundVisibility(.hidden)
  }

  /// Breadcrumb (project · tags) above the 13 pt title and its run state, left-aligned beside
  /// the back button as on the web phone header.
  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      breadcrumb
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(title)
          .webFont(.conversationTitle)
          .foregroundStyle(WebColor.text.color)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        if let runStatus { runStateBadge(runStatus) }
      }
    }
    .padding(.horizontal, 2)
    .frame(maxWidth: 560, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-header")
  }

  @ViewBuilder private var breadcrumb: some View {
    let project = thread.flatMap { DashboardModel.projectLabel($0, projects: store.projects) }
    let tags =
      thread.map { thread in
        thread.tagIds.compactMap { id in
          store.tags.first { $0.id == id && $0.sourceId == thread.sourceId }
        }
      } ?? []
    HStack(spacing: 6) {
      if let project {
        ProjectBadge(project.name, color: LabelColor(serverValue: project.color))
      }
      if project != nil && !tags.isEmpty {
        Text("·").webFont(.breadcrumb).foregroundStyle(WebColor.textMuted.color)
      }
      ForEach(tags.prefix(2), id: \.id) { tag in
        TagBadge(tag.name, color: LabelColor(serverValue: tag.color))
          .padding(.horizontal, 8)
          .frame(minHeight: 20)
          .background(WebColor.surfaceHover.color, in: Capsule())
      }
      // The last reported route (model · effort) the old header carried, quietly.
      if let route = knownRoute {
        if project != nil || !tags.isEmpty {
          Text("·").webFont(.breadcrumb).foregroundStyle(WebColor.textMuted.color)
        }
        RouteBadge(model: route.label, effort: route.effort ?? "", detail: route.detail)
          .layoutPriority(-1)
      }
    }
    .lineLimit(1)
  }

  /// Web `.chat-status`: a dot and the uppercase state.
  private func runStateBadge(_ status: (kind: StatusKind, label: String)) -> some View {
    let label = status.label
    let color: Color =
      switch status.kind {
      case .connecting: WebColor.jobProgress.color
      case .failed: WebColor.danger.color
      case .stale: WebColor.textMuted.color
      default: theme.palette.accent.color
      }
    return HStack(spacing: 5) {
      Image(systemName: status.kind == .stale ? "circle.dotted" : "circle.fill")
        .font(.system(size: 6, weight: .bold))
        .foregroundStyle(color)
      Text(label)
        .font(.system(size: 10, weight: .semibold)).tracking(0.7).textCase(.uppercase)
        .foregroundStyle(WebColor.textMuted.color)
        .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(status.label)
    .accessibilityIdentifier("conversation-run-state")
  }

  /// The web header's trailing "…" tile. iOS has no conversation actions yet, so it shows the
  /// facts the old in-transcript header carried: agent, state and the route's provenance.
  private var detailsMenu: some View {
    Menu {
      Section(agent?.label ?? "Agent unavailable") {
        if let runStatus { Text(runStatus.label) }
        if let route = knownRoute {
          Text(route.label + (route.effort.map { " · " + $0 } ?? ""))
          Text(route.provenance)
        }
      }
    } label: {
      Label("Conversation details", systemImage: "ellipsis")
    }
    .menuStyle(.button)
    .buttonStyle(WebTileButtonStyle())
    .accessibilityIdentifier("conversation-details")
  }

  /// The web empty chat: no card and no second title (the header already names it), only a
  /// quiet line in the column.
  @ViewBuilder private var placeholder: some View {
    if threadID == nil {
      Text("Write the first message below. The conversation is created when you send it.")
        .webFont(.system)
        .foregroundStyle(WebColor.textMuted.color)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer-placeholder")
    } else {
      VStack(spacing: 8) {
        ProgressView()
        Text("Waiting for the conversation history. Pull to refresh if it remains unavailable.")
          .webFont(.system)
          .foregroundStyle(WebColor.textMuted.color)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 48)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("transcript-loading")
    }
  }
}

/// A project row's destination until the project page exists (organize feature).
struct ProjectPlaceholder: View {
  let store: ConsoleStore
  let sourceID: String
  let projectID: String
  @Environment(\.consoleTheme) private var theme

  private var project: WebProject? {
    store.projects.first { $0.id == projectID && $0.sourceId == sourceID }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignSpacing.lg) {
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
          ProjectChip(
            project?.name ?? "Project", color: LabelColor(serverValue: project?.color))
          Text(
            project.map {
              "\($0.conversationCount) conversation\($0.conversationCount == 1 ? "" : "s")"
            } ?? ""
          )
          .designFont(.supporting).foregroundStyle(.secondary)
        }
        .contentSurface()
        EmptyStateView(
          "Project page coming soon", systemImage: "folder",
          message:
            "Placeholder: the project's conversations, context and settings arrive in a later update."
        )
        .contentSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project-placeholder")
      }
      .padding(DesignSpacing.lg)
      .frame(maxWidth: DesignMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.palette.canvas.color)
    .navigationTitle(project?.name ?? "Project")
    .navigationBarTitleDisplayMode(.inline)
  }
}
