// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct CronReplyButton: View {
  let store: ConsoleStore
  let sourceID: String
  let jobID: String
  let runID: String
  let snapshotKind: String
  @Environment(\.consoleTheme) private var theme
  private var key: CronReplyKey { .init(sourceID: sourceID, jobID: jobID, runID: runID) }
  private var phase: CronReplyPhase { store.cronReplyPhase(key) }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Button(phase == .importing ? "Importing…" : phase == .retry ? "Retry Reply" : "Reply") {
        store.replyToCronRun(sourceID: sourceID, runID: runID, snapshotKind: snapshotKind)
      }
      .buttonStyle(.plain).webFont(.messageAction).fontWeight(.bold)
      .foregroundStyle(theme.palette.accent.color)
      .padding(.horizontal, 9).padding(.vertical, 3)
      .background(theme.palette.accentSoft.color, in: Capsule())
      .frame(minHeight: 44).contentShape(Rectangle())
      .disabled(
        phase == .importing || store.connection != .live
          || store.agent(sourceID)?.status == "offline"
      )
      .accessibilityIdentifier("cron-reply-" + runID)
      if let message = store.cronReplySnapshot(key)?.message {
        Text(message).webFont(.messageAction)
          .foregroundStyle(phase == .retry ? DesignColor.warning.color : DesignColor.danger.color)
          .accessibilityIdentifier("cron-reply-message-" + runID)
      }
    }
    .onChange(of: phase) { _, value in
      if value == .retry || value == .error {
        AccessibilityNotification.Announcement(
          store.cronReplySnapshot(key)?.message ?? "Reply needs attention"
        ).post()
      }
    }
  }
}

private struct CronTextButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.frame(minHeight: 44).contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

enum CronRunFace {
  static func color(_ status: String) -> Color {
    if ["failed", "dropped"].contains(status) { return DesignColor.danger.color }
    if ["cancelled", "skipped_overlap", "skipped_gate"].contains(status) {
      return DesignColor.warning.color
    }
    return WebColor.textSoft.color
  }
  static func state(_ value: String) -> String {
    value == "succeeded" ? "completed" : value.replacingOccurrences(of: "_", with: " ")
  }
  static func bounded(_ value: String) -> String { ProviderPresentation.boundedText(value) }
}

/// Web cron-run-row: top hairline followed by one wrapping row, never a centred marker.
struct CronRunTranscriptView: View {
  let run: TranscriptTelemetry.CronRun
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = false
  @State private var copied = false
  @Environment(\.consoleTheme) private var theme
  private var sourceID: String? { store.conversations[message.threadId]?.thread.sourceId }
  private var jobID: String? {
    guard let sourceID, let job = store.automationSnapshot(sourceID)?.job,
      job.threadID == message.threadId
    else { return nil }
    return job.jobID
  }
  private var loading: Bool {
    sourceID.flatMap { store.automationSnapshot($0)?.job }?.runs.loadingDetails.contains(run.runID)
      == true
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Rectangle().fill(WebColor.line.color).frame(height: 1).padding(.top, 10)
      WebFlowLayout(spacing: 9, lineSpacing: 5) {
        Button(run.title) { expanded.toggle() }
          .buttonStyle(CronTextButtonStyle()).webFont(.messageAction).fontWeight(.bold)
          .foregroundStyle(
            theme.palette.accent.color
          )
          .frame(minHeight: 44).accessibilityIdentifier("cron-run-link-" + run.runID)
        Text(run.status.capitalized).webFont(.messageAction).foregroundStyle(
          CronRunFace.color(run.rawStatus))
        if let at = run.orderedAt {
          Text(TranscriptPresentation.date(at)?.formatted() ?? CronRunFace.bounded(at))
            .webFont(.messageAction).monospacedDigit().foregroundStyle(WebColor.textMuted.color)
        }
        if ConsoleStore.cronRunIsTerminal(run.rawStatus), let sourceID, let jobID {
          CronReplyButton(
            store: store, sourceID: sourceID, jobID: jobID, runID: run.runID,
            snapshotKind: run.activityLoaded ? "detail" : "summary")
        }
        Button(expanded ? "Hide details" : "Details") { expanded.toggle() }
          .buttonStyle(CronTextButtonStyle()).webFont(.messageAction).foregroundStyle(
            WebColor.textMuted.color
          )
          .frame(minHeight: 44).accessibilityIdentifier("cron-run-details-" + run.runID)
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      }
      if expanded {
        VStack(alignment: .leading, spacing: 7) {
          if let artifact = run.artifactID { Text("Artifact " + artifact).webFont(.code) }
          if let session = run.sessionID {
            Button(copied ? "Session copied" : "Originating session") {
              UIPasteboard.general.string = session
              copied = true
            }.buttonStyle(CronTextButtonStyle()).webFont(.messageAction)
              .accessibilityLabel(
                copied ? "Originating session copied" : "Copy originating session " + session
              )
              .accessibilityIdentifier("cron-session-" + run.runID).frame(minHeight: 44)
          }
          if run.eventCount > 0, let sourceID {
            Button(
              loading
                ? "Loading activity…"
                : run.activityLoaded || run.activityStale ? "Refresh activity" : "Load activity"
            ) {
              Task { await store.loadCronRunActivity(sourceID: sourceID, runID: run.runID) }
            }.buttonStyle(CronTextButtonStyle()).webFont(.messageAction).frame(minHeight: 44)
              .disabled(loading)
              .accessibilityIdentifier("cron-activity-" + run.runID)
          }
          ForEach(
            run.details.filter {
              !$0.hasPrefix("Artifact") && !$0.hasPrefix("Originating session")
            }, id: \.self
          ) {
            Text($0).webFont(.messageAction).foregroundStyle(DesignColor.warning.color)
          }
        }.textSelection(.enabled).padding(9).background(
          WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WebColor.line.color, lineWidth: 1))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Cron run " + run.runID + ", " + run.status)
    .accessibilityIdentifier("cron-run-" + run.runID)
  }
}

