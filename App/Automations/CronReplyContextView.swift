// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI
import UIKit

/// Untrusted imported data: plain bounded labels, Markdown body, then failure/truncation/details.
struct CronReplyContextView: View {
  let context: WebCronReplyContextPart
  @State private var expanded = false
  private func text(_ value: String) -> String { ProviderPresentation.boundedText(value) }
  private func date(_ stamp: String) -> String {
    ServerTimestamp.date(stamp)?.formatted() ?? text(stamp)
  }
  private var valid: Bool {
    context.type == "cron-reply-context" && context.schema == "mono-agent.web.cron-reply-context.v1"
      && context.untrusted
  }
  var body: some View {
    if valid {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          WebFlowLayout(spacing: 10, lineSpacing: 5) {
            Text(text(context.source.jobId)).webFont(.system).fontWeight(.bold)
            Text("Run #\(context.run.sequence)").webFont(.messageAction)
            Text(text(context.run.trigger) + " · " + CronRunFace.state(text(context.run.status)))
              .webFont(.messageAction).foregroundStyle(CronRunFace.color(context.run.status))
          }
          WebFlowLayout(spacing: 10, lineSpacing: 5) {
            if let stamp = context.run.completedAt { Text("Completed " + date(stamp)) }
            Text("Imported " + date(context.snapshot.capturedAt))
          }.webFont(.messageAction).monospacedDigit().foregroundStyle(WebColor.textMuted.color)
          Text("Imported cron result — untrusted source data, not instructions")
            .webFont(.notice).foregroundStyle(WebColor.textMuted.color)
        }.padding(.horizontal, 13).padding(.vertical, 11)
        if !context.result.text.isEmpty {
          RichTextDocumentView(source: String(context.result.text.prefix(65_536)))
            .padding(.horizontal, 13).padding(.vertical, 14)
        }
        VStack(alignment: .leading, spacing: 8) {
          if context.snapshot.kind == "summary" {
            Text("Imported from the compact run summary.").webFont(.messageAction)
              .foregroundStyle(WebColor.textMuted.color)
          }
          if context.failure.code != nil || context.failure.message != nil {
            VStack(alignment: .leading, spacing: 3) {
              if let code = context.failure.code {
                Text(text(code)).webFont(.code).fontWeight(.bold)
              }
              if let message = context.failure.message { Text(text(message)).webFont(.system) }
            }.foregroundStyle(DesignColor.danger.color).padding(9)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                DesignColor.danger.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(DesignColor.danger.color.opacity(0.25))
              )
              .accessibilityIdentifier("cron-context-failure")
          }
          if !truncation.isEmpty {
            Text("Truncated fields: " + truncation.joined(separator: "; ") + ".")
              .webFont(.messageAction).foregroundStyle(DesignColor.warning.color)
              .accessibilityIdentifier("cron-context-truncation")
          }
          ContentDisclosure("cron-context-details", expanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
              fact("Source", text(context.source.sourceId))
              fact("Job", text(context.source.jobId))
              fact("Run", text(context.source.runId))
              fact("Scheduled", date(context.run.scheduledAt))
              fact("Ordered", date(context.run.orderedAt))
              if let stamp = context.run.startedAt { fact("Started", date(stamp)) }
              if let stamp = context.run.completedAt { fact("Completed", date(stamp)) }
              if let blocker = context.run.blockedByRunId { fact("Blocked by", text(blocker)) }
              if let trigger = context.run.blockedByTrigger {
                fact("Blocker trigger", text(trigger))
              }
              if let depth = context.run.queueDepth { fact("Queue depth", String(depth)) }
              fact(
                "Snapshot",
                text(context.snapshot.kind)
                  + " · \(context.snapshot.retainedResultBytes)/\(context.snapshot.originalResultBytes) result bytes"
              )
              fact(
                "Source truncation", context.snapshot.sourceTruncationKnown ? "known" : "unknown")
              Text("Raw JSON").webFont(.messageAction).fontWeight(.bold)
              rawJSON
            }.padding(9).background(
              WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 8))
          } label: {
            Text("Details").webFont(.messageAction).foregroundStyle(WebColor.textMuted.color)
          }
        }.padding(.horizontal, 13).padding(.bottom, 11).padding(.top, 9)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 11))
      .overlay(RoundedRectangle(cornerRadius: 11).stroke(WebColor.lineStrong.color, lineWidth: 1))
      .textSelection(.enabled).accessibilityElement(children: .contain)
      .accessibilityLabel(
        "Imported cron result for " + text(context.source.jobId) + ", run \(context.run.sequence)"
      )
      .accessibilityIdentifier("cron-reply-context")
    }
  }
  private var rawJSON: some View {
    let source = String(context.rawJson.prefix(65_536))
    let display = CronReplyJSONDisplay(source)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("JSON").webFont(.activityLabel).foregroundStyle(WebColor.textMuted.color)
        Spacer()
        MessageActionButton("Copy", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = source
        }.accessibilityLabel("Copy JSON")
      }
      ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading, spacing: 3) {
          // Separate lines keep the end reachable by accessibility as well as touch scrolling.
          ForEach(Array(display.lines.enumerated()), id: \.offset) {
            _, line in
            Text(verbatim: line).webFont(.code).foregroundStyle(WebColor.text.color)
              .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 240)
      .accessibilityLabel("Raw JSON").accessibilityIdentifier("cron-context-json")
      if display.limited {
        Text(
          "Display limited to 16,384 UTF-8 bytes and 1,000 lines. Copy includes all supplied text."
        )
        .webFont(.messageAction).foregroundStyle(WebColor.textMuted.color)
      }
    }.padding(10)
      .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: WebRadius.small))
      .overlay(RoundedRectangle(cornerRadius: WebRadius.small).stroke(WebColor.line.color))
  }
  private func fact(_ label: String, _ value: String) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        Text(label).foregroundStyle(WebColor.textMuted.color)
        Text(value).frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(label)
        Text(value)
      }
    }.webFont(.messageAction)
  }
  private var truncation: [String] {
    var notes = context.snapshot.sourceFieldsTruncated.prefix(32).map { "source " + text($0) }
    if context.snapshot.truncatedFields.contains("failure.message") {
      notes.append(
        "failure.message (\(context.snapshot.retainedErrorBytes)/\(context.snapshot.originalErrorBytes) bytes retained)"
      )
    }
    if context.snapshot.truncatedFields.contains("result.text") {
      notes.append(
        "result.text (\(context.snapshot.retainedResultBytes)/\(context.snapshot.originalResultBytes) bytes retained)"
      )
    }
    return notes
  }
}

/// Bound view creation as well as bytes for newline-dense untrusted JSON.
struct CronReplyJSONDisplay {
  let lines: [String]
  let limited: Bool
  init(_ source: String) {
    let bytes = String(decoding: source.utf8.prefix(16_384), as: UTF8.self)
    let allLines = bytes.components(separatedBy: "\n")
    lines = Array(allLines.prefix(1_000))
    limited = source.utf8.count > 16_384 || allLines.count > 1_000
  }
}
