// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore

/// Everything the dashboard decides about agents and conversations without a view or a store.
/// Mirrors the web console's `dashboard-model.ts`, `thread-presentation.ts`, `unread.ts`,
/// `running-count.ts` and `console-store.tsx` agent ordering. Pure, so it is unit-tested.
enum DashboardModel {
  // MARK: Agents

  /// One letter per word, or the first two of a single word. Never empty.
  static func initials(_ label: String) -> String {
    let words = label.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
    guard let first = words.first else { return "A" }
    let letters =
      words.count == 1
      ? String(first.prefix(2)) : words.prefix(2).map { String($0.prefix(1)) }.joined()
    return letters.uppercased()
  }

  /// The label's first word, drawn under the square; the full label is spoken.
  static func shortLabel(_ label: String) -> String {
    label.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? label
  }

  /// Pinned (favourite) agents first, then ASCII-case-insensitive label, then source ID.
  static func sortPinnedFirst(_ agents: [WebAgentSummary]) -> [WebAgentSummary] {
    // SQLite NOCASE folds ASCII only; matching it keeps refreshes from reordering labels.
    func fold(_ text: String) -> String {
      var scalars = String.UnicodeScalarView()
      for scalar in text.unicodeScalars {
        scalars.append(
          (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar)
      }
      return String(scalars)
    }
    return agents.sorted { left, right in
      let leftPinned = left.pinned == true
      let rightPinned = right.pinned == true
      if leftPinned != rightPinned { return leftPinned }
      let l = fold(left.label)
      let r = fold(right.label)
      if l != r { return l < r }
      return left.sourceId < right.sourceId
    }
  }

  /// Offline, unpinned, unselected agents fold behind one "Show N offline" control.
  static func visibleAgents(
    _ agents: [WebAgentSummary], selected: String?, showOffline: Bool
  ) -> (visible: [WebAgentSummary], hiddenOffline: Int) {
    let hidden = Set(
      agents.filter { $0.status == "offline" && $0.pinned != true && $0.sourceId != selected }
        .map(\.sourceId))
    return (showOffline ? agents : agents.filter { !hidden.contains($0.sourceId) }, hidden.count)
  }

  // MARK: Thread presentation

  enum Kind: Equatable {
    case alert, cron, webhook, chat

    var systemImage: String {
      switch self {
      case .alert: "exclamationmark.triangle.fill"
      case .cron: "clock"
      case .webhook: "bolt.horizontal"
      case .chat: "bubble.left"
      }
    }

    var label: String {
      switch self {
      case .alert: "Needs attention"
      case .cron: "Scheduled"
      case .webhook: "Webhook"
      case .chat: "Conversation"
      }
    }
  }

  private static let jobOutcomes = [
    "succeeded": "Completed", "failed": "Background job failed",
    "timed_out": "Background job timed out", "cancelled": "Background job cancelled",
    "spawn_failed": "Background job failed to start",
    "queue_expired": "Background job expired in queue",
    "interrupted": "Background job interrupted",
  ]

  private struct Outcome {
    var terminal: WebJobActivity.Terminal?
    var jobIsLatest: Bool
    var error: String?
  }

  private static func classify(_ thread: WebThread) -> Outcome {
    let terminal = thread.jobActivity?.latestTerminal
    let run = thread.runState
    let status = run.lastOutcome?.status ?? run.status
    let finishedAt = run.lastOutcome == nil ? run.finishedAt : run.lastOutcome?.finishedAt
    var jobIsLatest = false
    if let terminal {
      if let finished = finishedAt.flatMap(parseDate),
        let completed = parseDate(terminal.completedAt)
      {
        jobIsLatest = completed > finished
      } else {
        jobIsLatest = finishedAt == nil
      }
    }
    let error: String?
    if jobIsLatest, let terminal {
      error = terminal.state == "succeeded" ? nil : jobOutcomes[terminal.state]
    } else {
      error =
        switch status {
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        case "interrupted": "Interrupted"
        default: nil
        }
    }
    return Outcome(terminal: terminal, jobIsLatest: jobIsLatest, error: error)
  }

  /// The failure the conversation is currently presenting; a running turn is never troubled.
  static func outcomeError(_ thread: WebThread) -> String? {
    thread.runState.status == "running" ? nil : classify(thread).error
  }

  static func jobSummaries(_ thread: WebThread) -> [String] {
    let activity = thread.jobActivity
    return [
      ("running", activity?.running ?? 0), ("starting", activity?.starting ?? 0),
      ("queued", activity?.queued ?? 0),
    ]
    .compactMap { state, count in
      count > 0 ? "\(count) background \(count == 1 ? "job" : "jobs") \(state)" : nil
    }
  }

  /// The row's status text and whether work is in flight. Both describe the same work.
  static func presentation(_ thread: WebThread) -> (text: String, active: Bool) {
    let jobs = jobSummaries(thread)
    if thread.runState.status == "running" {
      return ((["Working…"] + jobs).joined(separator: " · "), true)
    }
    let outcome = classify(thread)
    if !jobs.isEmpty {
      return (((outcome.error.map { [$0] } ?? []) + jobs).joined(separator: " · "), true)
    }
    if let error = outcome.error { return (error, false) }
    if outcome.jobIsLatest && outcome.terminal != nil { return ("", false) }
    let status = thread.runState.lastOutcome?.status ?? thread.runState.status
    if status == "complete" { return ("", false) }
    return (thread.messageCount > 0 ? "No reply yet" : "New conversation", false)
  }

  /// The newest reply, only in the slot an idle success leaves empty, collapsed to one line.
  static func excerpt(_ thread: WebThread) -> String? {
    guard presentation(thread).text.isEmpty, let preview = thread.lastMessagePreview else {
      return nil
    }
    let collapsed = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  /// Failure first, then how the conversation started.
  static func kind(_ thread: WebThread) -> Kind {
    if outcomeError(thread) != nil { return .alert }
    switch thread.trigger?.kind {
    case "cron": return .cron
    case "webhook": return .webhook
    default: return .chat
    }
  }

  /// Recent lists conversations; a cron channel is an automation's history.
  static func isRecent(_ thread: WebThread) -> Bool { thread.trigger?.kind != "cron" }

  /// The loaded project wins (it has the colour); otherwise the row's own project name.
  static func projectLabel(_ thread: WebThread, projects: [WebProject]) -> (
    name: String, color: String
  )? {
    guard let id = thread.projectId else { return nil }
    if let project = projects.first(where: { $0.id == id && $0.sourceId == thread.sourceId }) {
      return (project.name, project.color ?? "default")
    }
    return thread.projectName.map { ($0, "default") }
  }

  // MARK: Running

  /// How many cards one agent contributes before the rest fold away.
  static let runningCardsPerAgent = 2

  struct RunningGroup: Equatable {
    var agent: WebAgentSummary
    var threads: [WebThread]
  }

  /// The fallback when no fresh fleet listing stands behind Running: the listed rows that are
  /// active, overlaid by held (cached) running conversations. Never evidence of an idle fleet.
  static func mergeRunning(cached: [WebThread], listed: [WebThread]) -> [WebThread] {
    var order: [String] = []
    var byID: [String: WebThread] = [:]
    for thread in listed where presentation(thread).active {
      if byID[thread.id] == nil { order.append(thread.id) }
      byID[thread.id] = thread
    }
    for thread in cached {
      if byID[thread.id] == nil { order.append(thread.id) }
      byID[thread.id] = thread
    }
    return order.compactMap { byID[$0] }
  }

  /// Grouped into console agent order, most recent first; unknown agents drop out.
  static func groupRunning(_ running: [WebThread], agents: [WebAgentSummary]) -> [RunningGroup] {
    let bySource = Dictionary(grouping: running, by: \.sourceId)
    return agents.compactMap { agent in
      guard let threads = bySource[agent.sourceId], !threads.isEmpty else { return nil }
      return RunningGroup(
        agent: agent,
        threads: threads.sorted { a, b in
          let l = parseDate(a.updatedAt) ?? .distantPast
          let r = parseDate(b.updatedAt) ?? .distantPast
          return l != r ? l > r : a.id < b.id
        })
    }
  }

  static func runningCount(_ groups: [RunningGroup]) -> Int {
    groups.reduce(0) { $0 + $1.threads.count }
  }

  /// What one running card says: tool calls, a question waiting, cost so far, jobs.
  static func runningStatus(_ thread: WebThread) -> String {
    guard thread.runState.status == "running", let activity = thread.runState.activity else {
      return presentation(thread).text
    }
    let calls = activity.toolCallCount
    let head =
      activity.phase == "asking"
      ? "Asking you a question"
      : calls > 0 ? "Working · \(calls) tool call\(calls == 1 ? "" : "s")" : "Working…"
    var parts = [head] + jobSummaries(thread)
    if activity.costUnknown == true {
      parts.append("cost unknown")
    } else if let usd = activity.cumulativeUsd {
      parts.append(formatUSD(usd))
    }
    return parts.joined(separator: " · ")
  }

  /// Whether the card has been told anything yet about the turn it draws.
  static func runningPending(_ thread: WebThread) -> Bool {
    thread.runState.status != "running" || thread.runState.activity == nil
  }

  static func formatUSD(_ value: Double) -> String {
    value < 0.01 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
  }

  struct RunningProjection: Equatable {
    var groups: [RunningGroup]
    /// A fresh, live fleet listing stands behind the section.
    var authoritative: Bool
    /// The server's total (authoritative), else the cards drawn.
    var total: Int
    var truncated: Bool
    /// Per-agent badge counts: the server's when authoritative, else what is drawn.
    var counts: [String: Int]
  }

  static func running(
    fleet: WebActiveThreads?, authoritative: Bool, cached: [WebThread], listed: [WebThread],
    agents: [WebAgentSummary]
  ) -> RunningProjection {
    if authoritative, let fleet {
      let groups = groupRunning(fleet.threads, agents: agents)
      return RunningProjection(
        groups: groups, authoritative: true, total: fleet.total, truncated: fleet.truncated,
        counts: fleet.runningCounts)
    }
    let merged = mergeRunning(
      cached: cached.filter { presentation($0).active }, listed: (fleet?.threads ?? []) + listed)
    let groups = groupRunning(merged, agents: agents)
    return RunningProjection(
      groups: groups, authoritative: false, total: runningCount(groups), truncated: false,
      counts: Dictionary(uniqueKeysWithValues: groups.map { ($0.agent.sourceId, $0.threads.count) })
    )
  }

  /// An absent count is unknown; only an explicit zero means no running work.
  static func runningCount(for agent: WebAgentSummary, counts: [String: Int]) -> Int {
    counts[agent.sourceId] ?? agent.runningCount ?? 0
  }

  /// Unread conversations per agent over everything this device has been told about.
  static func unreadCounts(_ threads: [WebThread], isUnread: (WebThread) -> Bool) -> [String: Int] {
    var seen = Set<String>()
    var counts: [String: Int] = [:]
    for thread in threads where seen.insert(thread.id).inserted && isUnread(thread) {
      counts[thread.sourceId, default: 0] += 1
    }
    return counts
  }

  // MARK: Time

  static func parseDate(_ text: String) -> Date? {
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  /// A row's age: minutes/hours/days within a week, then the short date.
  static func relativeTime(
    _ text: String, now: Date, locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    guard let date = parseDate(text) else { return "" }
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    var style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
    style.calendar = Calendar(identifier: .gregorian)
    return date.formatted(style)
  }

  /// The same age in words for VoiceOver ("5 minutes ago").
  static func spokenTime(
    _ text: String, now: Date, locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    guard let date = parseDate(text) else { return "" }
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    func plural(_ value: Int, _ unit: String) -> String {
      "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }
    if minutes < 1 { return "just now" }
    if minutes < 60 { return plural(minutes, "minute") }
    if minutes < 24 * 60 { return plural(minutes / 60, "hour") }
    if minutes < 7 * 24 * 60 { return plural(minutes / (24 * 60), "day") }
    var style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.wide).day()
    style.calendar = Calendar(identifier: .gregorian)
    return date.formatted(style)
  }

  // MARK: Data mode

  /// The setting, and for Auto what it currently resolves to.
  static func dataModeLabel(_ setting: DataMode, effective: DataMode) -> String {
    switch setting {
    case .auto: "Auto · \(effective == .lean ? "Lean" : "Full")"
    case .lean: "Lean"
    case .full: "Full"
    }
  }

  /// Auto → Lean → Full → Auto: every state reachable by repeated taps.
  static func nextDataMode(_ setting: DataMode) -> DataMode {
    switch setting {
    case .auto: .lean
    case .lean: .full
    case .full: .auto
    }
  }
}
