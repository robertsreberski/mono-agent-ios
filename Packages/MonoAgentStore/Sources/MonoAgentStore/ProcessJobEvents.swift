// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// One background-job lifecycle fact as the transcript shows it (web
/// `ProcessJobActivityEvent`): the launch ("started") or the outcome ("terminal").
public struct ProcessJobActivityEvent: Sendable, Equatable, Identifiable {
  public enum Phase: String, Sendable { case started, terminal }
  public var id: String
  /// The launching tool call (or, for a delivered wake, its delivery key).
  public var toolCallId: String
  public var jobId: String
  public var tool: String
  public var summary: String
  public var phase: Phase
  public var state: String
  public var occurredAt: String?
  public var durationMs: Double?
  public var exitCode: Int?
  public var signal: String?
  /// The folded launch call's arguments; only on a started event that replaced its tool row.
  public var launchArgs: JSONValue?
  public var launchArgsTruncated: Bool?
  public var launchArgsBytes: Int?

  /// Web `processJobTerminalEvent`.
  public static func terminal(_ job: ProcessJobProjection, toolCallId: String) -> Self {
    .init(
      id: "process-job:\(job.jobId):terminal", toolCallId: toolCallId, jobId: job.jobId,
      tool: job.tool, summary: job.summary, phase: .terminal, state: job.state,
      occurredAt: job.timestamps.completedAt, durationMs: job.durationMs, exitCode: job.exitCode,
      signal: job.signal)
  }
}

/// The host's start receipt on the Exec/Bash/Agent call that launched a job.
public struct ProcessJobStartReceipt: Sendable, Equatable {
  public var jobId: String
  public var tool: String
  public var state: String
  public var startedAt: String?
  public var maxRuntimeMs: Double?
}

/// Pure port of the web's `projectProcessJobPresentation`: background jobs live in the shelf, so
/// `process-job` parts leave the transcript; each job contributes at most a "started" event
/// (paired to its launch call only through a unique host receipt) and a "terminal" event (unless a
/// wake already delivered it), both placed in the message that launched the job.
public enum ProcessJobEvents {
  public static let toolNames: Set<String> = [
    "Exec", "Bash", "Agent", "AgentManage", "AgentSend", "PeerAgent",
  ]
  public static let receiptSchema = "mono-agent.process-job-start-receipt.v1"

  public struct Projection: Sendable, Equatable {
    public var eventsByMessageID: [String: [ProcessJobActivityEvent]] = [:]
    /// Merged projections by job id (the wake conversion reads its job here).
    public var jobsByID: [String: ProcessJobProjection] = [:]
    public init() {}
  }