struct CronRunHistory: View {
  let store: ConsoleStore
  let sourceID: String
  let job: CronJobState
  @State private var expanded = false
  @State private var openRun: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ContentDisclosure("cron-run-history", expanded: $expanded) {
        Button(job.runs.loading ? "Loading runs…" : "Refresh runs") {
          Task { await store.loadCronRuns(sourceID: sourceID) }
        }.buttonStyle(CronTextButtonStyle()).webFont(.system).frame(minHeight: 44).disabled(
          job.runs.loading
        )
        .accessibilityIdentifier("cron-runs-refresh")
        if job.runs.loaded && job.runs.runs.isEmpty {
          Text("No visible runs.").webFont(.system).accessibilityIdentifier("cron-runs-empty")
        }
        ForEach(job.runs.runs, id: \.runId) { run in
          VStack(alignment: .leading, spacing: 5) {
            WebFlowLayout(spacing: 9, lineSpacing: 5) {
              Button("Run \(run.sequence)") {
                openRun = openRun == run.runId ? nil : run.runId
                if openRun != nil {
                  Task { await store.loadCronRunActivity(sourceID: sourceID, runID: run.runId) }
                }
              }.buttonStyle(CronTextButtonStyle()).webFont(.system).fontWeight(.bold).frame(
                minHeight: 44
              )
              .accessibilityIdentifier("cron-history-" + run.runId)
              Text(
                CronRunFace.bounded(run.trigger) + " · "
                  + CronRunFace.state(CronRunFace.bounded(run.status))
              ).webFont(.messageAction)
                .foregroundStyle(CronRunFace.color(run.status))
              Text(ServerTimestamp.date(run.orderedAt)?.formatted() ?? "Unknown time").webFont(
                .messageAction)
              if ConsoleStore.cronRunIsTerminal(run.status) {
                CronReplyButton(
                  store: store, sourceID: sourceID, jobID: job.jobID, runID: run.runId,
                  snapshotKind: job.runs.details[run.runId] == nil ? "summary" : "detail")
              }
            }
            if openRun == run.runId {
              if let detail = job.runs.details[run.runId] {
                VStack(alignment: .leading, spacing: 10) {
                  ForEach(Array(detail.parts.enumerated()), id: \.offset) { _, part in
                    if case .telemetry = part {
                      EmptyView()
                    } else {
                      TranscriptPartView(part: part, message: detail, store: store)
                    }
                  }
                }.accessibilityIdentifier("cron-history-detail")
              } else if job.runs.loadingDetails.contains(run.runId) {
                Text("Loading activity…").webFont(.system)
              }
            }
          }
          Divider()
        }
        if job.runs.nextCursor != nil {
          Button("Load earlier runs") {
            Task { await store.loadCronRuns(sourceID: sourceID, older: true) }
          }
          .buttonStyle(CronTextButtonStyle()).webFont(.system).frame(minHeight: 44).disabled(
            job.runs.loading
          )
          .accessibilityIdentifier("cron-runs-older")
        }
      } label: {
        Text("Run history").webFont(.system)
      }
      if let error = job.runs.error {
        Text(error).webFont(.system).foregroundStyle(DesignColor.danger.color)
      }
    }
    .onChange(of: expanded) { _, value in
      if value && !job.runs.loaded { Task { await store.loadCronRuns(sourceID: sourceID) } }
    }
  }
}
