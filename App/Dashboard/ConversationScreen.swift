// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI
import UIKit

/// Store-only conversation destination. Visibility remains owned by the route lifecycle.
struct ConversationScreen: View {
  let model: AppModel
  let store: ConsoleStore
  let route: AppRoute
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.consoleTheme) private var theme
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  @State private var onScreen = false
  /// A new conversation created by this screen's composer (C8); the route stays unchanged.
  @State private var createdThreadID: String?
  @State private var screenWidth: CGFloat = 402
  @State private var actionsOpen = false
  @State private var renaming = false
  @State private var renamedTitle = ""
  @State private var pendingRename = false
  @State private var pendingAction: ConversationAction?

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
        ConversationTranscript(state: state, store: store) {
          if let error = store.errorMessage {
            ConnectionBanner(.problem, title: "Conversation change", message: error)
          }
          if let result = store.manualCompactions[threadID] {
            TranscriptNotice(result.text)
              .accessibilityIdentifier("manual-compaction-status")
          }
        }
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
    .modifier(
      ConversationTopBar(compact: sizeClass != .regular, panel: theme.palette.panel) {
        compactHeader
      }
    )
    .toolbar { headerToolbar }
    // iPad: the web chat header in the system bar (panel at 94%), no back button there.
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
    .onChange(of: store.selectedThreadID) {
      actionsOpen = false
      pendingRename = false
      pendingAction = nil
      renaming = false
      store.cancelConversationAction()
      applyVisibility()
    }
    .alert("Rename conversation", isPresented: $renaming) {
      TextField("Title", text: $renamedTitle).accessibilityIdentifier("rename-title")
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        if let threadID { store.renameConversation(threadID: threadID, title: renamedTitle) }
      }
    }
    .alert(
      store.conversationActionConfirmation?.action.title ?? "Conversation action",
      isPresented: Binding(
        get: { store.conversationActionConfirmation != nil },
        set: { if !$0 { store.cancelConversationAction() } }
      ), presenting: store.conversationActionConfirmation
    ) { request in
      Button("Cancel", role: .cancel) { store.cancelConversationAction() }
      Button(request.action.title, role: request.action == .compact ? nil : .destructive) {
        store.confirmConversationAction(request.id)
      }
    } message: { request in
      Text(request.action.confirmation)
    }
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

  /// iPad (regular width): the header lives in the system bar, leading, beside the trailing
  /// tile. Phones draw `compactHeader` instead and hide the bar.
  @ToolbarContentBuilder private var headerToolbar: some ToolbarContent {
    if sizeClass == .regular {
      ToolbarItem(placement: .topBarLeading) {
        header.frame(width: max(120, screenWidth - (16 + 60)), alignment: .leading)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .topBarTrailing) { detailsMenu(glass: true) }
        .sharedBackgroundVisibility(.hidden)
    }
  }

  /// Web mobile `.chat-header` (styles.css 649, 1822–1866): 9 pt gutters, a bare 44 pt back
  /// chevron pulled 6 pt into the gutter, the title block, and the flat 36 pt "…" tile.
  private var compactHeader: some View {
    HStack(spacing: 8) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(WebColor.textSoft.color)
          .frame(width: DesignMetrics.minimumHitTarget, height: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, -6)
      .accessibilityLabel("Back")
      .accessibilityIdentifier("conversation-back")
      header.frame(maxWidth: .infinity, alignment: .leading)
      detailsMenu(glass: false)
        .padding(.trailing, -4)
    }
    .padding(.horizontal, WebSpace.headerGutter)
    .padding(.vertical, 7)
    .frame(minHeight: WebMetrics.headerHeight)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-top-bar")
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

  /// The web header's trailing conversation menu; no read-only details dead end.
  private func detailsMenu(glass: Bool) -> some View {
    Button("Conversation actions", systemImage: "ellipsis") { actionsOpen = true }
      .buttonStyle(WebTileButtonStyle(material: glass ? .glass : .flat))
      .accessibilityIdentifier("conversation-actions")
      .disabled(thread == nil)
      .popover(isPresented: $actionsOpen, arrowEdge: .top) {
        VStack(spacing: 0) {
          if let thread {
            OrganizeMenuRow("Rename conversation", systemImage: "pencil") {
              actionsOpen = false
              renamedTitle = thread.title
              pendingRename = true
            }
            .accessibilityIdentifier("action-rename")
            if agent?.supportsManualCompaction == true {
              OrganizeMenuRow(
                "Compact context", systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
              ) {
                actionsOpen = false
                pendingAction = .compact
              }
              .disabled(!store.canCompactConversation(thread))
              .accessibilityIdentifier("action-compact")
            }
            OrganizeMenuRow(
              thread.archivedAt == nil ? "Archive conversation" : "Restore conversation",
              systemImage: thread.archivedAt == nil ? "archivebox" : "arrow.uturn.backward"
            ) {
              actionsOpen = false
              if thread.archivedAt == nil {
                pendingAction = .archive
              } else {
                store.restoreConversation(threadID: thread.id)
              }
            }
            .accessibilityIdentifier("action-archive")
            if store.canDeleteConversation(thread) {
              OrganizeMenuRow("Permanently delete", systemImage: "trash", destructive: true) {
                actionsOpen = false
                pendingAction = .delete
              }
              .accessibilityIdentifier("action-delete")
            }
          }
        }
        .disabled(
          !store.canOrganize || threadID.flatMap { store.pendingConversationActions[$0] } != nil
        )
        .padding(4)
        .frame(idealWidth: 280)
        .background(WebColor.surfaceRaised.color)
        .presentationCompactAdaptation(.popover)
        .onDisappear {
          // Present only after the toolbar popover releases its presentation owner (iPad).
          if pendingRename {
            pendingRename = false
            renaming = true
          }
          if let pendingAction, let threadID {
            self.pendingAction = nil
            store.requestConversationAction(pendingAction, threadID: threadID)
          }
        }
      }
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

/// Phones: hides the system bar (and its glass back button) and pins the web mobile chat header
/// above the content: the chat panel flowing up through the status-bar band, with a 1 px
/// bottom line and no blur or glass. Swipe-back stays available through `InteractivePopRestorer`.
private struct ConversationTopBar<Bar: View>: ViewModifier {
  let compact: Bool
  let panel: AdaptiveColor
  @ViewBuilder let bar: () -> Bar

  func body(content: Content) -> some View {
    if compact {
      content
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
          bar()
            // The status-bar band is opaque panel, as the web's fixed band; the header is the
            // panel too (the web's 94% mix reads as opaque, and any show-through ghosts text).
            .background { panel.color.ignoresSafeArea(edges: .top) }
            .overlay(alignment: .bottom) {
              Rectangle().fill(WebColor.line.color).frame(height: 1)
                .accessibilityHidden(true)
            }
        }
        .background { InteractivePopRestorer().frame(width: 0, height: 0) }
    } else {
      content
    }
  }
}

/// UIKit disables the edge swipe-back when the navigation bar is hidden. This re-enables the
/// stack's own interactive pop gesture whenever there is a screen to return to.
private struct InteractivePopRestorer: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {}

  final class Controller: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
      gesture.isEnabled = true
      gesture.delegate = self
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      (navigationController?.viewControllers.count ?? 0) > 1
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
