// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Web `.peer-question`: untrusted peer prose on a surface card (P10/12, R10, 1 px line, 12.5/1.5),
/// a state line (amber while answerable), reference-only fields and the raw form.
struct JobPeerQuestionView: View {
  let question: PeerProcessJobQuestion
  let now: Date
  /// The composer dock supplies this: it opens the peer-question sheet, which drafts a reply
  /// in the composer. No answer route is invoked here.
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  @State private var schemaOpen = false
  private var pending: Bool {
    question.state == "awaiting_answer"
      && (JobPresentation.date(question.expiresAt).map { $0 > now } ?? false)
  }
  var body: some View {
    let state =
      pending
      ? "Waiting for the agent\u{2019}s answer"
      : question.state == "awaiting_answer"
        ? "Past expiry; awaiting host confirmation"
        : question.state.replacingOccurrences(of: "_", with: " ").capitalized
    let fields = PeerQuestionForm.describe(question.requestedSchema)
    VStack(alignment: .leading, spacing: 7) {
      WebFlowLayout(spacing: 10, lineSpacing: 2) {
        Text(state).fontWeight(.semibold)
          .foregroundStyle(pending ? WebJobTone.question.text : WebColor.textSoft.color)
        Text(question.peer + " / " + question.thread)
        if let date = JobPresentation.date(question.expiresAt), question.state == "awaiting_answer"
        {
          Text(pending ? "expires " + date.formatted(.relative(presentation: .named)) : "expired")
        }
      }
      .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("peer-question")
      Text(JobPresentation.preview(question.message, limit: 16_384).text)
        .foregroundStyle(WebColor.text.color)
        .textSelection(.enabled)
      ForEach(fields, id: \.key) { field in
        VStack(alignment: .leading, spacing: 2) {
          let label = Text(field.label).fontWeight(.semibold)
            .foregroundStyle(WebColor.textSoft.color)
          let required = Text(field.required ? " · required" : "")
            .foregroundStyle(WebGlass.textMuted.color)
          Text("\(label)\(required)")
          if let detail = field.description {
            Text(detail).font(.system(size: 12)).foregroundStyle(WebGlass.textMuted.color)
          }
          if field.options.isEmpty {
            Text(field.freeText ? "free text" : "value").foregroundStyle(WebGlass.textMuted.color)
          } else {
            ReferenceOptions(options: field.options)
          }
        }
      }
      Text("Untrusted peer text; not owner approval. The agent answers through PeerAgent.")
        .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
      Button(onAnswerPeerQuestion == nil ? "Answer · unavailable here" : "Answer") {
        onAnswerPeerQuestion?(question)
      }
      .disabled(!pending || onAnswerPeerQuestion == nil)
      .buttonStyle(WebSmallButtonStyle(.accent))
      .accessibilityIdentifier("peer-question-answer")
      Button {
        schemaOpen.toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
            .rotationEffect(.degrees(schemaOpen ? 90 : 0))
          Text("Raw form")
        }
        .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
        .frame(minHeight: 28).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(schemaOpen ? "Expanded" : "Collapsed")
      if schemaOpen {
        Text("questionId " + question.questionId).webFont(.jobMono)
          .foregroundStyle(WebGlass.textMuted.color)
        JobOutputBox(TranscriptPresentation.json(.object(question.requestedSchema)), maxHeight: 140)
      }
    }
    .webFont(.jobDetail)
    .padding(.vertical, 10).padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WebGlass.groupFill.color,
      in: RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
        .strokeBorder(WebGlass.hairline.color, lineWidth: 1))
  }
}

/// "Options, for reference: a · b": muted label, soft choices, never pressable.
private struct ReferenceOptions: View {
  let options: [String]
  var body: some View {
    let label = Text("Options, for reference: ").foregroundStyle(WebGlass.textMuted.color)
    let values = Text(options.joined(separator: "  ·  ")).foregroundStyle(WebColor.textSoft.color)
    Text("\(label)\(values)").font(.system(size: 12))
  }
}

