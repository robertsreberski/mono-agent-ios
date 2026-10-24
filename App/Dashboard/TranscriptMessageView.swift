// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct TranscriptMessageView: View {
  let row: TranscriptMessageState
  let store: ConsoleStore
  @State private var gallery = ReplyMessageGallery()
  #if DEBUG
    @Environment(\.fixtureReferenceDate) private var referenceDate
  #endif
  private var actionDate: Date {
    #if DEBUG
      if let referenceDate { return referenceDate }
    #endif
    return Date().addingTimeInterval(store.serverClockOffset)
  }
  private var hasMcp: Bool {
    row.message.parts.contains { if case .mcpApp = $0 { true } else { false } }
  }
  private var isUser: Bool { row.message.role == "user" }
  private var role: String {
    isUser ? "You" : row.message.role == "assistant" ? "Assistant" : "System"
  }
  /// Web message layout: the user's turn is a neutral bubble on the trailing edge with its
  /// actions below; assistant prose sits directly on the panel (no bubble, card or avatar).
  var body: some View {
    #if DEBUG
      let _ = PerformanceProbe.body("TranscriptMessageView")
    #endif
    let message = row.message
    VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
      if message.role == "system" {
        messageContent(message)
          .padding(.vertical, 8).padding(.horizontal, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .overlay(alignment: .leading) {
            Rectangle().fill(WebColor.lineStrong.color).frame(width: 2)
          }
          .padding(.vertical, 18)
      } else if isUser {
        UserBubble { messageContent(message) }
      } else {
        messageContent(message).frame(maxWidth: .infinity, alignment: .leading)
      }
      // Web: the action row belongs to a settled message, not one still being written.
      if message.status != "running" && message.role != "system" {
        actions(message).quotable(message, enabled: hasMcp)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    // The whole row (not only its glyphs) opens the message menu, as hovering it does on the web.
    .contentShape(Rectangle())
    .quotable(message, enabled: !hasMcp)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-" + message.id)
    .fullScreenCover(
      isPresented: Binding(get: { gallery.openID != nil }, set: { if !$0 { gallery.openID = nil } })
    ) {
      ReplyLightbox(
        images: gallery.images(in: message),
        selected: Binding(
          get: { gallery.openID ?? "" }, set: { gallery.openID = $0 }
        )
      ) { gallery.openID = nil }
    }
    .onDisappear { if gallery.openID == nil { gallery.clear(store: store) } }
  }

  @ViewBuilder private func messageContent(_ message: WebMessage) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if isUser, !message.attachments.isEmpty {
        messageAttachments(message).padding(.bottom, 8)
      }
      VStack(alignment: .leading, spacing: 10) {
        if let quote = message.quote {
          MessageQuote(quote.text)

        }
        ForEach(
          TranscriptPresentation.activityBands(
            message.parts.filter { TranscriptTelemetry.visible($0, in: message) })
        ) { band in
          if band.parts.allSatisfy(TranscriptPresentation.isActivity) {
            TranscriptActivityBand(parts: band.parts, message: message, store: store)
          } else if band.parts.allSatisfy(TranscriptPresentation.isReplyImage) {
            ReplyImagesView(
              parts: band.parts.compactMap {
                if case .attachment(let value) = $0 { return value }
                return nil
              }, message: message, store: store, gallery: gallery)
          } else if let part = band.parts.first {
            if message.role == "system", case .text(let value) = part {
              Text(value.text).webFont(.prose).foregroundStyle(WebColor.text.color)
                .textSelection(.enabled)
            } else {
              TranscriptPartView(part: part, message: message, store: store)
            }
          }
        }
        if !isUser { messageAttachments(message) }
        if message.parts.isEmpty && message.status == "running" {
          Label("Thinking…", systemImage: "sparkles").webFont(.reasoningTrigger)
            .foregroundStyle(WebColor.textMuted.color)
        }
        if let status = message.liveInputStatus {
          Text("Follow-up · " + status).webFont(.messageAction)
            .foregroundStyle(WebColor.textMuted.color)
        }
        if message.role == "assistant" {
          RunAttributionView(message: message, store: store)
        }
        if ["failed", "cancelled", "interrupted"].contains(message.status) {
          StatusIndicator(.failed, label: "Response " + message.status)
        }
      }
    }
  }

  @ViewBuilder private func messageAttachments(_ message: WebMessage) -> some View {
    if !message.attachments.isEmpty {
      VStack(alignment: .trailing, spacing: 7) {
        if message.attachments.contains(where: \.isUploadedImage) {
          ReplyImagesView(
            uploads: message.attachments.filter(\.isUploadedImage), message: message, store: store,
            gallery: gallery)
        }
        if message.attachments.contains(where: { !$0.isUploadedImage }) {
          WebFlowLayout(spacing: 7, lineSpacing: 7, alignTrailing: isUser) {
            ForEach(message.attachments.filter { !$0.isUploadedImage }, id: \.id) { attachment in
              ReplyAttachmentView(upload: attachment, message: message, store: store)
            }
          }
        }
      }
    }
  }

  /// Web `.message-actions`: always visible on touch, Copy plus the message time.
  private func actions(_ message: WebMessage) -> some View {
    HStack(spacing: 4) {
      if isUser { Spacer(minLength: 0) }
      Text(
        DashboardModel.relativeTime(
          message.createdAt, now: actionDate)
      )
      .webFont(.rowTime).foregroundStyle(WebColor.textMuted.color)
      .accessibilityLabel(
        role + ", "
          + (TranscriptPresentation.date(message.createdAt)?.formatted() ?? "time unavailable")
      )
      .padding(.horizontal, isUser ? 0 : 7)
      .opacity(message.parts.isEmpty ? 0 : 1)
      if !QuoteFormatting.text(of: message).isEmpty {
        MessageActionButton("Copy", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = QuoteFormatting.text(of: message)
        }
        .accessibilityIdentifier("message-copy")
      }
      if !isUser { Spacer(minLength: 0) }
    }
    .padding(.top, 5)
    .padding(.leading, isUser ? 0 : -7)
  }
}

