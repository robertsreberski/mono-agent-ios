// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentDesign
import MonoAgentKit

/// Turns summaries into design-system row values. Pure, so badges and wording are unit-tested.
enum DashboardRows {
  private static func kindLeading(_ thread: WebThread) -> ConversationRowContent.Leading {
    let kind = DashboardModel.kind(thread)
    let tone: StatusTone =
      switch kind {
      case .alert: .danger
      case .cron, .webhook: .accent
      case .chat: .neutral
      }
    // A failure takes the glyph; the spoken name still says where the conversation came from.
    let label =
      kind == .alert && thread.trigger != nil
      ? "\(kind.label), \(thread.trigger?.kind ?? "") conversation" : kind.label
    return .symbol(kind.systemImage, label: label, tone: tone)
  }

  private static func title(_ thread: WebThread) -> String {
    thread.title.isEmpty ? "Untitled conversation" : thread.title
  }

  private static func project(_ thread: WebThread, _ projects: [WebProject])
    -> ConversationRowContent.Chip?
  {
    DashboardModel.projectLabel(thread, projects: projects).map {
      .init($0.name, color: LabelColor(serverValue: $0.color))
    }
  }

  /// The web route badge (`model · effort`): the conversation override, else the last
  /// reported thread route. Nothing is drawn when the console reported neither.
  static func routeBadge(_ thread: WebThread) -> String? {
    func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    guard let model = nonempty(thread.runModel) ?? nonempty(thread.runState.model) else {
      return nil
    }
    let effort = nonempty(thread.runEffort) ?? nonempty(thread.runState.effort)
    return model + " · " + (effort.map { $0 == "none" ? "off" : $0 } ?? "—")
  }

  private static func activity(_ active: Bool, confirmed: Bool) -> ActivityState? {
    active ? (confirmed ? .running : .lastKnown) : nil
  }

  /// A Recent (or archive shelf) row.
  static func recent(
    _ thread: WebThread, unread: Bool, confirmed: Bool, projects: [WebProject], tags: [WebTag],
    now: Date
  ) -> ConversationRowContent {
    let presentation = DashboardModel.presentation(thread)
    let preview =
      thread.runState.status == "running"
      ? DashboardModel.runningStatus(thread)
      : presentation.text.isEmpty ? DashboardModel.excerpt(thread) : presentation.text
    let rowTags = thread.tagIds.compactMap { id in
      tags.first { $0.id == id && $0.sourceId == thread.sourceId }
    }
    return ConversationRowContent(
      leading: kindLeading(thread), title: AttributedString(title(thread)),
      time: DashboardModel.relativeTime(thread.updatedAt, now: now),
      timeAccessibility: DashboardModel.spokenTime(thread.updatedAt, now: now), unread: unread,
      scheduled: thread.wakeSchedule?.state == "active",
      activity: activity(presentation.active, confirmed: confirmed),
      preview: preview.map(AttributedString.init), previewPending: presentation.active,
      project: project(thread, projects),
      tags: rowTags.map { .init($0.name, color: LabelColor(serverValue: $0.color)) },
      route: routeBadge(thread))
  }

  /// A Running card: the card's own agent, never the selected one.
  static func running(
    _ thread: WebThread, agent: WebAgentSummary, confirmed: Bool, projects: [WebProject],
    now: Date
  ) -> ConversationRowContent {
    ConversationRowContent(
      leading: .monogram(DashboardModel.initials(agent.label), label: agent.label),
      title: AttributedString(title(thread)),
      time: DashboardModel.relativeTime(thread.updatedAt, now: now),
      timeAccessibility: DashboardModel.spokenTime(thread.updatedAt, now: now),
      activity: confirmed ? .running : .lastKnown,
      preview: AttributedString(DashboardModel.runningStatus(thread)),
      previewPending: DashboardModel.runningPending(thread), project: project(thread, projects),
      accessibilityContext: "on \(agent.label)", route: routeBadge(thread))
  }

  /// A search hit. The fresher held summary wins when this device has one.
  static func search(
    _ hit: WebThreadSearchHit, current: WebThread?, query: String, projects: [WebProject],
    now: Date
  ) -> ConversationRowContent {
    let thread = current.map { $0.revision >= hit.thread.revision ? $0 : hit.thread } ?? hit.thread
    let preview: AttributedString =
      if let snippet = hit.snippet {
        SearchHighlight.attributed(SearchHighlight.segments(snippet))
      } else if hit.titleMatch {
        AttributedString("Matched the title")
      } else {
        AttributedString(thread.lastMessagePreview ?? "No matching message text")
      }
    return ConversationRowContent(
      leading: kindLeading(thread),
      title: SearchHighlight.attributed(SearchHighlight.title(title(hit.thread), query: query)),
      time: DashboardModel.relativeTime(thread.updatedAt, now: now),
      timeAccessibility: DashboardModel.spokenTime(thread.updatedAt, now: now),
      preview: preview, project: project(thread, projects),
      detail: hit.messageMatches > 1 ? "\(hit.messageMatches) matches" : nil)
  }

  /// A project row: chats, last update and running/external state.
  static func project(_ project: WebProject, now: Date) -> ConversationRowContent {
    let chats = project.conversationCount + (project.external == nil ? 0 : 1)
    let channel =
      project.external.map { $0.channel.prefix(1).uppercased() + $0.channel.dropFirst() + " · " }
      ?? ""
    let detail: String? =
      if project.runningCount > 0 {
        "\(project.runningCount) running"
      } else if project.external?.state == "gone" {
        "Topic gone"
      } else if project.external?.state == "closed" {
        "Closed"
      } else {
        nil
      }
    return ConversationRowContent(
      leading: .folder(LabelColor(serverValue: project.color)),
      title: AttributedString(project.name),
      preview: AttributedString(
        "\(channel)\(chats) chat\(chats == 1 ? "" : "s") · updated "
          + DashboardModel.relativeTime(project.updatedAt, now: now)),
      detail: detail, accessibilityContext: "project", chevron: true)
  }
}