  /// Web `canonicalIsoTimestamp`: exactly the form `Date#toISOString` produces.
  public static func canonical(_ value: String?) -> Bool {
    guard let value, value.utf8.count == 24,
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil,
      let date = ServerTimestamp.date(value)
    else { return false }
    return date.formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true)) == value
  }

  /// Web `parseProcessJobStartReceipt`: only the canonical receipt with exactly its keys, for the
  /// tool that carries it.
  public static func receipt(_ value: JSONValue?, containingTool: String?)
    -> ProcessJobStartReceipt?
  {
    guard case .object(let record) = value else { return nil }
    let required: Set<String> = ["schema", "jobId", "tool", "state", "startedAt"]
    let keys = Set(record.keys)
    guard required.isSubset(of: keys), keys.subtracting(required).isSubset(of: ["maxRuntimeMs"]),
      record["schema"] == .string(receiptSchema),
      case .string(let tool) = record["tool"], toolNames.contains(tool), tool == containingTool,
      case .string(let jobId) = record["jobId"],
      !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, jobId.utf16.count <= 256,
      case .string(let state) = record["state"], ["queued", "starting", "running"].contains(state)
    else { return nil }
    var startedAt: String?
    switch record["startedAt"] {
    case .null?: startedAt = nil
    case .string(let value)? where canonical(value): startedAt = value
    default: return nil
    }
    var maxRuntimeMs: Double?
    if let limit = record["maxRuntimeMs"] {
      guard case .number(let number) = limit, number > 0, number.rounded() == number,
        number <= 9_007_199_254_740_991
      else { return nil }
      maxRuntimeMs = number
    }
    return .init(
      jobId: jobId, tool: tool, state: state, startedAt: startedAt, maxRuntimeMs: maxRuntimeMs)
  }

  /// Web `processJobThreadId`: the retained web thread a job reports to.
  public static func threadID(_ job: ProcessJobProjection) -> String? {
    let base = job.origin.conversationId.split(separator: "#", maxSplits: 1).first.map(String.init)
    guard let base, base.hasPrefix("web:"), base != "web:new" else { return nil }
    let id = String(base.dropFirst(4))
    return id.isEmpty ? nil : id
  }

  public static func project(messages: [WebMessage], threadID: String?) -> Projection {
    let messages = orderedMessages(messages)
    var projection = Projection()
    var order: [String] = []
    for message in messages {
      for part in message.parts {
        guard case .processJob(let value) = part else { continue }
        let job = value.job
        if let held = projection.jobsByID[job.jobId] {
          projection.jobsByID[job.jobId] = JobPresentation.merge(held, job)
        } else {
          projection.jobsByID[job.jobId] = job
          order.append(job.jobId)
        }
      }
    }
    guard let threadID else { return projection }
    let wakeJobIDs = Set(
      messages.flatMap { message in
        message.parts.compactMap { part -> String? in
          if case .processJobWake(let wake) = part { return wake.jobId }
          return nil
        }
      })
    struct Candidate {
      var messageID: String
      var toolCallID: String
      var receipt: ProcessJobStartReceipt
    }
    var candidates: [String: [String: Candidate]] = [:]
    var ambiguous = Set<String>()
    for message in messages where message.role == "assistant" && message.threadId == threadID {
      for part in message.parts {
        guard case .toolCall(let call) = part,
          let receipt = receipt(call.structuredResult, containingTool: call.toolName)
        else { continue }
        let key = message.id + "\u{0}" + call.toolCallId + "\u{0}" + receipt.jobId
        if let existing = candidates[receipt.jobId]?[key] {
          if existing.receipt != receipt { ambiguous.insert(receipt.jobId) }
        } else {
          candidates[receipt.jobId, default: [:]][key] = Candidate(
            messageID: message.id, toolCallID: call.toolCallId, receipt: receipt)
        }
      }
    }
    for jobID in order {
      guard let job = projection.jobsByID[jobID], !ambiguous.contains(jobID),
        let paired = candidates[jobID], paired.count == 1, let candidate = paired.values.first,
        self.threadID(job) == threadID, candidate.receipt.tool == job.tool
      else { continue }
      let admitted = ServerTimestamp.date(job.timestamps.admittedAt)
      let receiptStart = candidate.receipt.startedAt
      let projectionStart = job.timestamps.startedAt
      let conflicts =
        receiptStart != nil && projectionStart != nil && receiptStart != projectionStart
      let started = conflicts ? nil : receiptStart ?? projectionStart
      let validStarted: String? = {
        guard let started, canonical(started), let date = ServerTimestamp.date(started),
          let admitted, date >= admitted
        else { return nil }
        return started
      }()
      var events: [ProcessJobActivityEvent] = []
      if let validStarted {
        events.append(
          .init(
            id: "process-job:\(job.jobId):started", toolCallId: candidate.toolCallID,
            jobId: job.jobId, tool: job.tool, summary: job.summary, phase: .started,
            state: job.state, occurredAt: validStarted))
      }
      if JobPresentation.terminal(job) && !wakeJobIDs.contains(job.jobId) {
        var settled = job
        let completed = job.timestamps.completedAt
        let valid: Bool = {
          guard let completed, canonical(completed), let date = ServerTimestamp.date(completed),
            let admitted, date >= admitted
          else { return false }
          if let validStarted, let start = ServerTimestamp.date(validStarted) {
            return date >= start
          }
          return true
        }()
        settled.timestamps.completedAt = valid ? completed : nil
        events.append(.terminal(settled, toolCallId: candidate.toolCallID))
      }
      if !events.isEmpty {
        projection.eventsByMessageID[candidate.messageID, default: []].append(contentsOf: events)
      }
    }
    return projection
  }

  /// Web `convertWebMessage` for one message: `process-job` parts leave the transcript, a wake
  /// becomes its job's terminal event (or nothing when the job is unknown), and a completed launch
  /// call with a started event folds into it (its Input moves onto the started row). Launches
  /// without a started event keep their tool row, followed by their events.
  public static func entries(
    for message: WebMessage, projection: Projection, shelfOwnedCalls: Set<String> = []
  ) -> [TranscriptEntry] {
    let events = projection.eventsByMessageID[message.id] ?? []
    var byCall: [String: [ProcessJobActivityEvent]] = [:]
    for event in events { byCall[event.toolCallId, default: []].append(event) }
    var items: [TranscriptEntry] = []
    for (index, part) in message.parts.enumerated() {
      func append(_ item: TranscriptItem, suffix: String = "") {
        items.append(.init(id: "part-\(index)" + suffix, item: item))
      }
      switch part {
      case .processJob:
        continue
      case .processJobWake(let wake):
        if let job = projection.jobsByID[wake.jobId] {
          append(.jobEvent(.terminal(job, toolCallId: wake.deliveryKey)))
        }
      case .toolCall(let call):
        let launch = byCall[call.toolCallId] ?? []
        guard !launch.isEmpty else {
          if !shelfOwnedCalls.contains(callKey(message.id, call.toolCallId)) { append(.part(part)) }
          continue
        }
        let folds = call.status == "complete" && launch.contains { $0.phase == .started }
        if !folds { append(.part(part)) }
        for var event in launch {
          if folds && event.phase == .started && call.args != nil {
            event.launchArgs = call.args
            event.launchArgsTruncated = call.argsTruncated == true ? true : nil
            event.launchArgsBytes = call.argsBytes
          }
          append(.jobEvent(event), suffix: ":" + event.phase.rawValue)
        }
      default:
        append(.part(part))
      }
    }
    return items
  }
  public static func items(for message: WebMessage, projection: Projection) -> [TranscriptItem] {
    entries(for: message, projection: projection).map(\.item)
  }
  public static func callKey(_ messageID: String, _ callID: String) -> String {
    messageID + "\u{0}" + callID
  }
  /// Only rows that actually appear in an existing shelf group are suppressed. Unmatched,
  /// malformed and foreground calls remain reachable in the transcript.
  public static func shelfOwnedCalls(messages: [WebMessage], items: [JobShelfItem]) -> Set<String> {
    Set(
      items.filter { $0.family != nil }.flatMap { item in
        JobShelf.timeline(item, messages: messages).compactMap { step -> String? in
          guard case .call(let parent) = step else { return nil }
          return callKey(parent.messageID, parent.call.toolCallId)
        }
      })
  }

  public static func showsAttribution(_ value: WebRunAttribution?, status: String) -> Bool {
    guard let value else { return false }
    if value.disposition == "fallback" || !value.transitions.isEmpty || !value.retries.isEmpty {
      return true
    }
    let run = value.executed ?? value.attempted
    func effort(_ text: String) -> String {
      text.lowercased() == "none" ? "off" : text.lowercased()
    }
    if let effective = run?.effectiveEffort, let requested = value.requested.effort,
      effort(effective) != effort(requested)
    {
      return true
    }
    guard status != "complete", let attempted = run?.model, !attempted.isEmpty,
      let requested = value.requested.model, !requested.isEmpty
    else { return false }
    return attempted != requested
  }

  /// Applied steers replace their standalone user bubble only while the inline marker is loaded.
  /// Other live inputs remain below their target turn, not above the work they are steering.
  public static func orderedMessages(_ messages: [WebMessage]) -> [WebMessage] {
    let inlineIDs = Set(
      messages.flatMap { message in
        message.parts.compactMap { part -> String? in
          if case .steer(let steer) = part { return steer.messageId }
          return nil
        }
      })
    let shaped = messages.filter { $0.role != "user" || !inlineIDs.contains($0.id) }
    var anchors: [String: Int] = [:]
    for (index, message) in shaped.enumerated()
    where message.role != "user" || message.liveInputStatus == nil {
      if let turn = message.turnId { anchors[turn] = index }
    }
    var moved = Set<String>()
    var following: [Int: [WebMessage]] = [:]
    for message in shaped where message.role == "user" && message.liveInputStatus != nil {
      if let turn = message.turnId, let anchor = anchors[turn] {
        following[anchor, default: []].append(message)
        moved.insert(message.id)
      }
    }
    return shaped.enumerated().flatMap { index, message in
      (moved.contains(message.id) ? [] : [message]) + (following[index] ?? [])
    }
  }

  public static func visible(_ message: WebMessage, entries: [TranscriptEntry]) -> Bool {
    guard TranscriptTelemetry.visible(message) else { return false }
    guard message.role == "assistant",
      message.parts.contains(where: { if case .processJob = $0 { true } else { false } })
    else { return true }
    if !message.attachments.isEmpty || message.quote != nil
      || ["failed", "interrupted", "cancelled"].contains(message.status)
      || showsAttribution(message.attribution, status: message.status)
    {
      return true
    }
    return entries.contains { entry in
      guard case .part(let part) = entry.item else { return true }
      switch part {
      case .text(let text), .reasoning(let text):
        return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      default: return TranscriptTelemetry.visible(part, in: message)
      }
    }
  }

}

/// A transcript row source: a stored message part or a synthesised job event.
public enum TranscriptItem: Sendable, Equatable {
  case part(WebMessagePart)
  case jobEvent(ProcessJobActivityEvent)
  public var part: WebMessagePart? {
    if case .part(let value) = self { return value }
    return nil
  }
}

/// Identity retains the stored part index, even when preceding job carriers disappear or a
/// terminal event is inserted. A band's disclosure key must not shift as a job settles.
public struct TranscriptEntry: Sendable, Equatable, Identifiable {
  public var id: String
  public var item: TranscriptItem
}