/// `ProcessJobSubagentQuestion`: the question a detached child ended its turn with, a past fact.
struct JobSubagentQuestionView: View {
  let question: ProcessJobProjection.Question
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      WebFlowLayout(spacing: 10) {
        Text("Asked the parent agent").fontWeight(.semibold).foregroundStyle(
          WebColor.textSoft.color)
        Text("when it finished")
      }
      .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
      Text(question.question).foregroundStyle(WebColor.text.color).textSelection(.enabled)
      if let options = question.options, !options.isEmpty {
        ReferenceOptions(options: options)
      }
      Text("Untrusted child text; the parent agent answers it.")
        .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
    }
    .webFont(.jobDetail)
    .padding(.vertical, 10).padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WebGlass.groupFill.color,
      in: RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
        .strokeBorder(WebGlass.hairline.color, lineWidth: 1))
  }
}

/// `ProcessJobSubagentProgress`: the child's recent calls as dense activity steps (mono tool
/// column ≥ 68, muted summary, a FAILED pill, mono time), then its report as prose.
struct JobSubagentProgressView: View {
  let progress: ProcessJobSubagentProgress
  @State private var open: Set<Int> = []
  @State private var reportExpanded = true
  private var groups: [[ProcessJobSubagentProgress.Recent]] {
    progress.recent.reduce(into: []) { groups, call in
      if groups.last?.first?.toolName == call.toolName, call.toolName != "AskUser" {
        groups[groups.count - 1].append(call)
      } else {
        groups.append([call])
      }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if progress.recent.isEmpty {
        Text("No tool calls yet.").webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
          .frame(minHeight: 28)
      }
      if progress.toolCalls > progress.recent.count {
        Text("Showing the latest \(progress.recent.count) of \(progress.toolCalls) calls.")
          .font(.system(size: 11)).foregroundStyle(WebGlass.textMuted.color)
          .padding(.top, 2).padding(.bottom, 4)
      }
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        step(index, group)
      }
      if let answer = progress.answerHead {
        Button {
          reportExpanded.toggle()
        } label: {
          stepHead(
            tool: "Report" + (progress.answerTruncated == true ? " (truncated)" : ""),
            summary: "", failed: 0, time: nil, running: false, expanded: reportExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(reportExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("subagent-latest-answer")
        if reportExpanded {
          JobOutputBox(JobPresentation.preview(answer, limit: 16_384).text, prose: true)
            .padding(.bottom, 8)
          if progress.answerTruncated == true {
            Text("Only the answer head is available through this API.")
              .webFont(.jobMeta).foregroundStyle(WebGlass.textMuted.color)
          }
        }
      }
    }
  }
  @ViewBuilder private func step(_ index: Int, _ group: [ProcessJobSubagentProgress.Recent])
    -> some View
  {
    let first = group[0]
    let current = group.last(where: { $0.status == "running" }) ?? group[group.count - 1]
    let failed = group.filter { $0.status == "failed" }.count
    let running = current.status == "running"
    let total = group.compactMap(\.executionMs).reduce(0, +)
    Button {
      if open.contains(index) { open.remove(index) } else { open.insert(index) }
    } label: {
      stepHead(
        tool: first.toolName + (group.count > 1 ? " ×\(group.count)" : ""),
        summary: current.argsSummary.map { JobPresentation.preview($0, limit: 72).text } ?? "",
        failed: failed,
        time: running ? "running" : total > 0 ? JobPresentation.duration(total) : nil,
        running: running, expanded: open.contains(index))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityValue(open.contains(index) ? "Expanded" : "Collapsed")
    if open.contains(index) {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(group, id: \.id) { call in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
              Text(
                call.argsSummary.map { JobPresentation.preview($0, limit: 2048).text }
                  ?? call.toolName)
              if let workdir = call.workdir { Text("Directory: " + workdir).opacity(0.78) }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            Text(
              call.status
                + (call.executionMs.map { " · " + JobPresentation.duration($0) } ?? "")
            )
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(
              call.status == "failed"
                ? WebColor.danger.color
                : call.status == "running"
                  ? WebColor.jobProgressText.color : WebGlass.textMuted.color)
          }
          .foregroundStyle(WebGlass.textMuted.color)
        }
      }
      .padding(.leading, 8).padding(.trailing, 8).padding(.bottom, 8)
    }
  }
  private func stepHead(
    tool: String, summary: String, failed: Int, time: String?, running: Bool, expanded: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(tool).webFont(.stepTool)
        .foregroundStyle(running ? WebColor.text.color : WebColor.textSoft.color)
        .lineLimit(1)
        .frame(minWidth: 68, alignment: .leading)
      Text(summary).webFont(.stepSummary)
        .foregroundStyle(running ? WebColor.text.color : WebGlass.textMuted.color)
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      if failed > 0 {
        Text("\(failed) failed").font(.system(size: 9, weight: .bold)).textCase(.uppercase)
          .tracking(0.6)
          .foregroundStyle(WebColor.danger.color)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(WebColor.danger.color.opacity(0.12), in: Capsule())
      }
      if let time {
        Text(time).webFont(.stepTime)
          .foregroundStyle(running ? WebColor.jobProgressText.color : WebGlass.textMuted.color)
      }
    }
    .frame(minHeight: 28)
    .contentShape(Rectangle())
  }
}

