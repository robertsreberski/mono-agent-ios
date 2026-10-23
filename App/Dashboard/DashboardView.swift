// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// One console's dashboard: agents, Running, Projects, Recent (or the archive shelf), search,
/// connection state and the data mode. Reads only from the Store; every mutation is a Store
/// command. Glass is limited to the system bars and toolbars.
struct DashboardView: View {
  let model: AppModel
  let store: ConsoleStore
  @Binding var route: AppRoute?
  /// Regular width: the list drives the split view's selection. Compact: links push.
  let selectable: Bool
  let manageConsoles: () -> Void
  @Environment(\.consoleTheme) private var theme
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Binding var query: String
  let search: ThreadSearchModel
  @State private var showOffline = false
  @State private var expandedAgents: Set<String> = []
  @State private var loadingOlder = false
  @AppStorage("dashboard.projectsCollapsed") private var projectsCollapsed = false

  // MARK: Derived state

  private var agents: [WebAgentSummary] { DashboardModel.sortPinnedFirst(store.agents) }

  private var selectedAgentID: String? {
    store.selectedBucket?.sourceID ?? store.bootstrap?.threadsSourceId ?? agents.first?.sourceId
  }

  private var selectedAgent: WebAgentSummary? {
    agents.first { $0.sourceId == selectedAgentID }
  }

  private var archived: Bool { store.selectedBucket?.archived ?? false }

  private var bucketKey: BucketKey? {
    selectedAgentID.map { BucketKey(sourceID: $0, archived: archived) }
  }

  private var bucket: ThreadBucket? { bucketKey.flatMap { store.buckets[$0] } }

  private var recentThreads: [WebThread] {
    (bucket?.threads ?? []).filter(DashboardModel.isRecent)
  }

  private var authoritativeFleet: Bool {
    store.connection == .live && store.freshness == .fresh && store.activeFleet != nil
  }

  private var running: DashboardModel.RunningProjection {
    let listed = selectedAgentID.flatMap { store.buckets[BucketKey(sourceID: $0)]?.threads } ?? []
    return DashboardModel.running(
      fleet: store.activeFleet, authoritative: authoritativeFleet,
      cached: store.conversations.values.map(\.thread), listed: listed, agents: agents)
  }

  private var unreadCounts: [String: Int] {
    let listed = store.buckets.filter { !$0.key.archived }.values.flatMap(\.threads)
    return DashboardModel.unreadCounts(
      listed.filter(DashboardModel.isRecent) + (store.activeFleet?.threads ?? []),
      isUnread: store.isUnread)
  }

  private var projects: [WebProject] {
    store.projects.filter { $0.sourceId == selectedAgentID && $0.archivedAt == nil }
  }

  private var statusInputs: DashboardBanner.Inputs {
    DashboardBanner.Inputs(
      registry: model.registry.states[store.profile.id], started: store.isStarted,
      sync: store.connection, freshness: store.freshness, errorMessage: store.errorMessage,
      storage: [store.storage, store.authoredStorage, store.journalStorage],
      insecure: store.profile.endpoint.isInsecure)
  }

  private var consoleName: String {
    store.bootstrap?.console.displayName
      ?? (store.profile.name.isEmpty ? store.profile.endpoint.origin : store.profile.name)
  }

  private var searching: Bool { ThreadSearchModel.isSearching(query) }

  /// Shell readiness plus the first answer for this Store: hydrated, and either offline,
  /// fresh from the console or holding a reported failure. Never a timer.
  private var ready: Bool {
    model.isReady && store.hydrated
      && (!store.isStarted || store.freshness == .fresh || store.errorMessage != nil)
  }

  // MARK: Body

