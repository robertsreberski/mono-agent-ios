// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Web AgentSection. Reads and commands are exclusively Store-owned; the view never retries a POST.
struct RestartSection: View {
  let store: ConsoleStore
  let agent: WebAgentSummary
  let wide: Bool
  #if DEBUG
    @Environment(\.fixtureReferenceDate) private var referenceDate
  #else
    private var referenceDate: Date? { nil }
  #endif
  private var state: AgentRestartState { store.agentRestartState(agent.sourceId) }
  private var label: String { ProviderPresentation.boundedText(agent.label) }
  private var count: Int? {
    if store.freshness != .fresh { return nil }
    return store.activeFleet?.runningCounts[agent.sourceId] ?? agent.runningCount
  }
  private var successfulNow: Bool { state.restartedThisVisit && state.outcome == "success" }
  private var title: String {
    if state.confirming { return "Restart \(label) now?" }
    if state.inProgress { return "Restarting \(label)" }
    if successfulNow { return "\(label) is back online" }
    return "Restart \(label)"
  }
  var body: some View {
    SettingsBox {
      switch state.readState {
      case .loading:
        Text("Checking restart status…").webFont(.settingsNote)
          .foregroundStyle(WebColor.textMuted.color).padding(14)
          .accessibilityIdentifier("agent-restart-loading")
      case .error:
        HStack {
          Text("Couldn't read restart status").webFont(.rowTitle)
            .foregroundStyle(WebColor.text.color)
          Spacer()
          Button("Retry") { store.loadLatestAgentRestart(sourceID: agent.sourceId) }
            .buttonStyle(SettingsButtonStyle()).accessibilityIdentifier("agent-restart-retry")
        }.padding(14)
      case .ready:
        Group {
          if wide {
            HStack(alignment: .center, spacing: 16) {
              restartCopy.frame(maxWidth: .infinity, alignment: .leading)
              restartActions
            }
          } else {
            VStack(alignment: .leading, spacing: 10) {
              restartCopy
              restartActions
            }
          }
        }.padding(14)
      }
      SettingsFactRow("Running now", wide: wide, identifier: "agent-restart-running") {
        Text(count.map { $0 == 0 ? "None" : "\($0) conversation\($0 == 1 ? "" : "s")" } ?? "—")
          .webFont(.rowTitle).foregroundStyle(WebColor.text.color)
      }
      if state.readState == .ready && !successfulNow && (!state.inProgress || last != nil) {
        SettingsFactRow("Last restart", wide: wide, identifier: "agent-restart-last") {
          TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Text(lastDescription(now: referenceDate ?? timeline.date)).webFont(.settingsNote)
              .foregroundStyle(WebColor.textMuted.color)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-restart-section")
    .onAppear { store.openAgentRestart(sourceID: agent.sourceId) }
    .onChange(of: agent.sourceId) { old, new in
      store.closeAgentRestart(sourceID: old)
      store.openAgentRestart(sourceID: new)
    }
    .onDisappear { store.closeAgentRestart(sourceID: agent.sourceId) }
    .onChange(of: state.noticeSerial) {
      if let notice = state.notice { AccessibilityNotification.Announcement(notice).post() }
    }
  }
  private var restartCopy: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).webFont(.rowTitle).foregroundStyle(WebColor.text.color)
        .accessibilityIdentifier("agent-restart-title")
      Text(explanation).webFont(.settingsNote).foregroundStyle(WebColor.textMuted.color)
        .accessibilityIdentifier("agent-restart-explanation")
      if state.inProgress { progress }
      if let unknown = state.requestUnknown { notice(unknown, id: "agent-restart-unknown") }
      if let warning = state.pollWarning { notice(warning, id: "agent-restart-poll-warning") }
      if state.outcome == "not_confirmed" {
        notice("Restart not confirmed — check the agent." + reason, id: "agent-restart-outcome")
      } else if state.outcome == "failure" {
        notice("Restart failed." + reason, id: "agent-restart-outcome", danger: true)
      }
      if state.requesting {
        Text("Requesting restart…").webFont(.settingsNote)
          .foregroundStyle(WebColor.textMuted.color)
          .accessibilityIdentifier("agent-restart-requesting")
      }
      if let disabled = store.agentRestartUnavailableReason(agent.sourceId) {
        notice(disabled, id: "agent-restart-unavailable")
      }
    }
  }
  @ViewBuilder private var restartActions: some View {
    if !state.requesting && !state.inProgress {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { actions }
        VStack(alignment: .leading, spacing: 10) { actions }
      }.fixedSize(horizontal: wide, vertical: false)
    }
  }
  private var explanation: String {
    if state.confirming {
      return "Restarting may interrupt active conversations, jobs and monitors."
        + (count.flatMap {
          $0 > 0
            ? " About \($0) running conversation\($0 == 1 ? "" : "s") will be interrupted (approximate)."
            : nil
        } ?? "")
    }
    if successfulNow { return "Restarted just now." }
    return "Relaunches the agent process. Running conversations, jobs and monitors are interrupted."
  }
  private var reason: String {
    (state.operation?.reason ?? state.requestFailure).map { " " + String($0.prefix(280)) } ?? ""
  }
  private var last: WebAgentRestartOperation? {
    let value =
      state.inProgress ? state.initialOperation : state.operation ?? state.initialOperation
    return value?.outcome == nil ? nil : value
  }
  private func lastDescription(now: Date) -> String {
    guard let last else { return "No recent restart" }
    let outcome =
      last.outcome == "success"
      ? "Back online" : last.outcome == "failure" ? "Failed" : "Not confirmed"
    // Opaque server timestamps, never used to correlate requests or recover operations.
    let age = DashboardModel.relativeTime(last.requestedAt, now: now)
    let when = age == "now" ? "just now" : age.isEmpty ? "Unknown time" : "\(age) ago"
    return outcome + " · " + when
      + (last.outcome == "failure"
        ? (last.reason.map { " · " + String($0.prefix(280)) } ?? "") : "")
  }
  @ViewBuilder private var actions: some View {
    if state.confirming {
      Button("Cancel") { store.cancelAgentRestartConfirmation(sourceID: agent.sourceId) }
        .buttonStyle(SettingsButtonStyle()).accessibilityIdentifier("agent-restart-cancel")
      Button("Confirm restart") { store.confirmAgentRestart(sourceID: agent.sourceId) }
        .buttonStyle(SettingsButtonStyle(kind: .danger))
        .disabled(store.agentRestartUnavailableReason(agent.sourceId) != nil)
        .accessibilityIdentifier("agent-restart-confirm")
    } else {
      Button("Restart…") { store.requestAgentRestartConfirmation(sourceID: agent.sourceId) }
        .buttonStyle(SettingsButtonStyle())
        .accessibilityLabel("Restart \(label)")
        .disabled(store.agentRestartUnavailableReason(agent.sourceId) != nil)
        .accessibilityIdentifier("agent-restart-open-confirmation")
    }
  }
  private var progress: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { steps }
      VStack(alignment: .leading, spacing: 8) { steps }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Restart progress")
    .accessibilityValue(
      state.stage == "back_online"
        ? "Back online" : state.stage == "restarting" ? "Restarting" : "Requesting"
    )
    .accessibilityIdentifier("agent-restart-progress")
  }
  @ViewBuilder private var steps: some View {
    ForEach(["requesting", "restarting", "back_online"], id: \.self) { step in
      Label(
        step == "back_online" ? "Back online" : step.capitalized,
        systemImage: step == state.stage ? "circle.inset.filled" : "circle"
      )
      .webFont(.settingsNote)
      .foregroundStyle(step == state.stage ? WebColor.text.color : WebColor.textMuted.color)
    }
  }
  private func notice(_ text: String, id: String, danger: Bool = false) -> some View {
    Text(ProviderPresentation.boundedText(text)).webFont(.settingsNote)
      .foregroundStyle(danger ? WebColor.danger.color : WebColor.warning.color)
      .accessibilityIdentifier(id)
  }
}