struct SubagentPartView: View {
  let call: WebToolCall
  let message: WebMessage
  let store: ConsoleStore
  @State private var expanded = false
  @State private var loading = false
  @State private var repairFailed = false
  var body: some View {
    ActivityDisclosure(
      "Subagent · " + (call.name ?? call.toolName ?? "Delegation"),
      summary: call.label ?? UsagePresentation.text(UsagePresentation.layers(call.args), ["prompt"])
        ?? "",
      status: call.status == "running" ? .connecting : call.status == "failed" ? .failed : .online,
      detail: [
        call.status, "\(call.calls?.count ?? 0) tool calls",
        JobPresentation.duration(call.executionMs),
        TranscriptPresentation.cost(
          .init(amount: call.costUsd, unknown: call.costUnknown, knownSpend: call.knownCostUsd)),
      ].joined(separator: " · "),
      glyph: .agent, identifier: "subagent-" + call.toolCallId, expanded: $expanded
    ) {
      VStack(alignment: .leading, spacing: 7) {
        if let route = call.attribution {
          let executed = route.executed
          RouteBadge(
            model: executed?.model ?? route.attempted?.model ?? route.requested.model
              ?? "Unknown model",
            effort: executed?.effectiveEffort ?? executed?.effort ?? route.attempted?.effort
              ?? route.requested.effort ?? "",
            detail: TranscriptPresentation.attribution(route, status: call.status))
        }
        DisclosureGroup("Task") {
          Text(
            UsagePresentation.text(UsagePresentation.layers(call.args), ["prompt"])
              ?? TranscriptPresentation.json(call.args)
          ).textSelection(.enabled)
        }
        let calls = call.calls ?? []
        if calls.isEmpty { Text("No tool calls recorded.").webFont(.jobDetail) }
        ForEach(TranscriptPresentation.clusters(calls.map(WebMessagePart.toolCall))) { cluster in
          if cluster.parts.count > 1 {
            ToolClusterView(
              calls: cluster.parts.compactMap {
                if case .toolCall(let call) = $0 { return call }
                return nil
              }, message: message, store: store)
          } else if let part = cluster.parts.first {
            TranscriptPartView(part: part, message: message, store: store)
          }
        }
        if call.result != nil {
          Text(JobPresentation.preview(TranscriptPresentation.json(call.result), limit: 200).text)
            .webFont(.jobDetail).lineLimit(3)
          DisclosureGroup("Latest answer") {
            CodeDocumentView(source: TranscriptPresentation.json(call.result), language: "Report")
          }
        }
        if call.argsTruncated == true || call.resultTruncated == true {
          Text("Preview only").webFont(.activityMeta)
          Button(loading ? "Loading…" : "Load full delegation") {
            loading = true
            Task {
              repairFailed =
                !(await store.repairToolOutput(
                  threadID: message.threadId, messageID: message.id, toolCallID: call.toolCallId))
              loading = false
            }
          }.disabled(loading)
        }
        if repairFailed {
          Text("Could not load full delegation. Retry or refresh.").webFont(.activityMeta)
        }
        if call.history?.persistence == "failed" {
          Text("Tool history was not saved.").webFont(.activityMeta)
        }
      }
    }
  }
}
