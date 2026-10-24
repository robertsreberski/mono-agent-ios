// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ProjectScreen: View {
  let store: ConsoleStore
  let sourceID: String
  let projectID: String
  let navigate: (AppRoute?) -> Void
  @Environment(\.consoleTheme) private var theme
  @State private var editor: ProjectEditorRequest?
  @State private var creating = false
  @State private var error: String?
  private var project: WebProject? { store.projects.first { $0.id == projectID } }
  private var page: ProjectMembers { store.projectMembers[projectID] ?? ProjectMembers() }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          navigate(nil)
        } label: {
          Label(
            store.agents.first { $0.sourceId == sourceID }?.label ?? "Conversations",
            systemImage: "chevron.left")
        }
        .buttonStyle(.plain).foregroundStyle(WebColor.textSoft.color)
        Spacer()
        Button("Project settings", systemImage: "slider.horizontal.3") {
          editor = .init(sourceID: sourceID, projectID: projectID)
        }
        .buttonStyle(WebTileButtonStyle()).accessibilityIdentifier("project-settings-button")
        Button("New conversation", systemImage: "plus") { Task { await create() } }
          .buttonStyle(WebTileButtonStyle(.accent)).disabled(creating || !store.canOrganize)
          .accessibilityIdentifier("project-new-conversation")
      }.webFont(.conversationTitle).padding(.horizontal, 17).padding(.vertical, 7)
      ScrollView {
        if let project {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
              Eyebrow("Project")
              Text(project.name).webFont(.projectName).foregroundStyle(WebColor.text.color)
              Text(
                "\(project.conversationCount + (project.external == nil ? 0 : 1)) conversations · \(project.runningCount) running"
                  + cost(project)
              )
              .webFont(.projectMeta).foregroundStyle(WebColor.textMuted.color)
              if let known = project.monthKnownUsd {
                Text("Known cost \(UsagePresentation.usd(known)) this month").webFont(.contextNote)
              }
            }
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Eyebrow("Context")
                Spacer()
                Button("Edit") { editor = .init(sourceID: sourceID, projectID: projectID) }
                  .webQuietPill()
              }
              Text(
                project.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? "No context yet." : project.context
              )
              .webFont(.projectContext).foregroundStyle(
                project.context.isEmpty ? WebColor.textMuted.color : WebColor.textSoft.color)
              Text("Prepended to every conversation in this project").webFont(.contextNote)
                .foregroundStyle(WebColor.textMuted.color)
            }
            .padding(.vertical, 12).padding(.horizontal, 14).background(
              WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.line.color) }
            .webShadow(.small)
            HStack {
              Eyebrow("Conversations")
              Spacer()
              Text("Sorted by recent").webFont(.contextNote).foregroundStyle(
                WebColor.textMuted.color)
            }
            if let external = project.external {
              HStack {
                Image(systemName: "paperplane")
                VStack(alignment: .leading) {
                  Text(external.label).webFont(.rowTitle)
                  Text("Telegram · history not viewable here").webFont(.rowSubtitle)
                  if external.state != "open" {
                    Text(external.state == "closed" ? "Closed in Telegram" : "Telegram topic gone")
                      .webFont(.contextNote)
                  }
                }
              }.foregroundStyle(WebColor.textSoft.color)
            }
            if page.failed {
              ErrorStateView(
                "Conversations could not be refreshed", message: "Try again when connected.",
                retryTitle: "Retry conversations"
              ) { Task { await store.loadProjectMembers(id: projectID) } }
            }
            if page.threads.isEmpty {
              TranscriptNotice(page.loading ? "Loading conversations…" : "No conversations yet")
            }
            LazyVStack(spacing: 0) {
              ForEach(page.threads, id: \.id) { thread in
                Button {
                  navigate(
                    .conversation(
                      profile: store.profile.id, sourceID: thread.sourceId, threadID: thread.id,
                      archived: thread.archivedAt != nil))
                } label: {
                  ConversationRow(
                    DashboardRows.recent(
                      thread, unread: store.isUnread(thread),
                      confirmed: store.isRunningConfirmed(threadID: thread.id),
                      projects: store.projects, tags: store.tags, now: Date()))
                }.buttonStyle(WebRowButtonStyle()).accessibilityIdentifier(
                  "project-member-\(thread.id)")
                Rectangle().fill(WebColor.line.color).frame(height: 1)
              }
            }
            if page.nextCursor != nil {
              Button("Load older conversations") {
                Task { await store.loadProjectMembers(id: projectID, older: true) }
              }.disabled(page.loading)
            }
            if let error { Text(error).webFont(.system).foregroundStyle(WebColor.danger.color) }
          }.padding(17).frame(maxWidth: WebMetrics.column, alignment: .leading).frame(
            maxWidth: .infinity)
        } else {
          EmptyStateView(
            "Project unavailable", systemImage: "folder", message: "It may have been removed.")
        }
      }
      .refreshable { await store.loadProjectMembers(id: projectID) }
    }
    .background(theme.palette.panel.color).toolbar(.hidden, for: .navigationBar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("project-page")
    .task(id: projectID) {
      if store.selectedBucket?.sourceID != sourceID { await store.select(sourceID: sourceID) }
      await store.loadProjectMembers(id: projectID)
    }
    .sheet(item: $editor) { ProjectSettings(store: store, request: $0) }
    .onChange(of: project?.archivedAt) { if project?.archivedAt != nil { navigate(nil) } }
    .onChange(of: project?.id) { if project == nil { navigate(nil) } }
  }
  private func cost(_ project: WebProject) -> String {
    if case .unknown = project.monthCost { return " · cost unknown this month" }
    return project.monthUsd.map { " · \(UsagePresentation.usd($0)) this month" } ?? ""
  }
  private func create() async {
    guard !creating, store.canOrganize else { return }
    creating = true
    defer { creating = false }
    do {
      let id = try await store.createConversation(.init(sourceId: sourceID, projectId: projectID))
      navigate(
        .conversation(profile: store.profile.id, sourceID: sourceID, threadID: id, archived: false))
    } catch is CancellationError {} catch { self.error = OrganizeError.failed.localizedDescription }
  }
}
