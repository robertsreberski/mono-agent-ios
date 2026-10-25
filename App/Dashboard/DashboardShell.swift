// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Adaptive navigation for one console's dashboard.
///
/// Regular width: `NavigationSplitView`, the dashboard as the sidebar and the destination in the
/// detail column (or an empty state). Compact width: a `NavigationStack` rooted at the dashboard
/// that pushes the destination. Both read and write the same ID-based `route`, so rotation,
/// iPad resizing and Slide Over keep the selection; scene storage restores it after the system
/// discards the scene, but only for the same console profile.
struct DashboardShell: View {
  let model: AppModel
  let store: ConsoleStore
  let manageConsoles: () -> Void
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.consoleTheme) private var theme
  @SceneStorage("dashboard.route") private var storedRoute = ""
  @State private var route: AppRoute?
  @State private var projectDestination: AppRoute?
  @State private var columns: NavigationSplitViewVisibility = .all
  @State private var launched = false
  /// Transient agent settings: covers the current context without replacing `route`.
  @State private var settings: AgentSettingsPresentation?
  /// Search lives here so a size-class change (rotation, iPad resizing) keeps the query.
  @State private var query: String
  @State private var search: ThreadSearchModel

  init(model: AppModel, store: ConsoleStore, manageConsoles: @escaping () -> Void) {
    self.model = model
    self.store = store
    self.manageConsoles = manageConsoles
    _query = State(initialValue: model.launchQuery ?? "")
    _search = State(
      initialValue: ThreadSearchModel { [store] source, query in
        try await store.searchThreads(sourceID: source, query: query)
      })
  }

  private var path: Binding<[AppRoute]> {
    Binding(
      get: {
        guard let route, route.isDashboardDestination else { return [] }
        if let projectDestination, projectDestination != route {
          return [projectDestination, route]
        }
        return [route]
      },
      set: {
        route = $0.last
        if $0.isEmpty { projectDestination = nil }
      })
  }

  var body: some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView(columnVisibility: $columns) {
          dashboard(selectable: true)
            .navigationSplitViewColumnWidth(min: 320, ideal: WebMetrics.dashboardColumn, max: 520)
        } detail: {
          // Regular: settings is the detail with a ✕; the sidebar stays usable and retargets it.
          ZStack {
            // Retained, but neither visible nor reachable while settings covers it.
            NavigationStack {
              detail(regularDetailRoute).id(regularDetailRoute)
            }
            .environment(\.coveredBySettings, settings != nil)
            .opacity(settings == nil ? 1 : 0)
            .allowsHitTesting(settings == nil)
            .accessibilityHidden(settings != nil)
            if let settings {
              AgentSettingsScreen(
                store: store, sourceID: store.dashboardAgentID, target: settings.target,
                layout: .split, close: closeSettings)
            }
          }
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        // Compact: a full-size screen with Back over the retained stack, route and scroll. The
        // cover's modal presentation keeps VoiceOver and touches out of the covered context.
        NavigationStack(path: path) {
          dashboard(selectable: false)
            .navigationDestination(for: AppRoute.self) { detail($0) }
        }
        .environment(\.coveredBySettings, settings != nil)
        .fullScreenCover(
          isPresented: Binding(
            get: { settings != nil },
            set: { presented in if !presented && sizeClass != .regular { settings = nil } })
        ) {
          if let settings {
            AgentSettingsScreen(
              store: store, sourceID: store.dashboardAgentID, target: settings.target,
              layout: .stacked, close: closeSettings
            )
            .environment(\.agentSettingsEntry, settingsEntry)
          }
        }
      }
    }
    .environment(\.agentSettingsEntry, settingsEntry)
    #if DEBUG
      .environment(\.openWebConsole, openWebConsole)
      .overlay(alignment: .bottomLeading) {
        // Fixtures never leave the app; tests read the URL "Open web console" would open.
        if let url = model.fixtureExternalURL {
          Text(url.absoluteString).font(.system(size: 2)).opacity(0.02)
          .accessibilityIdentifier("fixture-external-url")
        }
      }
    #endif
    .onChange(of: route) { old, new in
      // Opening a conversation (sidebar or link) closes settings, as on the web.
      if old != new, settings != nil { settings = nil }
    }
    .environment(
      \.openNewConversation,
      NewConversationAction { source in
        route = .newConversation(profile: store.profile.id, sourceID: source)
      }
    )
    .onChange(of: route) { _, value in
      storedRoute = value?.encoded ?? ""
      if case .project = value { projectDestination = value }
    }
    .task(id: model.isReady) { applyLaunchRoute() }
  }

  private var regularDetailRoute: AppRoute? {
    if case .project = route {
      return store.selectedConversation.map {
        .conversation(
          profile: store.profile.id, sourceID: $0.thread.sourceId, threadID: $0.thread.id,
          archived: $0.thread.archivedAt != nil)
      }
    }
    return route
  }

  @ViewBuilder private func dashboard(selectable: Bool) -> some View {
    if selectable, case .project(_, let source, let id) = projectDestination ?? route {
      ProjectScreen(
        store: store, sourceID: source, projectID: id, selectable: true,
        navigate: navigateFromProject)
    } else {
      DashboardView(
        model: model, store: store, route: $route, selectable: selectable,
        manageConsoles: manageConsoles, query: $query, search: search)
    }
  }

  @ViewBuilder
  private func detail(_ route: AppRoute?) -> some View {
    switch route {
    case .conversation, .newConversation:
      if let route {
        ConversationScreen(
          model: model, store: store, route: route,
          navigate: { self.route = $0 ?? projectDestination }
        )
        .id(route)
      }
    case .project(_, let source, let id):
      ProjectScreen(store: store, sourceID: source, projectID: id, navigate: navigateFromProject)
    case .console, nil:
      EmptyStateView(
        "Choose a conversation", systemImage: "bubble.left.and.bubble.right",
        message: "Pick a conversation from the list, or start a new one."
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.palette.canvas.color)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("detail-empty")
    }
  }

  #if DEBUG
    private var openWebConsole: OpenWebConsoleAction {
      if model.isFixture {
        return OpenWebConsoleAction { [model] url in model.recordExternalOpen(url) }
      }
      return OpenWebConsoleAction { url in UIApplication.shared.open(url) }
    }
  #endif

  private var settingsEntry: AgentSettingsEntry {
    AgentSettingsEntry(
      isOpen: settings != nil,
      open: { section in openSettings(section) },
      toggle: {
        // Web: where the dashboard stays visible a second press closes; otherwise it retargets.
        if settings != nil && sizeClass == .regular {
          closeSettings()
        } else {
          openSettings(nil)
        }
      })
  }

  /// A new intent for the same section is still an explicit navigation.
  private func openSettings(_ section: AgentSettingsSection?) {
    let intent = (settings?.target.intent ?? 0) + 1
    withAnimation(.snappy(duration: 0.25)) {
      settings = AgentSettingsPresentation(
        target: AgentSettingsTarget(section: section, intent: intent))
    }
  }

  private func closeSettings() {
    withAnimation(.snappy(duration: 0.25)) { settings = nil }
  }

  private func navigateFromProject(_ target: AppRoute?) {
    if let target {
      route = target
    } else {
      projectDestination = nil
      if sizeClass == .regular {
        route = store.selectedConversation.map {
          .conversation(
            profile: store.profile.id, sourceID: $0.thread.sourceId, threadID: $0.thread.id,
            archived: $0.thread.archivedAt != nil)
        }
      } else {
        route = nil
      }
    }
  }

  /// Restores the last destination for this console, or opens the DEBUG fixture conversation.
  private func applyLaunchRoute() {
    guard model.isReady, !launched else { return }
    launched = true
    // DEBUG launch destination (always nil in Release), applied once after Store readiness.
    if let section = model.launchSettings {
      openSettings(section.section)
    }
    guard route == nil else { return }
    if let threadID = model.launchThreadID,
      let thread = store.buckets.values.lazy.flatMap(\.threads).first(where: { $0.id == threadID })
    {
      route = .conversation(
        profile: store.profile.id, sourceID: thread.sourceId, threadID: thread.id,
        archived: thread.archivedAt != nil)
      return
    }
    if let restored = AppRoute(encoded: storedRoute), restored.isDashboardDestination,
      restored.profile == store.profile.id
    {
      route = restored
    }
  }
}
