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
        ConversationTranscript(state: state, store: store) { header }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            header
            placeholder
          }
          .padding(DesignSpacing.lg)
          .frame(maxWidth: DesignMetrics.readableWidth, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .conversationComposer(
      store: store, route: route, createdThreadID: $createdThreadID,
      sampleAttachments: model.offersSampleAttachments
    )
    .background(theme.palette.canvas.color)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationSubtitle(agent?.label ?? "Agent unavailable")
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

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Text(title)
        .designFont(.screenTitle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DesignSpacing.md) { facts }
        VStack(alignment: .leading, spacing: DesignSpacing.sm) { facts }
      }
      if let route = knownRoute {
        RouteBadge(model: route.label, effort: route.effort ?? "", detail: route.detail)
      }
      if let threadID, let state = store.conversations[threadID] {
        ConversationActivityHeader(state: state, store: store)
      }
      if let thread, let project = DashboardModel.projectLabel(thread, projects: store.projects) {
        ProjectChip(project.name, color: LabelColor(serverValue: project.color))
      }
    }
    .contentSurface()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-header")
  }

  @ViewBuilder private var facts: some View {
    Label(agent?.label ?? "Agent unavailable", systemImage: "person.crop.square")
      .designFont(.supporting)
      .foregroundStyle(.secondary)
    if let runStatus {
      StatusChip(runStatus.kind, label: runStatus.label)
        .accessibilityIdentifier("conversation-run-state")
    }
  }

  @ViewBuilder private var placeholder: some View {
    if threadID == nil {
      EmptyStateView(
        "New conversation", systemImage: "square.and.pencil",
        message:
          "Write the first message below. The conversation is created when you send it."
      )
      .contentSurface()
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("composer-placeholder")
    } else {
      EmptyStateView(
        "Loading conversation", systemImage: "text.bubble",
        message:
          "Waiting for the conversation history. Pull to refresh if it remains unavailable."
      )
      .contentSurface()
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