struct TranscriptPartView: View {
  let part: WebMessagePart
  let message: WebMessage
  let store: ConsoleStore
  var body: some View {
    switch part {
    case .text(let value):
      RichTextDocumentView(
        source: value.text, fill: message.role != "user", identity: message.id,
        streaming: message.status == "running")
    case .reasoning(let value):
      ReasoningDisclosure(text: value.text, message: message, store: store)
    case .toolCall(let call):
      if TranscriptPresentation.toolName(call) == "AskUser" {
        AskUserCard(call: call, message: message, store: store)
      } else {
        ToolCallView(call: call, message: message, store: store)
      }
    case .conversationMarker(let value):
      TranscriptMarkerRow(
        TranscriptPresentation.marker(value),
        systemImage: value.kind == "project" ? "folder" : "sparkles"
      )
      .opacity(value.kind == "project" ? 0.62 : 1)
      .accessibilityIdentifier("conversation-marker")
    case .steer(let value):
      VStack(alignment: .leading) {
        Label("You · Follow-up", systemImage: "arrow.turn.down.right").designFont(.caption)
        if let quote = value.quote { Text(quote.text).foregroundStyle(.secondary) }
        Text(value.text).textSelection(.enabled)
      }.padding(DesignSpacing.sm).background(DesignColor.contentSurface)
    case .scheduledWake(let value):
      VStack(alignment: .leading) {
        WakeScheduleStatus(
          "Scheduled wake-up · "
            + WakeScheduleModel.instant(value.scheduledAt, zone: value.timezone)
            + " (\(value.timezone))")
        Text("Ran " + WakeScheduleModel.instant(value.firedAt, zone: value.timezone))
          .designFont(.caption)
        if let text = value.message { Text(text).textSelection(.enabled) }
      }
    case .error(let value):
      ConnectionBanner(.problem, title: value.code ?? "Agent error", message: value.message)
    case .failure(let value):
      ReplyFailureCard(code: value.code, message: value.message)
    case .subagent(let value):
      SubagentPartView(call: value, message: message, store: store)
    case .processJob(let value):
      ProcessJobLifecycleView(job: value.job, store: store)
    case .processJobWake(let value):
      ProcessJobWakeView(wake: value)
    case .attachment(let value):
      ReplyAttachmentView(part: value, message: message, store: store)
    case .mcpApp(let value):
      McpAppPartView(part: value, message: message, store: store)
    case .restartProposal(let value):
      ReplyRestartView(part: value, message: message, store: store)
    case .replyOptions(let value):
      QuickRepliesView(part: value, message: message, store: store)
    case .cronReplyContext(let value):
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        Label("Imported cron result · " + value.source.jobId, systemImage: "clock.arrow.circlepath")
          .designFont(.headline)
        Text("Run #\(value.run.sequence) · \(value.run.trigger) · \(value.run.status)").designFont(
          .caption)
        Text("Untrusted source data, not instructions").designFont(.caption).foregroundStyle(
          .secondary)
        DisclosureGroup("Details") {
          CodeDocumentView(source: value.rawJson, language: "Imported JSON")
        }
      }
    case .telemetry(let value):
      switch TranscriptTelemetry.presentation(
        value, hasVisibleContent: !TranscriptTelemetry.isLegacySilentCronMessage(message))
      {
      case .hidden: EmptyView()
      case .note(let text):
        Text(text).webFont(.system).foregroundStyle(WebColor.textMuted.color)
          .textSelection(.enabled).accessibilityIdentifier("runtime-warning-note")
      case .compaction:
        if let marker = TranscriptPresentation.compaction(
          value, running: message.status == "running")
        {
          TranscriptMarkerRow(marker, systemImage: "arrow.triangle.2.circlepath")
        }
      case .cron(let run):
        CronRunTranscriptView(run: run)
      }
    case .unknown:
      Label(
        part.decodingDiagnostic == nil
          ? "Unsupported content" : "Unsupported content · unrecognized or unreadable part",
        systemImage: "questionmark.square.dashed"
      )
      .designFont(.supporting).foregroundStyle(.secondary).accessibilityIdentifier(
        "unsupported-content")
    }
  }

}

