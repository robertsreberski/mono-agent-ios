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
  @State private var projectEditor: ProjectEditorRequest?
  @State private var tagEditor: TagEditorRequest?
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
    (bucket?.threads ?? []).filter {
      DashboardModel.isRecent($0) && ($0.archivedAt != nil) == archived
    }
  }

  private var authoritativeFleet: Bool {
    store.connection == .live && store.freshness == .fresh && store.activeFleet != nil
  }

  private var running: DashboardModel.RunningProjection {
    let listed = selectedAgentID.flatMap { store.buckets[BucketKey(sourceID: $0)]?.threads } ?? []
    return DashboardModel.running(
      fleet: store.activeFleet, authoritative: authoritativeFleet,
      cached: store.cachedThreads, listed: listed, agents: agents)
  }

  private var unreadCounts: [String: Int] {
    store.unreadCounts
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

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.agentSettingsEntry) private var settingsEntry
  @FocusState private var searchFocused: Bool
  @AccessibilityFocusState private var settingsButtonFocused: Bool

  var body: some View {
    #if DEBUG
      let _ = PerformanceProbe.body("DashboardView")
    #endif
    TimelineView(.everyMinute) { context in
      content(now: model.referenceDate ?? context.date)
    }
    .background(theme.palette.panel.color.ignoresSafeArea())
    .overlay(alignment: .trailing) {
      // Web: the 340 pt dashboard column ends in a 1 px line beside the chat.
      if selectable {
        Rectangle().fill(WebColor.line.color).frame(width: 1).ignoresSafeArea()
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(ready ? "scenario-ready" : "dashboard-loading")
    .navigationTitle(selectedAgent?.label ?? consoleName)
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: query) { updateSearch() }
    .onChange(of: selectedAgentID) { previous, _ in
      // A query is about one agent; its hits must not linger under another agent's name.
      if previous != nil { query = "" }
      updateSearch()
    }
    .onChange(of: store.isStarted) { updateSearch() }
    .sheet(item: $tagEditor) { TagSettings(store: store, request: $0) }
    .sheet(item: $projectEditor) { request in
      ProjectSettings(store: store, request: request) { project in
        route = .project(
          profile: store.profile.id, sourceID: project.sourceId, projectID: project.id)
      }
    }
    .task(id: ready) { if ready { updateSearch() } }
  }

  /// Web dashboard column: fixed header, agent strip and search, then the scrolling sections
  /// and the quiet footer. At accessibility sizes the strip and search scroll with the list.
  @ViewBuilder private func content(now: Date) -> some View {
    #if DEBUG
      let _ = PerformanceProbe.body("DashboardView.content")
    #endif
    VStack(spacing: 0) {
      header
      if !typeSize.isAccessibilitySize {
        agentStrip
        searchField
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if typeSize.isAccessibilitySize {
            agentStrip
            searchField
          }
          sections(now: now)
        }
        .padding(.horizontal, WebSpace.dashboardGutter)
        .padding(.top, typeSize.isAccessibilitySize ? 0 : 8)
        .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      .scrollDismissesKeyboard(.immediately)
      .accessibilityIdentifier("dashboard-list")
      .refreshable { await refresh() }
    }
    .safeAreaBar(edge: .bottom) { footer }
    .scrollEdgeEffectStyle(.hard, for: .bottom)
  }

  @ViewBuilder private func sections(now: Date) -> some View {
    bannerSection
    if searching {
      searchSections(now: now)
    } else {
      runningSection(now: now)
      projectsSection(now: now)
      recentSection(now: now)
    }
  }

  // MARK: Header

  private var statusLine: String {
    DashboardBanner.subtitle(console: consoleName, inputs: statusInputs)
  }

  /// Web `.dashboard-header`: eyebrow console name, the agent name, and the action tiles
  /// (Consoles, then the web's notifications, agent settings and new conversation). At
  /// accessibility sizes the tiles wrap below the title.
  @ViewBuilder private var header: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 8) {
        headerTitle
        headerActions
      }
      .padding(.horizontal, WebSpace.dashboardGutter)
      .padding(.vertical, 7)
    } else {
      HStack(alignment: .center, spacing: 12) {
        headerTitle
        Spacer(minLength: 0)
        headerActions
      }
      .padding(.horizontal, WebSpace.dashboardGutter)
      .padding(.vertical, 7)
      .frame(minHeight: WebMetrics.headerHeight)
    }
  }

  private var headerTitle: some View {
    VStack(alignment: .leading, spacing: 3) {
      // The web eyebrow is the console name; a non-live state is appended in words.
      Eyebrow(
        statusLine.hasSuffix(" · Online") ? String(statusLine.dropLast(9)) : statusLine)
      Text(selectedAgent?.label ?? consoleName)
        .webFont(.agentName)
        .foregroundStyle(WebColor.text.color)
        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        .accessibilityAddTraits(.isHeader)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(selectedAgent?.label ?? consoleName), \(statusLine)")
  }

  private var headerActions: some View {
    // 36 pt tiles in 44 pt hit targets: the visible gap is the web's 8 px.
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 0) {
        Button("Consoles", systemImage: "server.rack") { manageConsoles() }
          .buttonStyle(WebTileButtonStyle())
          .accessibilityIdentifier("consoles-button")
        NotificationsButton(store: store)
        settingsButton
        Button("New conversation", systemImage: "plus") { newConversation() }
          .buttonStyle(WebTileButtonStyle(.accent))
          .disabled(selectedAgentID == nil)
          .accessibilityIdentifier("new-conversation")
      }
    }
    .padding(.trailing, typeSize.isAccessibilitySize ? 0 : -4)
    .padding(.leading, typeSize.isAccessibilitySize ? -4 : 0)
  }

  /// Web `.agent-settings-button`: opens over the current screen, a second press closes it
  /// where the dashboard stays visible, and a dot marks an unsaved run-defaults draft.
  private var settingsButton: some View {
    let unsaved = selectedAgentID.map { store.hasUnsavedRunDefaults($0) } ?? false
    return Button("Agent settings", systemImage: "slider.horizontal.3") {
      settingsEntry.toggle()
    }
    .buttonStyle(WebTileButtonStyle())
    .overlay(alignment: .topTrailing) {
      if unsaved {
        Circle().fill(WebColor.warning.color).frame(width: 6, height: 6)
          .offset(x: -9, y: 9)
          .accessibilityHidden(true)
          .accessibilityIdentifier("agent-settings-dot")
      }
    }
    .disabled(selectedAgentID == nil)
    .accessibilityValue(
      (settingsEntry.isOpen ? "Expanded" : "Collapsed") + (unsaved ? ", unsaved changes" : "")
    )
    .accessibilityIdentifier("agent-settings-button")
    .accessibilityFocused($settingsButtonFocused)
    .onChange(of: settingsEntry.isOpen) { wasOpen, isOpen in
      // Closing returns VoiceOver to the invoker (web `settingsInvokerRef`).
      // The covered stack becomes accessible again on the next update; focus after it.
      if wasOpen && !isOpen {
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(150))
          settingsButtonFocused = true
        }
      }
    }
  }

  // MARK: Banners

  @ViewBuilder private var bannerSection: some View {
    let banners = DashboardBanner.banners(statusInputs)
    if !banners.isEmpty {
      VStack(spacing: 8) {
        ForEach(banners) { banner in
          ConnectionBanner(
            banner.kind, title: banner.title, message: banner.message,
            actionTitle: banner.actionTitle,
            action: banner.action == nil
              ? nil
              : { @MainActor in if let action = banner.action { Task { await perform(action) } } }
          )
          .accessibilityIdentifier(banner.identifier)
        }
      }
      .padding(.bottom, WebSpace.sectionGap)
    }
  }

  // MARK: Agents

  @ViewBuilder private var agentStrip: some View {
    let visibility = DashboardModel.visibleAgents(
      agents, selected: selectedAgentID, showOffline: showOffline)
    let counts = running.counts
    let unread = unreadCounts
    if agents.isEmpty {
      Text("No agents discovered. Running agents will appear automatically.")
        .webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : WebSpace.dashboardGutter)
        .padding(.vertical, 8)
        .accessibilityIdentifier("agent-strip")
    } else {
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: WebSpace.agentGap) {
          ForEach(visibility.visible, id: \.sourceId) { agent in
            agentButton(
              agent, running: DashboardModel.runningCount(for: agent, counts: counts),
              unread: unread[agent.sourceId] ?? 0)
          }
          if visibility.hiddenOffline > 0 || showOffline {
            offlineToggle(hidden: visibility.hiddenOffline)
          }
        }
        .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : WebSpace.dashboardGutter)
        .padding(.top, 2)
        .padding(.bottom, 2)
      }
      .scrollIndicators(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Agents")
      .accessibilityIdentifier("agent-strip")
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
      VStack(spacing: 5) {
        Image(systemName: showOffline ? "eye.slash" : "eye")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(WebColor.textMuted.color)
          .frame(width: WebMetrics.agentSquare, height: WebMetrics.agentSquare)
          .background(
            RoundedRectangle(cornerRadius: WebRadius.medium, style: .continuous)
              .strokeBorder(
                WebColor.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        Text(showOffline ? "Hide" : "\(hidden) offline")
          .webFont(.agentLabel).foregroundStyle(WebColor.textMuted.color).lineLimit(1)
      }
      .padding(.top, 6)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      showOffline ? "Hide offline agents" : "Show \(hidden) offline agent\(hidden == 1 ? "" : "s")"
    )
    .accessibilityIdentifier("agent-offline-toggle")
  }

  // MARK: Search

  /// Web `.dashboard-search`: 42 pt, radius 12, subtle fill and a line-strong edge; focus
  /// raises the fill, turns the edge accent and adds the 3 px accent glow.
  private var searchField: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.medium, style: .continuous)
    return HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(WebColor.textMuted.color)
        .accessibilityHidden(true)
      TextField(
        "Search conversations", text: $query,
        prompt: Text("Search conversations").foregroundStyle(WebColor.textMuted.color)
      )
      .webFont(.search)
      .foregroundStyle(WebColor.text.color)
      .focused($searchFocused)
      .submitLabel(.search)
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .accessibilityIdentifier("search-field")
      if !query.isEmpty {
        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
          .labelStyle(.iconOnly)
          .font(.system(size: 13))
          .foregroundStyle(WebColor.textMuted.color)
          .frame(minWidth: 26, minHeight: 26)
          .contentShape(Rectangle())
          .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .frame(minHeight: WebMetrics.searchHeight)
    .background(
      searchFocused ? WebColor.surfaceRaised.color : WebColor.surfaceSubtle.color, in: shape
    )
    .overlay {
      shape.strokeBorder(
        searchFocused ? theme.palette.accent.color : WebColor.lineStrong.color, lineWidth: 1)
    }
    .background {
      if searchFocused { shape.inset(by: -3).fill(theme.palette.accentGlow) }
    }
    .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : WebSpace.dashboardGutter)
    .padding(.vertical, 12)
  }

  // MARK: Section heads

  /// Web `.dashboard-section-head`: an uppercase eyebrow, optional count and trailing control.
  private func sectionHead<Trailing: View>(
    _ title: String, count: Int? = nil, symbol: String? = nil, accent: Bool = false,
    note: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) -> some View {
    let tone = accent ? theme.palette.accent.color : WebColor.textMuted.color
    return HStack(alignment: .center, spacing: 10) {
      HStack(spacing: 6) {
        if let symbol {
          Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone).accessibilityHidden(true)
        }
        Eyebrow(title, color: tone)
        if let count {
          Text("\(count)").webFont(.sectionCount).foregroundStyle(tone)
        }
        if let note {
          Text(note).font(.system(size: 9, weight: .semibold)).tracking(0.36)
            .foregroundStyle(WebColor.textMuted.color).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      trailing()
    }
    .frame(minHeight: 26)
    .padding(.bottom, WebSpace.sectionHeadBottom)
  }

  /// Rows bleed 8 pt into the gutter (web `margin: 0 -8px`) and are divided by an inset line.
  private func rowList<Item, ID: Hashable, Row: View>(
    _ items: [Item], id: KeyPath<Item, ID>, scope: String, @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    ForEach(
      DashboardListProjection.rows(items, id: id, scope: scope)
    ) { entry in
      let item = entry.value
      let divided = items.first.map { $0[keyPath: id] != item[keyPath: id] } ?? false
      row(item)
        .padding(.top, divided ? 1 : 0)
        .overlay(alignment: .top) {
          if divided {
            Rectangle().fill(WebColor.line.color).frame(height: 1)
              .padding(.horizontal, WebSpace.rowPaddingHorizontal).accessibilityHidden(true)
          }
        }
        .padding(.horizontal, -WebSpace.rowPaddingHorizontal)
    }
  }

  private func rowButton(_ target: AppRoute, identifier: String, content: ConversationRowContent)
    -> some View
  {
    let thread = target.threadID.flatMap { id in
      store.cachedThreads.first { $0.id == id }
        ?? store.buckets.values.flatMap(\.threads).first { $0.id == id }
    }
    return DashboardRow(
      value: .init(
        target: target, identifier: identifier, content: content,
        selected: selectable && route == target,
        wakeStatus: thread?.wakeSchedule.map { WakeScheduleModel.status($0) }),
      select: { route = $0 }
    ).equatable()
      .contextMenu {
        if case .conversation(_, _, let id, _) = target,
          let thread = store.cachedThreads.first(where: { $0.id == id })
            ?? store.buckets.values.flatMap(\.threads).first(where: { $0.id == id })
        {
          Menu("Conversation tags", systemImage: "tag") {
            ForEach(store.tags.filter { $0.sourceId == thread.sourceId }, id: \.id) { tag in
              Button(
                "\(thread.tagIds.contains(tag.id) ? "Remove" : "Add") \(tag.name)",
                systemImage: thread.tagIds.contains(tag.id) ? "checkmark" : "tag"
              ) {
                let ids =
                  thread.tagIds.contains(tag.id)
                  ? thread.tagIds.filter { $0 != tag.id } : thread.tagIds + [tag.id]
                Task { try? await store.setConversationTags(threadID: id, tagIDs: ids) }
              }
            }
            Button("New tag…", systemImage: "plus") {
              tagEditor = .init(sourceID: thread.sourceId, threadID: id)
            }
            Menu("Edit tags") {
              ForEach(store.tags.filter { $0.sourceId == thread.sourceId }, id: \.id) { tag in
                Button(tag.name) { tagEditor = .init(sourceID: thread.sourceId, tagID: tag.id) }
              }
            }
          }.disabled(!store.canOrganize)
        }
      }
  }

  // MARK: Running

  @ViewBuilder private func runningSection(now: Date) -> some View {
    let projection = running
    if !projection.groups.isEmpty {
      sectionHead(
        "Running", count: projection.total, symbol: "waveform.path.ecg", accent: true,
        note: projection.authoritative ? nil : "Last known, not confirmed just now"
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Running, \(projection.total)\(projection.authoritative ? "" : ", last known")"
      )
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("running-section")
      ForEach(projection.groups, id: \.agent.sourceId) { group in
        let expanded = expandedAgents.contains(group.agent.sourceId)
        let cards =
          expanded
          ? group.threads : Array(group.threads.prefix(DashboardModel.runningCardsPerAgent))
        ForEach(
          DashboardListProjection.rows(cards, id: \.id, scope: "running")
        ) { entry in
          let thread = entry.value
          runningCard(thread, agent: group.agent, now: now)
            .padding(
              .top,
              group.agent.sourceId == projection.groups.first?.agent.sourceId
                && thread.id == cards.first?.id ? 0 : 7)
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
          .webFont(.rowSubtitle)
          .foregroundStyle(WebColor.textMuted.color)
          .padding(.horizontal, 7)
          .frame(minHeight: 27)
          .frame(minHeight: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
          .buttonStyle(.plain)
          .accessibilityIdentifier("running-more-\(group.agent.sourceId)")
          .padding(.top, 7)
        }
      }
      if projection.truncated {
        Text(
          "Showing \(DashboardModel.runningCount(projection.groups)) of \(projection.total)"
        )
        .webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color).padding(.top, 7)
      }
      Color.clear.frame(height: WebSpace.sectionGap).accessibilityHidden(true)
    }
  }

  /// Web `.running-card`: accent 7% into raised, accent 26% into line, radius 12, −8 bleed.
  private func runningCard(_ thread: WebThread, agent: WebAgentSummary, now: Date) -> some View {
    let target = conversationRoute(thread)
    return DashboardRow(
      value: .init(
        target: target, identifier: "running-row-\(thread.id)",
        content: DashboardRows.running(
          thread, agent: agent, confirmed: store.isRunningConfirmed(threadID: thread.id),
          projects: store.projects, now: now),
        selected: selectable && route == target, running: true), select: { route = $0 }
    ).equatable()
      .padding(.horizontal, -WebSpace.rowPaddingHorizontal)
  }

  // MARK: Projects

  @ViewBuilder private func projectsSection(now: Date) -> some View {
    let projects = projects
    if let agent = selectedAgentID {
      HStack {
        Button {
          projectsCollapsed.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .semibold))
              .rotationEffect(.degrees(projectsCollapsed ? -90 : 0))
              .foregroundStyle(WebColor.textMuted.color)
              .accessibilityHidden(true)
            sectionHead("Projects", note: projectsCollapsed ? "\(projects.count) hidden" : nil)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Projects, \(projects.count)")
        .accessibilityValue(projectsCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(projectsCollapsed ? "Shows the projects" : "Hides the projects")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("projects-section")
        Button("New", systemImage: "plus") { projectEditor = .init(sourceID: agent) }
          .buttonStyle(.plain).webFont(.footer).foregroundStyle(WebColor.textMuted.color)
          .frame(minHeight: 44).disabled(!store.canOrganize).accessibilityIdentifier(
            "new-project")
      }
      if !projectsCollapsed {
        rowList(projects, id: \.id, scope: "projects") { project in
          rowButton(
            AppRoute.project(profile: store.profile.id, sourceID: agent, projectID: project.id),
            identifier: "project-row-\(project.id)",
            content: DashboardRows.project(project, now: now))
        }
      }
      Color.clear.frame(height: WebSpace.sectionGap).accessibilityHidden(true)
    }
  }

  // MARK: Recent

  @ViewBuilder private func recentSection(now: Date) -> some View {
    let threads = recentThreads
    sectionHead(archived ? "Archived" : "Recent")
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("recent-section")
    if threads.isEmpty {
      recentEmpty
    }
    rowList(threads, id: \.id, scope: "recent") { thread in
      rowButton(
        conversationRoute(thread), identifier: "recent-row-\(thread.id)",
        content: DashboardRows.recent(
          thread, unread: store.isUnread(thread),
          confirmed: store.isRunningConfirmed(threadID: thread.id), projects: store.projects,
          tags: store.tags, now: now))
    }
    if let key = bucketKey, bucket?.nextCursor != nil {
      Button {
        Task {
          loadingOlder = true
          await store.refreshBucket(key, older: true)
          loadingOlder = false
        }
      } label: {
        HStack(spacing: 6) {
          if loadingOlder { ProgressView().controlSize(.mini) }
          Text(loadingOlder ? "Loading older conversations…" : "Load older conversations")
        }
        .webFont(.rowSubtitle)
        .foregroundStyle(WebColor.textSoft.color)
        .padding(.horizontal, 9)
        .frame(minHeight: 31)
        .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WebColor.line.color))
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(loadingOlder || !store.isStarted)
      .padding(.top, 8)
      .accessibilityIdentifier("load-older")
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
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recent-empty")
  }

  // MARK: Search results

  @ViewBuilder private func searchSections(now: Date) -> some View {
    let hits = search.hits
    if hits.isEmpty {
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
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("search-results")
    } else {
      let current = Dictionary(
        store.buckets.values.flatMap(\.threads).map { ($0.id, $0) },
        uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
      let active = hits.filter { $0.thread.archivedAt == nil }
      let shelved = hits.filter { $0.thread.archivedAt != nil }
      if !active.isEmpty {
        sectionHead("Conversations", note: search.status == .loading ? "Updating…" : nil)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("search-results")
        rowList(active, id: \.thread.id, scope: "search") { hit in
          searchRow(hit, current: current, now: now)
        }
        if search.truncated && shelved.isEmpty { truncatedNote }
        Color.clear.frame(height: WebSpace.sectionGap).accessibilityHidden(true)
      }
      if !shelved.isEmpty {
        sectionHead("Archived")
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(active.isEmpty ? "search-results" : "search-archived")
        rowList(shelved, id: \.thread.id, scope: "search") { hit in
          searchRow(hit, current: current, now: now)
        }
        if search.truncated { truncatedNote }
      }
    }
  }

  private var truncatedNote: some View {
    Text("Showing the closest matches. Add a word to narrow the search.")
      .webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
      .padding(.top, 8)
  }

  private func searchRow(_ hit: WebThreadSearchHit, current: [String: WebThread], now: Date)
    -> some View
  {
    rowButton(
      conversationRoute(current[hit.thread.id] ?? hit.thread),
      identifier: "search-row-\(hit.thread.id)",
      content: DashboardRows.search(
        hit, current: current[hit.thread.id], query: search.answeredQuery,
        projects: store.projects, now: now))
  }

  // MARK: Footer

  /// Web `.dashboard-footer`: data mode and Archived as quiet 32 pt glass pills. They float
  /// over the list with the system scroll-edge effect, not on a solid panel band (the web's
  /// 28 pt fade into the panel); GLASS-RULES.md.
  private var footer: some View {
    VStack(spacing: 0) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          dataModeMenu
          Spacer(minLength: 0)
          archiveToggle
        }
      }
      .padding(.horizontal, WebSpace.dashboardGutter - 7)
      .frame(minHeight: 44)
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
      HStack(spacing: 6) {
        Image(systemName: store.effectiveDataMode == .lean ? "leaf" : "waveform.path.ecg")
          .font(.system(size: 11, weight: .medium))
        Text(label).fontWeight(.semibold)
          .foregroundStyle(
            store.effectiveDataMode == .lean ? theme.palette.accent.color : WebColor.textMuted.color
          )
      }
      .webQuietPill(hitTarget: false)
    }
    .buttonStyle(.plain)
    .frame(minHeight: DesignMetrics.minimumHitTarget)
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
      HStack(spacing: 6) {
        Image(systemName: archived ? "bubble.left.and.bubble.right" : "archivebox")
          .font(.system(size: 11, weight: .medium))
        Text(title)
      }
    }
    .buttonStyle(WebQuietPillStyle())
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
