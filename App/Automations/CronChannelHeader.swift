// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct CronChannelHeader: View {
  let store: ConsoleStore
  let sourceID: String
  let jobID: String
  let threadID: String
  var lastRunAnchor: (String) -> Void = { _ in }
  @State private var expanded = false
  private var state: AutomationState? { store.automationSnapshot(sourceID) }
  private var job: WebCronJob? {
    state?.overview?.jobs.first { $0.jobId == jobID && $0.threadId == threadID }
  }
  private var control: CronJobState? { state?.job }
  private var reason: String? {
    store.cronActionUnavailableReason(sourceID: sourceID, jobID: jobID, threadID: threadID)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ContentDisclosure("cron-header", expanded: $expanded) {
        facts
        actions
        if let reason { Text(reason).webFont(.system).foregroundStyle(WebColor.textMuted.color) }
      } label: {
        Text("\(job?.expression ?? "Unknown") · \(stateLabel) · Next \(nextTime)")
          .webFont(.system).foregroundStyle(WebColor.textSoft.color)
      }
      if let error = control?.error ?? state?.error {
        Text(error).webFont(.system).foregroundStyle(DesignColor.danger.color)
          .accessibilityIdentifier("cron-error")
      }
      if let notice = control?.notice {
        Text(notice).webFont(.system).foregroundStyle(WebColor.textSoft.color)
          .accessibilityIdentifier("cron-notice")
      }
      if state?.overview?.jobsTruncated == true {
        Text("Older historical jobs are omitted from this bounded overview.").webFont(.system)
      }
    }
    .padding(.horizontal, WebSpace.transcriptGutter).padding(.bottom, 16)
    .task(id: sourceID + jobID + (store.agent(sourceID)?.generation ?? "")) {
      expanded = false
      store.openCronJob(sourceID: sourceID, jobID: jobID, threadID: threadID)
      await store.refreshAutomations(sourceID: sourceID)
    }
    .onDisappear { store.closeCronJob(sourceID: sourceID) }
    .sheet(
      isPresented: Binding(
        get: { control?.confirmation != nil },
        set: { if !$0 { store.cancelCronConfirmation(sourceID: sourceID) } })
    ) {
      confirmation
    }
    .sheet(
      isPresented: Binding(
        get: { control?.configOpen == true },
        set: { if !$0 { store.closeCronConfig(sourceID: sourceID) } })
    ) {
      if let config = control?.config {
        CronConfigView(config: config) { store.closeCronConfig(sourceID: sourceID) }
      }
    }
    .onChange(of: control?.notice) { _, value in
      if let value { AccessibilityNotification.Announcement(value).post() }
    }
  }
  private var stateLabel: String {
    guard let job else { return "Unknown" }
    return AutomationPresentation.state(job, live: store.automationIsAuthoritative(sourceID))
  }
  private var nextTime: String {
    guard let job,
      let date = AutomationPresentation.nextRun(
        job,
        live: store.automationIsAuthoritative(sourceID), now: Date())
    else { return "Unknown" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
  private func fact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).webFont(.eyebrow).foregroundStyle(WebColor.textMuted.color)
      Text(value).webFont(.system).foregroundStyle(WebColor.text.color).textSelection(.enabled)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var facts: some View {
    VStack(alignment: .leading, spacing: 12) {
      fact("Schedule", job?.expression ?? "Unknown")
      fact("Timezone", job?.timezone ?? "Unknown")
      fact("State", stateLabel)
      if let job, job.declaredEnabled != job.effectiveEnabled {
        Text(
          "Config \(job.declaredEnabled ? "enabled" : "disabled"); runtime override \(job.effectiveEnabled ? "enabled" : "disabled")"
        )
        .webFont(.system).foregroundStyle(WebColor.textMuted.color)
      }
      if let run = job?.lastRun {
        Button {
          lastRunAnchor(run.runId)
        } label: {
          fact("Last run", ServerTimestamp.date(run.orderedAt)?.formatted() ?? "Unknown")
        }.buttonStyle(.plain).accessibilityIdentifier("cron-last-run")
      } else {
        fact("Last run", "Unknown")
      }
      fact("Next run", nextTime)
      fact("Health", job?.health ?? "unknown")
    }
  }
  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack { actionButtons }
      VStack(alignment: .leading) { actionButtons }
    }
  }
  @ViewBuilder private var actionButtons: some View {
    Button("Run now") { store.performCronAction(sourceID: sourceID, action: .run) }
      .designButtonStyle(.primary).disabled(
        reason != nil || control == nil
          || (control?.busy == true || state?.pendingJobs.contains(jobID) == true)
          || control?.confirmation != nil
      )
      .accessibilityIdentifier("cron-run-now")
    Button(job?.effectiveEnabled == true ? "Disable" : "Enable") {
      store.performCronAction(
        sourceID: sourceID, action: .enabled(!(job?.effectiveEnabled ?? false)))
    }.designButtonStyle(.secondary).disabled(
      reason != nil || control == nil
        || (control?.busy == true || state?.pendingJobs.contains(jobID) == true)
        || control?.confirmation != nil
    )
    .accessibilityIdentifier("cron-enabled")
    Button("View config") { store.openCronConfig(sourceID: sourceID) }
      .designButtonStyle(.secondary)
      .disabled(
        store.connection != .live || store.agent(sourceID)?.status == "offline"
          || store.agent(sourceID)?.cron?.read != true || control == nil
          || (control?.busy == true || state?.pendingJobs.contains(jobID) == true)
          || control?.confirmation != nil
      )
      .accessibilityIdentifier("cron-config")
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 20) {
      WebSheetHeader(
        "Confirm cron action", subtitle: "Confirmation required", closeLabel: "Cancel",
        closeIdentifier: "cron-confirm-close"
      ) { store.cancelCronConfirmation(sourceID: sourceID) }
      if let challenge = control?.confirmation?.challenge {
        Text(ProviderPresentation.boundedText(challenge.message)).webFont(.system)
        Text(
          "Confirmation expires \(ServerTimestamp.date(challenge.expiresAt)?.formatted() ?? "Unknown")."
        )
        .webFont(.system).foregroundStyle(WebGlass.textMuted.color)
      }
      if let error = control?.error { Text(error).webFont(.system) }
      HStack {
        Button("Cancel") { store.cancelCronConfirmation(sourceID: sourceID) }
          .designButtonStyle(.secondary, placement: .floating).accessibilityIdentifier(
            "cron-confirm-cancel")
        Spacer()
        Button(
          (control?.busy == true || state?.pendingJobs.contains(jobID) == true)
            ? "Applying…" : "Confirm"
        ) {
          Task { await store.confirmCronAction(sourceID: sourceID) }
        }.designButtonStyle(.primary, placement: .floating).accessibilityIdentifier(
          "cron-confirm-submit"
        ).disabled(reason != nil)
      }.disabled((control?.busy == true || state?.pendingJobs.contains(jobID) == true))
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .webSheetVeil().presentationDetents([.medium, .large])
      .interactiveDismissDisabled(
        (control?.busy == true || state?.pendingJobs.contains(jobID) == true)
      )
      .accessibilityElement(children: .contain).accessibilityIdentifier("cron-confirmation")
  }
}