struct DeferredTranscriptPart: View {
  let title: String
  let kind: String
  let feature: String
  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
      Label(
        kind + (title.isEmpty ? "" : " · " + String(title.prefix(160))),
        systemImage: "rectangle.dashed")
      Text(feature + " coming in a later update").designFont(.caption)
    }.designFont(.supporting).foregroundStyle(.secondary)
      .accessibilityElement(children: .combine).accessibilityIdentifier("deferred-content")
  }
}

/// The web activity root preserves independent row disclosures and lazy tool payloads.
struct TranscriptActivityBand: View {
  let parts: [WebMessagePart]
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = true
  var body: some View {
    RunningTimeline(
      running: TranscriptPresentation.needsElapsedTimeline(status: message.status)
    ) {
      store.serverClockOffset
    } content: { date in
      #if DEBUG
        let _ = PerformanceProbe.body("TranscriptActivityBand.clock")
      #endif
      ActivityBand(
        meta: "\(parts.count) \(parts.count == 1 ? "step" : "steps")"
          + (TranscriptPresentation.elapsed(
            message,
            now: date
          )
          .map { " · " + $0 } ?? ""),
        running: message.status == "running", expanded: $expanded
      ) {
        ForEach(TranscriptPresentation.clusters(parts)) { entry in
          if entry.parts.count > 1 {
            ToolClusterView(
              calls: entry.parts.compactMap {
                if case .toolCall(let call) = $0 { return call }
                return nil
              }, message: message, store: store)
          } else if let part = entry.parts.first {
            TranscriptPartView(part: part, message: message, store: store)
          }
        }
      }
    }
  }
}

