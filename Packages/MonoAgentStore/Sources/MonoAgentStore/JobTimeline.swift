// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public struct JobParentCall: Identifiable, Sendable, Equatable {
  public var id: String { messageID + ":" + call.toolCallId }
  public var messageID: String
  public var call: WebToolCall
  public var action: String
  public var text: String?
  public var at: String
  public var launchedJobID: String?
  public var closed = false
  public var peerThread: String?
}
public enum JobTimelineStep: Identifiable, Sendable, Equatable {
  case call(JobParentCall)
  case turn(ProcessJobProjection)
  public var id: String {
    switch self {
    case .call(let call): "call:" + call.id
    case .turn(let job): "turn:" + job.jobId
    }
  }
}
extension JobShelf {
  private static func resultText(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    if case .array(let parts) = value {
      let text = parts.compactMap { part -> String? in
        guard case .object(let record) = part, record["type"] == .string("text"),
          case .string(let text) = record["text"]
        else { return nil }
        return text
      }
      return text.isEmpty ? nil : text.joined(separator: "\n")
    }
    return nil
  }
  /// Parent prose is display-only, never interpreted as approval or sent back to a child.
  /// Only unique, tool-matching host receipts associate unnamed launches with turns.
  public static func timeline(_ item: JobShelfItem, messages: [WebMessage]) -> [JobTimelineStep] {
    var calls: [JobParentCall] = []
    var peerModes: [String: Bool] = [:]
    let threadIDs = Set(
      item.jobs.compactMap { job -> String? in
        let origin = String(
          job.origin.conversationId.split(separator: "#", maxSplits: 1).first ?? "")
        return origin.hasPrefix("web:") ? String(origin.dropFirst(4)) : nil
      })
    for message in messages
    where message.role == "assistant" && (threadIDs.isEmpty || threadIDs.contains(message.threadId))
    {
      for part in message.parts {
        let call: WebToolCall
        switch part {
        case .toolCall(let value), .subagent(let value): call = value
        default: continue
        }
        let tool = call.toolName ?? call.name ?? ""
        let family =
          tool == "PeerAgent" || tool.hasSuffix("__PeerAgent")
          ? "peer" : ["Agent", "AgentManage", "AgentSend"].contains(tool) ? "agent" : nil
        guard let family, family == item.family else { continue }
        let records = UsagePresentation.layers(call.args)
        let args = records.first ?? [:]
        let addressed = UsagePresentation.text(records, family == "peer" ? ["peer"] : ["id"])
        let peerThread = UsagePresentation.text(records, ["thread"])
        let receipt = UsagePresentation.layers(call.structuredResult)
        let canonical =
          UsagePresentation.text(receipt, ["schema"]) == "mono-agent.process-job-start-receipt.v1"
          && UsagePresentation.text(receipt, ["tool"]) == tool
          && ["queued", "starting", "running"].contains(
            UsagePresentation.text(receipt, ["state"]) ?? "")
          && receipt.first?["startedAt"] != nil
        var launched = canonical ? UsagePresentation.text(receipt, ["jobId"]) : nil
        var action =
          tool == "Agent"
          ? "brief"
          : args["steer"] != nil
            ? "steer"
            : args["stop"] == .bool(true)
              ? "stop"
              : args["message"] != nil
                ? "message" : args["close"] == .bool(true) ? "close" : "message"
        var text =
          UsagePresentation.text(records, ["prompt", "message", "steer"])
          ?? {
            if case .string(let text) = call.args { return text }
            return nil
          }()
        if family == "peer" {
          action = UsagePresentation.text(records, ["action"]) ?? "message"
          let key = (addressed ?? "") + "\u{0}" + (peerThread ?? "")
          let detached =
            action == "send" ? args["background"] == .bool(true) : peerModes[key] == true
          var started: String?
          if detached, call.status == "complete", let result = resultText(call.result),
            let data = result.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let host) = value, Set(host.keys) == ["peer", "thread", "jobId", "state"],
            host["peer"] == args["peer"], host["thread"] == args["thread"],
            host["state"] == .string("started"),
            case .string(let id) = host["jobId"]
          {
            started = id
          }
          if action == "send", call.status == "complete", !detached || started != nil {
            peerModes[key] = detached
          }
          launched = started
          if action == "answer", case .object(let answers) = args["answers"] {
            text = answers.keys.sorted().map { key in
              key + ": " + (resultText(answers[key]) ?? String(describing: answers[key]!))
            }.joined(separator: "\n")
          }
          if action == "send" { action = "message" }
        }
        guard
          addressed != nil
            ? addressed == item.instanceID : item.jobs.contains(where: { $0.jobId == launched })
        else { continue }
        let closeRequested = args["close"] == .bool(true)
        let closePattern =
          "^<subagent: [^<>\\n]+ · instance "
          + NSRegularExpression.escapedPattern(for: item.instanceID ?? "")
          + " · turn \\d+ · closed(?: · [^<>\\n]*)?>"
        let closed =
          family == "agent" && closeRequested && call.status == "complete"
          && resultText(call.result)?.range(of: closePattern, options: .regularExpression) != nil
        calls.append(
          .init(
            messageID: message.id, call: call, action: action, text: text, at: message.createdAt,
            launchedJobID: launched, closed: closed, peerThread: peerThread))
      }
    }
    let claims = Dictionary(grouping: calls.compactMap { $0.launchedJobID }, by: { $0 }).mapValues(
      \.count)
    var remaining = item.jobs
    var steps: [JobTimelineStep] = []
    var asked = false
    for var call in calls {
      while let first = remaining.first, first.jobId != call.launchedJobID,
        (JobPresentation.date(first.timestamps.admittedAt) ?? .distantPast)
          < (JobPresentation.date(call.at) ?? .distantPast)
      {
        steps.append(.turn(first))
        remaining.removeFirst()
        asked = first.subagentQuestion != nil || first.peerQuestion != nil
      }
      if call.action == "message" && asked {
        call.action = "reply"
        asked = false
      }
      steps.append(.call(call))
      if let id = call.launchedJobID, claims[id] == 1,
        let index = remaining.firstIndex(where: { $0.jobId == id && $0.tool == call.call.toolName })
      {
        let job = remaining.remove(at: index)
        steps.append(.turn(job))
        asked = job.subagentQuestion != nil || job.peerQuestion != nil
      }
    }
    return steps + remaining.map(JobTimelineStep.turn)
  }
  public static func visibleSteps(
    _ item: JobShelfItem, messages: [WebMessage], unfolded: Bool, now: Date
  ) -> [JobTimelineStep] {
    let steps = timeline(item, messages: messages)
    guard !unfolded, item.jobs.count > 4 else { return steps }
    let turns = steps.indices.filter {
      if case .turn = steps[$0] { return true }
      return false
    }
    guard turns.count > 2 else { return steps }
    var foldAt = turns[turns.count - 2]
    if foldAt > 0, case .call(let call) = steps[foldAt - 1], case .turn(let job) = steps[foldAt],
      call.launchedJobID == job.jobId
    {
      foldAt -= 1
    }
    var pinned: Set<Int> = []
    for index in steps.indices where index < foldAt {
      if case .turn(let job) = steps[index], JobPresentation.pending(job, now: now) {
        pinned.insert(index)
        if index > 0, case .call(let call) = steps[index - 1], call.launchedJobID == job.jobId {
          pinned.insert(index - 1)
        }
      }
    }
    return steps.enumerated().filter { $0.offset >= foldAt || pinned.contains($0.offset) }.map(
      \.element)
  }
  public static func purpose(_ item: JobShelfItem, messages: [WebMessage]) -> String {
    let title = JobPresentation.title(item.newest)
    let generic =
      title == "Persistent subagent " + (item.instanceID ?? "")
      || title.range(
        of: #"^Peer \S+ thread \S+( question continuation)?$"#, options: .regularExpression) != nil
    if generic,
      let task = timeline(item, messages: messages).reversed().compactMap({ step -> String? in
        if case .call(let call) = step, ["brief", "message", "reply"].contains(call.action) {
          return call.text
        }
        return nil
      }).first
    {
      return task.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let prefix = "Peer " + (item.instanceID ?? "") + " "
    return item.family == "peer" && title.hasPrefix(prefix)
      ? String(title.dropFirst(prefix.count)) : title
  }
  public static func cost(_ item: JobShelfItem) -> String? {
    let prices = item.jobs.compactMap(\.subagentProgress)
    guard !prices.isEmpty else { return nil }
    var known = 0.0
    var hasKnown = false
    var unknown = false
    for progress in prices {
      switch CostAmount(
        amount: progress.costUsd, unknown: progress.costUnknown, knownSpend: progress.knownCostUsd)
      {
      case .known(let amount):
        known += amount
        hasKnown = true
      case .unknown(let spend):
        unknown = true
        if let spend, spend.isFinite, spend >= 0 {
          known += spend
          hasKnown = true
        }
      }
    }
    if !known.isFinite { return "Cost unknown" }
    return unknown
      ? "Cost unknown" + (hasKnown ? " · Known cost " + UsagePresentation.usd(known) : "")
      : UsagePresentation.usd(known) + " total"
  }
  public static func closed(_ item: JobShelfItem, messages: [WebMessage]) -> Bool {
    var closed = false
    for step in timeline(item, messages: messages) {
      switch step {
      case .turn: closed = false
      case .call(let call): if call.closed { closed = true }
      }
    }
    return closed
  }
}