  var body: some View {
    TimelineView(.everyMinute) { context in
      list(now: model.referenceDate ?? context.date)
    }
    .accessibilityIdentifier(ready ? "scenario-ready" : "dashboard-loading")
    .navigationTitle(selectedAgent?.label ?? consoleName)
    .navigationSubtitle(DashboardBanner.subtitle(console: consoleName, inputs: statusInputs))
    .toolbar { toolbar }
    .contentMargins(.bottom, DesignMetrics.minimumHitTarget + DesignSpacing.lg, for: .scrollContent)
    .searchable(
      text: $query,
      placement: sizeClass == .regular
        ? .automatic : .navigationBarDrawer(displayMode: .always),
      prompt: "Search conversations"
    )
    .refreshable { await refresh() }
    .onChange(of: query) { updateSearch() }
    .onChange(of: selectedAgentID) { previous, _ in
      // A query is about one agent; its hits must not linger under another agent's name.
      if previous != nil { query = "" }
      updateSearch()
    }
    .onChange(of: store.isStarted) { updateSearch() }
    .task(id: ready) { if ready { updateSearch() } }
  }

  @ViewBuilder private func list(now: Date) -> some View {
    if selectable {
      List(selection: $route) { sections(now: now) }
        .listStyle(.sidebar)
    } else {
      List { sections(now: now) }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.canvas.color)
    }
  }

  @ViewBuilder private func sections(now: Date) -> some View {
    bannerSection
    agentSection
    if searching {
      searchSections(now: now)
    } else {
      runningSection(now: now)
      projectsSection(now: now)
      recentSection(now: now)
    }
  }

  // MARK: Banners

  @ViewBuilder private var bannerSection: some View {
    let banners = DashboardBanner.banners(statusInputs)
    if !banners.isEmpty {
      Section {
        ForEach(banners) { banner in
          ConnectionBanner(
            banner.kind, title: banner.title, message: banner.message,
            actionTitle: banner.actionTitle,
            action: banner.action == nil
              ? nil
              : { @MainActor in if let action = banner.action { Task { await perform(action) } } }
          )
          .accessibilityIdentifier(banner.identifier)
          .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          .listRowBackground(Color.clear)
        }
      }
    }
  }

  // MARK: Agents

  @ViewBuilder private var agentSection: some View {
    let visibility = DashboardModel.visibleAgents(
      agents, selected: selectedAgentID, showOffline: showOffline)
    let counts = running.counts
    let unread = unreadCounts
    Section {
      if agents.isEmpty {
        Text("No agents discovered. Running agents will appear automatically.")
          .designFont(.supporting).foregroundStyle(.secondary)
          .accessibilityIdentifier("agent-strip")
      } else {
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: DesignSpacing.md) {
            ForEach(visibility.visible, id: \.sourceId) { agent in
              agentButton(
                agent, running: DashboardModel.runningCount(for: agent, counts: counts),
                unread: unread[agent.sourceId] ?? 0)
            }
            if visibility.hiddenOffline > 0 || showOffline {
              offlineToggle(hidden: visibility.hiddenOffline)
            }
          }
          .padding(.horizontal, DesignSpacing.xs)
          .padding(.bottom, DesignSpacing.xs)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
        .accessibilityIdentifier("agent-strip")
        .listRowInsets(
          EdgeInsets(top: 0, leading: DesignSpacing.sm, bottom: 0, trailing: DesignSpacing.sm))
      }
    }
  }

  private func agentButton(_ agent: WebAgentSummary, running: Int, unread: Int) -> some View {
    let selected = agent.sourceId == selectedAgentID
    let presence = AgentTile.Presence(serverValue: agent.status)
    return Button {
      selectAgent(agent.sourceId)
    } label: {
      AgentTile(
        initials: DashboardModel.initials(agent.label),
        caption: DashboardModel.shortLabel(agent.label), presence: presence, selected: selected,
        pinned: agent.pinned == true, badge: AgentTile.badge(running: running, unread: unread))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      AgentTile.accessibilityLabel(
        name: agent.label, presence: presence, pinned: agent.pinned == true, running: running,
        unread: unread)
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("agent-tile-\(agent.sourceId)")
  }

  private func offlineToggle(hidden: Int) -> some View {
    Button {
      showOffline.toggle()
    } label: {
      VStack(spacing: DesignSpacing.xs) {
        Image(systemName: showOffline ? "eye.slash" : "eye")
          .font(.system(.headline))
          .foregroundStyle(.secondary)
          .frame(
            minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget
          )
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
              .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        Text(showOffline ? "Hide" : "\(hidden) offline")
          .designFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(.top, DesignSpacing.sm)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      showOffline ? "Hide offline agents" : "Show \(hidden) offline agent\(hidden == 1 ? "" : "s")"
    )
    .accessibilityIdentifier("agent-offline-toggle")
  }

  // MARK: Running

  @ViewBuilder private func runningSection(now: Date) -> some View {
    let projection = running
    if !projection.groups.isEmpty {
      Section {
        ForEach(projection.groups, id: \.agent.sourceId) { group in
          let expanded = expandedAgents.contains(group.agent.sourceId)
          let cards =
            expanded
            ? group.threads : Array(group.threads.prefix(DashboardModel.runningCardsPerAgent))
          ForEach(cards, id: \.id) { thread in
            NavigationLink(value: conversationRoute(thread)) {
              ConversationRow(
                DashboardRows.running(
                  thread, agent: group.agent,
                  confirmed: store.isRunningConfirmed(threadID: thread.id),
                  projects: store.projects,
                  now: now))
            }
            .accessibilityIdentifier("running-row-\(thread.id)")
          }
          if group.threads.count > DashboardModel.runningCardsPerAgent {
            let hidden = group.threads.count - cards.count
            Button(
              expanded
                ? "Show fewer · \(group.agent.label)" : "+\(hidden) more · \(group.agent.label)"
            ) {
              if expanded {
                expandedAgents.remove(group.agent.sourceId)
              } else {
                expandedAgents.insert(group.agent.sourceId)
              }
            }
            .designFont(.supporting)
            .foregroundStyle(theme.palette.accent.color)
            .accessibilityIdentifier("running-more-\(group.agent.sourceId)")
          }
        }
        if projection.truncated {
          Text("Showing \(DashboardModel.runningCount(projection.groups)) of \(projection.total)")
            .designFont(.caption).foregroundStyle(.secondary)
        }
      } header: {
        SectionHeader(
          "Running", detail: projection.authoritative ? nil : "Last known, not confirmed just now"
        ) {
          Text("\(projection.total)")
            .designFont(.headline).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "Running, \(projection.total)\(projection.authoritative ? "" : ", last known")"
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("running-section")
      }
    }
  }

  // MARK: Projects

  @ViewBuilder private func projectsSection(now: Date) -> some View {
    let projects = projects
    if !projects.isEmpty, let agent = selectedAgentID {
      Section {
        if !projectsCollapsed {
          ForEach(projects, id: \.id) { project in
            NavigationLink(
              value: AppRoute.project(
                profile: store.profile.id, sourceID: agent, projectID: project.id)
            ) {
              ConversationRow(DashboardRows.project(project, now: now))
            }
            .accessibilityIdentifier("project-row-\(project.id)")
          }
        }
      } header: {
        Button {
          projectsCollapsed.toggle()
        } label: {
          SectionHeader("Projects", detail: projectsCollapsed ? "\(projects.count) hidden" : nil) {
            Image(systemName: "chevron.down")
              .rotationEffect(.degrees(projectsCollapsed ? -90 : 0))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Projects, \(projects.count)")
        .accessibilityValue(projectsCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(projectsCollapsed ? "Shows the projects" : "Hides the projects")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("projects-section")
      }
    }
  }

  // MARK: Recent

  @ViewBuilder private func recentSection(now: Date) -> some View {
    let threads = recentThreads
    Section {
      if threads.isEmpty {
        recentEmpty
      }
      ForEach(threads, id: \.id) { thread in
        NavigationLink(value: conversationRoute(thread)) {
          ConversationRow(
            DashboardRows.recent(
              thread, unread: store.isUnread(thread),
              confirmed: store.isRunningConfirmed(threadID: thread.id), projects: store.projects,
              tags: store.tags, now: now))
        }
        .accessibilityIdentifier("recent-row-\(thread.id)")
      }
      if let key = bucketKey, bucket?.nextCursor != nil {
        Button {
          Task {
            loadingOlder = true
            await store.refreshBucket(key, older: true)
            loadingOlder = false
          }
        } label: {
          HStack {
            Text(loadingOlder ? "Loading older conversations…" : "Load older conversations")
            if loadingOlder {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(loadingOlder || !store.isStarted)
        .accessibilityIdentifier("load-older")
      }
    } header: {
      SectionHeader(archived ? "Archived" : "Recent")
        .accessibilityIdentifier("recent-section")
    }
  }

  @ViewBuilder private var recentEmpty: some View {
    Group {
      if bucket == nil && store.isStarted && store.connection != .offline {
        LoadingStateView("Loading conversations…")
      } else if bucket == nil && !archived {
        EmptyStateView(
          "Conversations unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right",
          message: "This device has no saved list for this agent yet.")
      } else if archived {
        EmptyStateView("No archived conversations", systemImage: "archivebox")
      } else {
        EmptyStateView(
          "Start a conversation", systemImage: "bubble.left.and.bubble.right",
          message: "Conversations with \(selectedAgent?.label ?? "this agent") appear here.",
          actionTitle: selectedAgentID == nil ? nil : "New conversation",
          action: selectedAgentID == nil ? nil : { @MainActor in newConversation() })
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recent-empty")
  }

  // MARK: Search

  @ViewBuilder private func searchSections(now: Date) -> some View {
    let hits = search.hits
    if hits.isEmpty {
      Section {
        Group {
          switch search.status {
          case .error:
            ErrorStateView(
              "Search is unavailable right now",
              message: store.isStarted ? nil : "Search needs a live connection to the console.")
          case .ready:
            EmptyStateView("No matching conversations", systemImage: "magnifyingglass")
          case .idle, .loading:
            LoadingStateView("Searching…")
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-results")
      }
    } else {
      let current = Dictionary(
        store.buckets.values.flatMap(\.threads).map { ($0.id, $0) },
        uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
      let active = hits.filter { $0.thread.archivedAt == nil }
      let shelved = hits.filter { $0.thread.archivedAt != nil }
      if !active.isEmpty {
        Section {
          ForEach(active, id: \.thread.id) { hit in searchRow(hit, current: current, now: now) }
        } header: {
          SectionHeader("Conversations", detail: search.status == .loading ? "Updating…" : nil)
            .accessibilityIdentifier("search-results")
        } footer: {
          if search.truncated && shelved.isEmpty { truncatedNote }
        }
      }
      if !shelved.isEmpty {
        Section {
          ForEach(shelved, id: \.thread.id) { hit in searchRow(hit, current: current, now: now) }
        } header: {
          SectionHeader("Archived")
            .accessibilityIdentifier(active.isEmpty ? "search-results" : "search-archived")
        } footer: {
          if search.truncated { truncatedNote }
        }
      }
    }
  }

  private var truncatedNote: some View {
    Text("Showing the closest matches. Add a word to narrow the search.")
      .designFont(.caption)
  }

  private func searchRow(_ hit: WebThreadSearchHit, current: [String: WebThread], now: Date)
    -> some View
  {
    NavigationLink(value: conversationRoute(current[hit.thread.id] ?? hit.thread)) {
      ConversationRow(
        DashboardRows.search(
          hit, current: current[hit.thread.id], query: search.answeredQuery,
          projects: store.projects, now: now))
    }
    .accessibilityIdentifier("search-row-\(hit.thread.id)")
  }

  // MARK: Toolbar

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Consoles", systemImage: "server.rack") { manageConsoles() }
        .accessibilityIdentifier("consoles-button")
    }
    ToolbarItem(placement: .primaryAction) {
      Button("New conversation", systemImage: "square.and.pencil") { newConversation() }
        .disabled(selectedAgentID == nil)
        .accessibilityIdentifier("new-conversation")
    }
    ToolbarItemGroup(placement: .bottomBar) {
      dataModeMenu
      Spacer()
      archiveToggle
    }
  }

  private var dataModeMenu: some View {
    let label = DashboardModel.dataModeLabel(store.dataMode, effective: store.effectiveDataMode)
    return Menu {
      Picker(
        "Data mode",
        selection: Binding(get: { store.dataMode }, set: { store.setDataMode($0) })
      ) {
        Text("Auto").tag(DataMode.auto)
        Text("Lean").tag(DataMode.lean)
        Text("Full").tag(DataMode.full)
      }
      .pickerStyle(.inline)
      Text("Auto follows Low Data Mode. Lean halves page sizes and batches live updates.")
    } label: {
      // Text stays visible: the mode is a fact to read, not only a control to find.
      HStack(spacing: DesignSpacing.xs) {
        Image(
          systemName: store.effectiveDataMode == .lean
            ? "leaf" : "antenna.radiowaves.left.and.right")
        Text(label)
      }
    }
    .accessibilityLabel("Data \(label)")
    .accessibilityHint("Changes the data mode")
    .accessibilityIdentifier("data-mode")
  }

  private var archiveToggle: some View {
    let count =
      selectedAgentID.flatMap { store.buckets[BucketKey(sourceID: $0, archived: true)] }?
      .threads.count ?? 0
    let title = archived ? "Back to conversations" : count > 0 ? "Archived · \(count)" : "Archived"
    return Button {
      toggleArchive()
    } label: {
      HStack(spacing: DesignSpacing.xs) {
        Image(systemName: archived ? "bubble.left.and.bubble.right" : "archivebox")
        Text(title)
      }
    }
    .disabled(selectedAgentID == nil)
    .accessibilityLabel(
      archived ? "Back to conversations" : count > 0 ? "Archived, \(count)" : "Archived"
    )
    .accessibilityIdentifier("archive-toggle")
  }

  // MARK: Actions

  private func conversationRoute(_ thread: WebThread) -> AppRoute {
    .conversation(
      profile: store.profile.id, sourceID: thread.sourceId, threadID: thread.id,
      archived: thread.archivedAt != nil)
  }

  private func newConversation() {
    guard let agent = selectedAgentID else { return }
    route = .newConversation(profile: store.profile.id, sourceID: agent)
  }

  private func selectAgent(_ id: String) {
    guard id != selectedAgentID else { return }
    route = AgentSwitch.route(afterSelecting: id, current: route)
    let keep = route?.threadID
    Task { await store.select(sourceID: id, archived: false, threadID: keep) }
  }

  private func toggleArchive() {
    guard let agent = selectedAgentID else { return }
    let keep = route?.sourceID == agent ? route?.threadID : nil
    Task { await store.select(sourceID: agent, archived: !archived, threadID: keep) }
  }

  private func updateSearch() {
    search.update(
      query: query, sourceID: selectedAgentID, lean: store.effectiveDataMode == .lean)
  }

  private func perform(_ action: DashboardBanner.Action) async {
    switch action {
    case .connect:
      await model.registry.connect(store.profile.id)
    case .reconcile:
      store.clearErrorMessage()
      await store.reconcile()
    }
  }

  /// Pull to refresh: one reconciliation when live, otherwise an explicit reconnect probe.
  private func refresh() async {
    if store.isStarted, case .connected = model.registry.states[store.profile.id] {
      store.clearErrorMessage()
      await store.reconcile()
    } else {
      await model.registry.connect(store.profile.id)
    }
  }
}