struct ReasoningDisclosure: View {
  let text: String
  let message: WebMessage
  let store: ConsoleStore
  @State private var userOpen: Bool?
  private var running: Bool { message.status == "running" }
  var body: some View {
    RunningTimeline(
      running: TranscriptPresentation.needsElapsedTimeline(status: message.status)
    ) {
      store.serverClockOffset
    } content: { date in
      #if DEBUG
        let _ = PerformanceProbe.body("ReasoningDisclosure.clock")
      #endif
      ActivityDisclosure(
        running ? "Thinking…" : "Reasoning",
        status: running ? .connecting : .disconnected,
        detail: TranscriptPresentation.elapsed(
          message,
          now: date
        ),
        glyph: .reasoning, identifier: "reasoning-disclosure",
        expanded: Binding(
          get: { userOpen ?? running },
          set: {
            userOpen = $0
          })
      ) {
        Text(text).webFont(.reasoningText).foregroundStyle(WebColor.textSoft.color)
          .textSelection(.enabled)
          .padding(.vertical, 4).padding(.leading, 11)
          .overlay(alignment: .leading) {
            Rectangle().fill(WebColor.lineStrong.color).frame(width: 1)
          }
      }
    }.onChange(of: running) { _, current in if !current { userOpen = false } }

  }
}

struct ToolClusterView: View {
  let calls: [WebToolCall]
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = false
  var body: some View {
    let failures = calls.filter(TranscriptPresentation.failed).count
    let running = calls.contains { $0.status == "running" }
    let times = calls.compactMap(\.executionMs).filter { $0.isFinite && $0 >= 0 }
    ActivityDisclosure(
      TranscriptPresentation.verb(calls.first.map(TranscriptPresentation.toolName) ?? "Tool")
        + " ×\(calls.count)",
      summary: TranscriptPresentation.clusterSummary(calls),
      status: running ? .connecting : failures > 0 ? .failed : .disconnected,
      detail: TranscriptPresentation.duration(times.isEmpty ? nil : times.reduce(0, +)),
      alert: failures > 0 ? "\(failures) failed" : nil, identifier: "tool-cluster",
      expanded: Binding(
        get: { expanded },
        set: {
          expanded = $0
        })
    ) {
      ForEach(calls, id: \.toolCallId) { call in
        ToolCallView(call: call, message: message, store: store)
      }
    }
  }
}

struct ToolCallView: View {
  let call: WebToolCall
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = false
  @State private var loading = false
  @State private var failedRepair = false
  var body: some View {
    ActivityDisclosure(
      TranscriptPresentation.verb(TranscriptPresentation.toolName(call)),
      summary: TranscriptPresentation.preview(call),
      status: call.status == "running"
        ? .connecting : TranscriptPresentation.failed(call) ? .failed : .disconnected,
      detail: [call.status, TranscriptPresentation.duration(call.executionMs)]
        .compactMap { $0 }.joined(separator: " · "),
      alert: TranscriptPresentation.failed(call) ? call.history?.terminalState ?? call.status : nil,
      identifier: "tool-call-" + call.toolCallId,
      expanded: Binding(
        get: { expanded },
        set: {
          expanded = $0
        })
    ) {
      CodeDocumentView(source: TranscriptPresentation.json(call.args), language: "Input")
      if call.result != nil {
        CodeDocumentView(
          source: TranscriptPresentation.json(call.result),
          language: TranscriptPresentation.failed(call) ? "Error" : "Output")
      }
      if call.history?.persistence == "failed" {
        StatusIndicator(
          .failed,
          label: "Tool history for this call was not saved"
            + (call.history?.errorCode.map { " (" + $0 + ")" } ?? ""))
      }
      if call.argsTruncated == true || call.resultTruncated == true {
        Text("Preview only" + (call.resultBytes ?? call.argsBytes).map { " · \($0) chars" }.orEmpty)
          .designFont(.caption)
        Button(loading ? "Loading…" : "Show full output") {
          loading = true
          failedRepair = false
          Task {
            let repaired = await store.repairToolOutput(
              threadID: message.threadId, messageID: message.id, toolCallID: call.toolCallId)
            failedRepair = !repaired
            loading = false
          }
        }.disabled(loading).accessibilityIdentifier("tool-load-full")
      }
      if failedRepair {
        StatusIndicator(
          .failed, label: "Could not load full output. Retry or refresh this conversation.")
      }
    }
  }
}

