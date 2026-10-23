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
  @State private var columns: NavigationSplitViewVisibility = .all
  @State private var launched = false
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
      get: { route.map { $0.isDashboardDestination ? [$0] : [] } ?? [] },
      set: { route = $0.last })
  }

  var body: some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView(columnVisibility: $columns) {
          dashboard(selectable: true)
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 520)
        } detail: {
          NavigationStack {
            detail(route).id(route)
          }
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        NavigationStack(path: path) {
          dashboard(selectable: false)
            .navigationDestination(for: AppRoute.self) { detail($0) }
        }
      }
    }
    .environment(
      \.openNewConversation,
      NewConversationAction { source in
        route = .newConversation(profile: store.profile.id, sourceID: source)
      }
    )
    .onChange(of: route) { _, value in storedRoute = value?.encoded ?? "" }
    .task(id: model.isReady) { applyLaunchRoute() }
  }

  private func dashboard(selectable: Bool) -> some View {
    DashboardView(
      model: model, store: store, route: $route, selectable: selectable,
      manageConsoles: manageConsoles, query: $query, search: search)
  }

  @ViewBuilder
  private func detail(_ route: AppRoute?) -> some View {
    switch route {
    case .conversation, .newConversation:
      if let route { ConversationScreen(model: model, store: store, route: route) }
    case .project(_, let source, let id):
      ProjectPlaceholder(store: store, sourceID: source, projectID: id)
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

  /// Restores the last destination for this console, or opens the DEBUG fixture conversation.
  private func applyLaunchRoute() {
    guard model.isReady, !launched else { return }
    launched = true
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
