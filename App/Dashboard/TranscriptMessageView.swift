// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct TranscriptMessageView: View {
  let row: TranscriptMessageState
  let store: ConsoleStore
  let startsTurn: Bool
  private var isUser: Bool { row.message.role == "user" }
  private var role: String {
    isUser ? "You" : row.message.role == "assistant" ? "Assistant" : "System"
  }
  /// Web message layout: the user's turn is a neutral bubble on the trailing edge with its
  /// actions below; assistant prose sits directly on the panel (no bubble, card or avatar).
  var body: some View {
    let message = row.message
    VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
      if isUser {
        UserBubble { messageContent(message) }
      } else {
        messageContent(message).frame(maxWidth: .infinity, alignment: .leading)
      }
      // Web: the action row belongs to a settled message, not one still being written.
      if message.status != "running" { actions(message) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    // The whole row (not only its glyphs) opens the message menu, as hovering it does on the web.
    .contentShape(Rectangle())
    .quotable(message)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-" + message.id)
  }

  @ViewBuilder private func messageContent(_ message: WebMessage) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let quote = message.quote {
        Text(quote.text)
          .font(.system(size: 11)).lineSpacing(3).lineLimit(4)
          .foregroundStyle(WebColor.textSoft.color)
          .padding(.vertical, 8).padding(.horizontal, 10)
          .background(WebColor.surface.color.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
          .overlay(alignment: .leading) {
            Rectangle().fill(WebColor.lineStrong.color).frame(width: 2)
          }
          .textSelection(.enabled)
          .accessibilityLabel("Quote: " + quote.text)
      }
      ForEach(TranscriptPresentation.activityBands(message.parts)) { band in
        if band.parts.allSatisfy(TranscriptPresentation.isActivity) {
          TranscriptActivityBand(parts: band.parts, message: message, store: store)
        } else if let part = band.parts.first {
          TranscriptPartView(part: part, message: message, store: store)
        }
      }
      ForEach(message.attachments, id: \.id) { attachment in
        DeferredTranscriptPart(
          title: attachment.name, kind: attachment.kind == "image" ? "Image" : "Attachment",
          feature: "File viewer")
      }
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

  /// Web `.message-actions`: always visible on touch, Copy plus the message time.
  private func actions(_ message: WebMessage) -> some View {
    HStack(spacing: 4) {
      if isUser { Spacer(minLength: 0) }
      TimelineView(.periodic(from: .now, by: 60)) { context in
        Text(
          DashboardModel.relativeTime(
            message.createdAt, now: context.date.addingTimeInterval(store.serverClockOffset))
        )
        .webFont(.rowTime).foregroundStyle(WebColor.textMuted.color)
        // The role is spoken with the time, as the old visible "You"/"Assistant" header was.
        .accessibilityLabel(
          role + ", "
            + (TranscriptPresentation.date(message.createdAt)?.formatted() ?? "time unavailable"))
      }
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
    case .text(let value): RichTextDocumentView(source: value.text, fill: message.role != "user")
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
        Label("Scheduled wake-up", systemImage: "alarm").designFont(.headline)
        Text(TranscriptPresentation.date(value.scheduledAt)?.formatted() ?? value.scheduledAt)
          .designFont(.caption)
        if let text = value.message { Text(text).textSelection(.enabled) }
      }
    case .error(let value):
      ConnectionBanner(.problem, title: value.code ?? "Agent error", message: value.message)
    case .failure(let value):
      ConnectionBanner(.problem, title: value.code, message: value.message)
    case .subagent(let value):
      SubagentPartView(call: value, message: message, store: store)
    case .processJob(let value):
      ProcessJobLifecycleView(job: value.job, store: store)
    case .processJobWake(let value):
      ProcessJobWakeView(wake: value)
    case .attachment(let value):
      DeferredTranscriptPart(
        title: value.name, kind: value.mediaType.hasPrefix("image/") ? "Image" : "Reply file",
        feature: "File viewer")
    case .mcpApp(let value):
      DeferredTranscriptPart(
        title: value.title ?? value.toolName, kind: "MCP app", feature: "App viewer")
    case .restartProposal(let value):
      DeferredTranscriptPart(
        title: value.reason ?? "Restart agent", kind: "Restart proposal", feature: "Restart card")
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
      if let marker = TranscriptPresentation.compaction(value, running: message.status == "running")
      {
        TranscriptMarkerRow(marker, systemImage: "arrow.triangle.2.circlepath")
      } else if value.event == "context_usage"
        || UsagePresentation.layers(value.data).contains(where: {
          $0["kind"] == .string("context_usage")
        })
      {
        Label("Context measurement recorded", systemImage: "chart.pie").designFont(.caption)
          .foregroundStyle(.secondary)
      } else {
        DeferredTranscriptPart(
          title: value.kind ?? value.event, kind: "Telemetry", feature: "Context viewer")
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
    TimelineView(.periodic(from: .now, by: 1)) { context in
      ActivityBand(
        meta: "\(parts.count) \(parts.count == 1 ? "step" : "steps")"
          + (TranscriptPresentation.elapsed(
            message, now: context.date.addingTimeInterval(store.serverClockOffset)
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
    TimelineView(.periodic(from: .now, by: 1)) { context in
      ActivityDisclosure(
        running ? "Thinking…" : "Reasoning",
        status: running ? .connecting : .disconnected,
        detail: TranscriptPresentation.elapsed(
          message, now: context.date.addingTimeInterval(store.serverClockOffset)),
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
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(
          [
            TranscriptPresentation.cost(cost),
            TranscriptPresentation.elapsed(
              message, now: context.date.addingTimeInterval(store.serverClockOffset)),
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