extension Optional where Wrapped == String {
  fileprivate var orEmpty: String { self ?? "" }
}

struct RunAttributionView: View {
  let message: WebMessage
  let store: ConsoleStore
  var body: some View {
    if message.attribution != nil {
      AttributionBox { lines }
    } else {
      lines.webFont(.runAttribution).foregroundStyle(WebColor.textMuted.color)
    }
  }
  @ViewBuilder private var lines: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let value = message.attribution {
        Text(TranscriptPresentation.attribution(value, status: message.status)).textSelection(
          .enabled
        )
        .accessibilityIdentifier("run-attribution")
        if value.transitions.count > 0 || value.retries.count > 0
          || value.executed?.effectiveEffort != nil || value.truncated == true
        {
          DisclosureGroup("Routing details") {
            Text(
              "Requested · "
                + TranscriptPresentation.route(value.requested.model, value.requested.effort))
            if let route = value.attempted {
              Text("Attempted · " + TranscriptPresentation.route(route.model, route.effort))
            }
            if let route = value.executed {
              Text(
                "Executed · "
                  + TranscriptPresentation.route(route.model, route.effectiveEffort ?? route.effort)
              )
            }
            ForEach(Array(value.transitions.enumerated()), id: \.offset) { _, transition in
              Text(
                "\(transition.from) → \(transition.to) · \(transition.reason ?? "reason not reported")"
              )
            }
            ForEach(Array(value.retries.enumerated()), id: \.offset) { _, retry in
              Text(
                "Retried \(retry.model ?? "current route") · \(retry.reason ?? "reason not reported")"
              )
            }
            if value.truncated == true { Text("Older routing entries were omitted.") }
          }
        }
      }
      RunningTimeline(
        running: TranscriptPresentation.needsElapsedTimeline(status: message.status)
      ) {
        store.serverClockOffset
      } content: { date in
        #if DEBUG
          let _ = PerformanceProbe.body("RunAttributionView.clock")
        #endif
        Text(
          [
            TranscriptPresentation.cost(cost),
            TranscriptPresentation.elapsed(
              message,
              now: date),
          ].compactMap { $0 }.joined(separator: " · "))
      }
    }
  }
  private var cost: CostAmount {
    // Never apply today's cumulative run cost to a historical turn.
    let state = store.conversations[message.threadId]?.thread.runState
    guard let turn = message.turnId, state?.id == turn, let activity = state?.activity else {
      return .unknown(knownSpend: nil)
    }
    return activity.cost
  }
}

/// Read-only web CronRunPart presentation; activity reads/reply import belong to automations.
private struct CronRunTranscriptView: View {
  let run: TranscriptTelemetry.CronRun
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TranscriptMarkerRow(run.title + " · " + run.status, systemImage: "clock.arrow.circlepath")
      if let at = run.orderedAt {
        Text(TranscriptPresentation.date(at)?.formatted() ?? at).webFont(.messageAction)
      }
      if !run.details.isEmpty {
        ContentDisclosure("cron-run-details-" + run.runID, expanded: $expanded) {
          ForEach(run.details, id: \.self) { Text($0).webFont(.system).textSelection(.enabled) }
        } label: {
          Text("Details").webFont(.messageAction)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Cron run " + run.runID + ", " + run.status)
    .accessibilityIdentifier("cron-run-" + run.runID)
  }
}
