// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct TranscriptMessageView: View {
  let row: TranscriptMessageState
  let store: ConsoleStore
  @State private var gallery = ReplyMessageGallery()
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
      let visible = message.parts.filter {
        TranscriptTelemetry.visible($0, in: message) && TranscriptPresentation.isShown($0)
      }
      let bands = TranscriptPresentation.activityBands(visible)
      // Web: only the band holding the turn's last activity part carries the turn's clock.
      let openBand = bands.last { $0.parts.allSatisfy(TranscriptPresentation.isActivity) }?.id
      VStack(alignment: .leading, spacing: 10) {
        if let quote = message.quote {
          MessageQuote(quote.text)

        }
        ForEach(bands) { band in
          if band.parts.allSatisfy(TranscriptPresentation.isActivity) {
            TranscriptActivityBand(
              parts: band.parts, message: message, store: store, timed: band.id == openBand)
          } else if band.parts.allSatisfy(TranscriptPresentation.isReplyImage) {
            ReplyImagesView(
              parts: band.parts.compactMap {
                if case .attachment(let value) = $0 { return value }
                return nil
              }, message: message, store: store, gallery: gallery)
          } else if let part = band.parts.first {
            if message.role == "system", case .text(let value) = part {
              Text(value.text).webFont(.system).foregroundStyle(WebColor.textMuted.color)
                .textSelection(.enabled)
            } else {
              TranscriptPartView(part: part, message: message, store: store)
            }
          }
        }
        if !isUser { messageAttachments(message) }
        // Web `RunningText` (`indicator="no-text"`): the dots stand in while the turn runs
        // without new prose, including after an Activity band.
        if message.role == "assistant" && message.status == "running"
          && !TranscriptPresentation.endsWithProse(visible)
        {
          ThinkingDots()
        }
        if let status = message.liveInputStatus {
          Text("Follow-up · " + status).webFont(.messageAction)
            .foregroundStyle(WebColor.textMuted.color)
        }
        if message.role == "assistant",
          TranscriptPresentation.showsRunAttribution(message.attribution, status: message.status)
        {
          RunAttributionView(message: message)
        }
        if message.status == "failed" {
          MessageErrorCard(code: "", message: "The response ended with an error.")
            .accessibilityIdentifier("message-error")
        } else if ["cancelled", "interrupted"].contains(message.status) {
          Text("Response " + message.status).webFont(.messageAction)
            .foregroundStyle(WebColor.textMuted.color)
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

  /// Web `.message-actions`: always visible on touch and Copy only. The web shows no message
  /// time; VoiceOver still hears who wrote it and when. Copy is disabled without copyable text.
  private func actions(_ message: WebMessage) -> some View {
    let text = QuoteFormatting.text(of: message)
    return HStack(spacing: 4) {
      if isUser { Spacer(minLength: 0) }
      MessageActionButton("Copy", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = text
      }
      .disabled(text.isEmpty)
      .opacity(text.isEmpty ? 0.45 : 1)
      .accessibilityLabel(isUser ? "Copy message" : "Copy response")
      .accessibilityValue(
        role + ", "
          + (TranscriptPresentation.date(message.createdAt)?.formatted() ?? "time unavailable")
      )
      .accessibilityIdentifier("message-copy")
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
      MessageErrorCard(code: value.code ?? "Agent error", message: value.message)
        .accessibilityIdentifier("message-error-part")
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

/// Web `ActivityGroup`: open while the turn streams and collapsed once it settles
/// (`collapseOnSettle`); a user toggle wins until the next settle. Only the band holding the
/// turn's last activity part carries the turn's clock.
struct TranscriptActivityBand: View {
  let parts: [WebMessagePart]
  let message: WebMessage
  let store: ConsoleStore
  var timed = true
  @State private var userOpen: Bool?
  private var running: Bool { message.status == "running" }
  var body: some View {
    let steps = TranscriptPresentation.activityStepCount(parts)
    let count = "\(steps) \(steps == 1 ? "step" : "steps")"
    let expanded = Binding(get: { userOpen ?? running }, set: { userOpen = $0 })
    Group {
      if timed {
        RunningTimeline(
          running: TranscriptPresentation.needsElapsedTimeline(status: message.status)
        ) {
          store.serverClockOffset
        } content: { date in
          #if DEBUG
            let _ = PerformanceProbe.body("TranscriptActivityBand.clock")
          #endif
          band(
            meta: count
              + (TranscriptPresentation.elapsed(message, now: date).map { " · " + $0 } ?? ""),
            expanded: expanded)
        }
      } else {
        band(meta: count, expanded: expanded)
      }
    }
    .onChange(of: running) { _, now in if !now { userOpen = nil } }
  }
  private func band(meta: String, expanded: Binding<Bool>) -> some View {
    ActivityBand(meta: meta, running: running, expanded: expanded) {
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

/// Web `variant="thinking"`: a muted bulb, no label, the thought's first 52 characters as the
/// summary; it opens while the thought streams and collapses when it settles.
struct ReasoningDisclosure: View {
  let text: String
  let message: WebMessage
  let store: ConsoleStore
  @State private var userOpen: Bool?
  private var running: Bool { message.status == "running" }
  var body: some View {
    ActivityDisclosure(
      "", summary: TranscriptPresentation.thinkingPreview(text),
      status: running ? .connecting : .disconnected, glyph: .reasoning,
      identifier: "reasoning-disclosure",
      expanded: Binding(get: { userOpen ?? running }, set: { userOpen = $0 })
    ) {
      ActivityThought(text)
    }
    .onChange(of: running) { _, current in if !current { userOpen = nil } }
  }
}

/// Web `ToolClusterPart`: a run of identical calls as one row (`Read ×4`, deduplicated leaves,
/// summed time, a failure count); members stay individually expandable as flat steps.
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
      alert: TranscriptPresentation.failedLabel(failures, clustered: true),
      identifier: "tool-cluster", expanded: $expanded
    ) {
      ActivitySteps {
        ForEach(calls, id: \.toolCallId) { call in
          ActivityStep(
            TranscriptPresentation.toolName(call), summary: TranscriptPresentation.preview(call),
            failed: TranscriptPresentation.failedLabel(
              TranscriptPresentation.failed(call) ? 1 : 0, clustered: false),
            duration: TranscriptPresentation.duration(call.executionMs),
            identifier: "tool-call-" + call.toolCallId
          ) {
            ToolPayloadView(call: call, message: message, store: store, indented: false)
          }
        }
      }
    }
  }
}

/// Web `ToolFallback`: one call as an activity row; the time is its only trailing fact (no
/// state word), a failure adds the tag.
struct ToolCallView: View {
  let call: WebToolCall
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = false
  var body: some View {
    let failed = TranscriptPresentation.failed(call)
    ActivityDisclosure(
      TranscriptPresentation.verb(TranscriptPresentation.toolName(call)),
      summary: TranscriptPresentation.preview(call),
      status: call.status == "running" ? .connecting : failed ? .failed : .disconnected,
      detail: TranscriptPresentation.duration(call.executionMs),
      alert: failed ? call.history?.terminalState ?? "failed" : nil,
      identifier: "tool-call-" + call.toolCallId,
      expanded: $expanded
    ) {
      ToolPayloadView(call: call, message: message, store: store, indented: true)
    }
  }
}

/// Web `ActivityPayload`: Input, a preview notice owning the one repair control, Output or
/// Error, and a tinted history failure.
struct ToolPayloadView: View {
  let call: WebToolCall
  let message: WebMessage
  let store: ConsoleStore
  let indented: Bool
  @State private var phase = ActivityTruncationNotice.Phase.idle
  var body: some View {
    let argsTruncated = call.argsTruncated == true
    let resultTruncated = call.resultTruncated == true
    let load: () -> Void = { repair() }
    let resultLoad: (() -> Void)? = argsTruncated ? nil : load
    let resultPhase: ActivityTruncationNotice.Phase = argsTruncated ? .idle : phase
    let failed = TranscriptPresentation.failed(call)
    let historyNote: String? =
      call.history?.persistence == "failed"
      ? "Tool history for this call was not saved"
        + (call.history?.errorCode.map { " (" + $0 + ")" } ?? "") + "." : nil
    ActivityPayload(indented: indented) {
      ActivityPayloadBlock("Input", text: TranscriptPresentation.json(call.args))
      if argsTruncated {
        ActivityTruncationNotice(characters: call.argsBytes, phase: phase, action: load)
      }
      if call.result != nil {
        ActivityPayloadBlock(
          failed ? "Error" : "Output", text: TranscriptPresentation.json(call.result))
      }
      // One repair fetches the whole part, so only the first notice offers it.
      if resultTruncated {
        ActivityTruncationNotice(
          characters: call.resultBytes, phase: resultPhase, action: resultLoad)
      }
      if let historyNote { ActivityErrorNote(historyNote) }
    }
  }
  private func repair() {
    phase = .loading
    Task {
      let repaired = await store.repairToolOutput(
        threadID: message.threadId, messageID: message.id, toolCallID: call.toolCallId)
      phase = repaired ? .idle : .failed
    }
  }
}

/// Web `RunAttribution`, shown only for a run that deviated (see
/// `TranscriptPresentation.showsRunAttribution`): fit-content, a FALLBACK pill and warning tint
/// for a fallback, an effort-change note, and quiet routing details. No cost or clock: the
/// Activity header already carries the turn's elapsed time.
struct RunAttributionView: View {
  let message: WebMessage
  @State private var details = false
  var body: some View {
    if let value = message.attribution {
      let fallback = value.disposition == "fallback"
      AttributionBox(fallback: fallback) {
        // Fit-content like the web: one line when it fits, wrapping only when it must.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) { summary(value, fallback: fallback) }
          WebFlowLayout(spacing: 8, lineSpacing: 5) { summary(value, fallback: fallback) }
        }
        if !value.transitions.isEmpty || !value.retries.isEmpty || value.truncated == true
          || (value.executed ?? value.attempted)?.effectiveEffort != nil
        {
          Button {
            details.toggle()
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                .rotationEffect(.degrees(details ? 90 : 0))
              Text("Routing details")
            }
            .font(.system(size: 10))
            .foregroundStyle(WebColor.textMuted.color)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityValue(details ? "Expanded" : "Collapsed")
          .accessibilityIdentifier("routing-details")
          if details { routingDetails(value) }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(fallback ? "Model fallback" : "Run route")
    }
  }
  @ViewBuilder private func summary(_ value: WebRunAttribution, fallback: Bool) -> some View {
    if fallback { AttributionWarning("Fallback") }
    Text(TranscriptPresentation.attribution(value, status: message.status))
      .textSelection(.enabled)
      .accessibilityIdentifier("run-attribution")
    if let change = TranscriptPresentation.effortChange(value) {
      Text(change).foregroundStyle(WebColor.warning.color)
    }
  }
  @ViewBuilder private func routingDetails(_ value: WebRunAttribution) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      row("Requested", TranscriptPresentation.route(value.requested.model, value.requested.effort))
      if let route = value.attempted {
        row("Attempted", TranscriptPresentation.route(route.model, route.effort))
      }
      if let route = value.executed {
        row("Executed", TranscriptPresentation.route(route.model, route.effort))
      }
      if let effective = (value.executed ?? value.attempted)?.effectiveEffort {
        row("Effective effort", effective)
      }
      ForEach(Array(value.transitions.enumerated()), id: \.offset) { _, transition in
        Text(
          "\(transition.from) → \(transition.to) · \(transition.reason ?? "reason not reported")")
      }
      ForEach(Array(value.retries.enumerated()), id: \.offset) { _, retry in
        Text(
          "Retried \(retry.model ?? "current route")"
            + (retry.retryIndex.map { " · attempt \($0 + 1)" } ?? "")
            + (retry.reason.map { " · " + $0 } ?? ""))
      }
      if value.truncated == true {
        Text("Older routing entries were omitted.").foregroundStyle(WebColor.warning.color)
      }
    }
    .padding(.vertical, 7)
    .textSelection(.enabled)
  }
  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).foregroundStyle(WebColor.textMuted.color).frame(width: 92, alignment: .leading)
      Text(value).font(.system(size: 9.5, design: .monospaced))
    }
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
