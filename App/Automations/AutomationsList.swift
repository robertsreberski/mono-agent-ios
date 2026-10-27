// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct AutomationsList: View {
  let store: ConsoleStore
  let sourceID: String
  let query: String
  let selectedJobID: String?
  let open: (String) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.consoleTheme) private var theme
  private var state: AutomationState? { store.automationSnapshot(sourceID) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let overview = state?.overview {
        let live = store.automationIsAuthoritative(sourceID)
        if !live {
          ConnectionBanner(
            .notice, title: "Saved automation snapshot",
            message: state?.error ?? overview.degradedReason
              ?? "Live schedule status is unavailable. Saved \(state?.savedAt?.formatted() ?? overview.generatedAt)."
          )
          .accessibilityIdentifier("automations-snapshot")
        }
        if overview.jobsTruncated == true {
          Text("This overview is truncated. Some removed historical jobs may not be shown.")
            .webFont(.system).foregroundStyle(WebColor.textMuted.color)
        }
        let rows = AutomationPresentation.jobs(overview, query: query)
        if overview.jobs.isEmpty {
          EmptyStateView(
            "No automations configured", systemImage: "clock",
            message: "Scheduled jobs appear here before their first run."
          )
          .accessibilityElement(children: .combine).accessibilityIdentifier("automations-empty")
        } else if rows.isEmpty {
          EmptyStateView(
            "No matching automations", systemImage: "magnifyingglass",
            message:
              "No automation matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."
          )
          .accessibilityElement(children: .combine).accessibilityIdentifier("automations-no-match")
        } else {
          ForEach(rows, id: \.jobId) { job in
            Button {
              open(job.jobId)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock").foregroundStyle(theme.palette.accent.color)
                  .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                  HStack(alignment: .firstTextBaseline) {
                    Text(job.jobId).webFont(.rowTitle)
                    Spacer(minLength: 4)
                    Text(AutomationPresentation.state(job, live: live)).webFont(.rowSubtitle)
                  }
                  Text(
                    AutomationPresentation.runStatus(job) + " · " + job.health + " · "
                      + next(job, live: live) + " · " + AutomationPresentation.schedule(job)
                  )
                  .webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
                  .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                  if let date = AutomationPresentation.lastInvocation(job) {
                    Text("Last run " + date.formatted(date: .abbreviated, time: .shortened))
                      .webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
                  }
                }
              }
              .padding(.vertical, 10).padding(.horizontal, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                selectedJobID == job.jobId ? theme.palette.accentSoft.color : .clear,
                in: RoundedRectangle(cornerRadius: 8)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(WebColor.text.color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
              "Open run history for \(job.jobId), \(AutomationPresentation.state(job, live: live)), \(AutomationPresentation.schedule(job)), \(job.health), \(next(job, live: live))"
            )
            .accessibilityAddTraits(selectedJobID == job.jobId ? [.isSelected] : [])
            .accessibilityIdentifier("automation-row-" + job.jobId)
          }
        }
      } else if state?.loading == true {
        LoadingStateView("Loading automations…")
      } else {
        EmptyStateView(
          store.connection != .live ? "Automations unavailable offline" : "Automations unavailable",
          systemImage: "clock",
          message: state?.error ?? "No saved automation snapshot is available for this agent."
        )
        .accessibilityIdentifier("automations-unavailable")
      }
      if state?.error != nil {
        Button("Try again") { Task { await store.refreshAutomations(sourceID: sourceID) } }
          .designButtonStyle(.secondary).accessibilityIdentifier("automations-retry")
      }
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("automations-list")
    .task(id: sourceID) { await store.refreshAutomations(sourceID: sourceID) }
  }
  private func next(_ job: WebCronJob, live: Bool) -> String {
    if !job.configured { return "No longer scheduled" }
    if !live { return "Next run unavailable" }
    if !job.effectiveEnabled { return "No next run while disabled" }
    guard let date = AutomationPresentation.nextRun(job, live: live, now: Date()) else {
      return "Next run unavailable"
    }
    return "Next " + date.formatted(date: .abbreviated, time: .shortened)
  }
}
