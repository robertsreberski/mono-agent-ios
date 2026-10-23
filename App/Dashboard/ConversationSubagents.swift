// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct JobPeerQuestionView: View {
  let question: PeerProcessJobQuestion
  let now: Date
  /// C8 may supply this when its composer can answer. No answer route is invoked here.
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  private var pending: Bool {
    question.state == "awaiting_answer"
      && (JobPresentation.date(question.expiresAt).map { $0 > now } ?? false)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Label(
        pending
          ? "Question pending"
          : question.state == "awaiting_answer"
            ? "Past expiry; awaiting host confirmation"
            : question.state.replacingOccurrences(of: "_", with: " ").capitalized,
        systemImage: "questionmark.bubble"
      )
      .designFont(.headline).accessibilityIdentifier("peer-question")
      Text(question.peer + " / " + question.thread).designFont(.caption).foregroundStyle(.secondary)
      Text(JobPresentation.preview(question.message, limit: 16_384).text).textSelection(.enabled)
      if let date = JobPresentation.date(question.expiresAt), question.state == "awaiting_answer" {
        Text("Expires " + date.formatted()).designFont(.caption)
      }
      Text("Untrusted peer text; not owner approval.").designFont(.caption).foregroundStyle(
        .secondary)
      Button(onAnswerPeerQuestion == nil ? "Answer · coming in composer" : "Answer") {
        onAnswerPeerQuestion?(question)
      }.disabled(!pending || onAnswerPeerQuestion == nil)
        .designButtonStyle(.secondary).accessibilityIdentifier("peer-question-answer")
      DisclosureGroup("Requested form (reference only)") {
        CodeDocumentView(
          source: TranscriptPresentation.json(.object(question.requestedSchema)), language: "JSON")
      }.designFont(.caption)
    }
  }
}

struct JobSubagentProgressView: View {
  let progress: ProcessJobSubagentProgress
  @State private var reportExpanded = false
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
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Text(progress.profile + (progress.label.map { " · " + $0 } ?? "")).designFont(.headline)
        .accessibilityIdentifier("subagent-progress")
      if let route = progress.route {
        let executed = route.executed
        RouteBadge(
          model: executed?.model ?? route.requested.model ?? "Unknown model",
          effort: executed?.effectiveEffort ?? executed?.effort ?? route.requested.effort ?? "",
          detail: (executed == nil ? "Requested only · not confirmed execution" : "Executed")
            + " · " + (route.disposition ?? "unknown"))
      }
      Text("\(progress.toolCalls) tool calls · \(progress.failedCalls) failed").designFont(.caption)
      Text(
        TranscriptPresentation.cost(
          .init(
            amount: progress.costUsd, unknown: progress.costUnknown,
            knownSpend: progress.knownCostUsd))
      )
      .designFont(.caption).foregroundStyle(.secondary)
      if progress.toolCalls > progress.recent.count {
        Text("Showing latest \(progress.recent.count) of \(progress.toolCalls) calls").designFont(
          .caption)
      }
      if progress.recent.isEmpty { Text("No tool calls yet.").designFont(.supporting) }
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        if let first = group.first {
          DisclosureGroup {
            ForEach(group, id: \.id) { call in
              VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Label(
                  call.status,
                  systemImage: call.status == "failed"
                    ? "xmark.circle"
                    : call.status == "running" ? "circle.lefthalf.filled" : "checkmark.circle")
                if let args = call.argsSummary {
                  Text(JobPresentation.preview(args, limit: 2048).text).textSelection(.enabled)
                }
                if let workdir = call.workdir {
                  Text("Directory: " + workdir).textSelection(.enabled)
                }
                if let duration = call.executionMs { Text(JobPresentation.duration(duration)) }
              }.designFont(.caption)
            }
          } label: {
            let current = group.last(where: { $0.status == "running" }) ?? group[group.count - 1]
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
              Text(
                first.toolName + (group.count > 1 ? " ×\(group.count)" : "") + " · "
                  + current.status)
              if let args = current.argsSummary {
                Text(JobPresentation.preview(args, limit: 72).text).designFont(.code).lineLimit(2)
              }
            }
          }.designFont(.supporting)
        }
      }
      if let answer = progress.answerHead {
        Text(JobPresentation.preview(answer, limit: 200).text).designFont(.supporting).lineLimit(3)
        DisclosureGroup(
          "Latest answer" + (progress.answerTruncated == true ? " · server-truncated" : ""),
          isExpanded: $reportExpanded
        ) {
          Text(JobPresentation.preview(answer, limit: 16_384).text).designFont(.body).textSelection(
            .enabled)
          if progress.answerTruncated == true {
            Text("Only the answer head is available through this API.").designFont(.caption)
          }
        }.accessibilityIdentifier("subagent-latest-answer")
      }
    }
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
      identifier: "subagent-" + call.toolCallId, expanded: $expanded
    ) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
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
        if calls.isEmpty { Text("No tool calls recorded.").designFont(.supporting) }
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
            .designFont(.supporting).lineLimit(3)
          DisclosureGroup("Latest answer") {
            CodeDocumentView(source: TranscriptPresentation.json(call.result), language: "Report")
          }
        }
        if call.argsTruncated == true || call.resultTruncated == true {
          Text("Preview only").designFont(.caption)
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
          Text("Could not load full delegation. Retry or refresh.").designFont(.caption)
        }
        if call.history?.persistence == "failed" {
          Text("Tool history was not saved.").designFont(.caption)
        }
      }
    }
  }
}
