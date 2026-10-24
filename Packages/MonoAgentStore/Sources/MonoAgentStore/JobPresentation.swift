// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Pure, clock-snapshot-driven decisions shared by job rows, groups and their counts.
public enum JobPresentation {
  public static let terminalStates: Set<String> = [
    "succeeded", "failed", "timed_out", "cancelled", "spawn_failed", "queue_expired", "interrupted",
  ]
  public static func terminal(_ job: ProcessJobProjection) -> Bool {
    terminalStates.contains(job.state)
  }
  public static func title(_ job: ProcessJobProjection) -> String {
    command(job) && job.summary.hasPrefix("Purpose: ")
      ? String(job.summary.dropFirst(9)) : job.summary
  }
  public static func command(_ job: ProcessJobProjection) -> Bool {
    ["Exec", "Bash"].contains(job.tool)
  }
  public static func date(_ stamp: String?) -> Date? {
    ServerTimestamp.date(stamp)
  }
  public static func pending(_ job: ProcessJobProjection, now: Date) -> Bool {
    guard let question = job.peerQuestion, question.state == "awaiting_answer",
      let deadline = date(question.expiresAt)
    else { return false }
    return deadline > now
  }
  public static func current(_ job: ProcessJobProjection, now: Date) -> Bool {
    !terminal(job) || pending(job, now: now)
      || (job.subagentQuestion != nil && job.wake.state == "pending")
  }
  public static func issue(_ job: ProcessJobProjection) -> Bool {
    terminal(job)
      && ((!(["succeeded", "cancelled"].contains(job.state)))
        || ["failed", "unknown"].contains(job.wake.state) || job.childStillBusy == true)
  }
  public struct Status: Sendable, Equatable {
    public var label: String
    public var symbol: String
    public var tone: String
  }
  public static func status(_ job: ProcessJobProjection, now: Date) -> Status {
    if !terminal(job) && job.cancelRequested {
      return .init(label: "Stopping", symbol: "stop.circle", tone: "neutral")
    }
    if job.state == "succeeded" && pending(job, now: now) {
      return .init(label: "Question pending", symbol: "questionmark.circle", tone: "warning")
    }
    let face: (String, String, String) =
      switch job.state {
      case "queued": ("Queued", "circle", "neutral")
      case "starting": ("Starting", "circle.lefthalf.filled", "warning")
      case "running": ("Running", "circle.lefthalf.filled", "warning")
      case "succeeded": ("Done", "checkmark.circle.fill", "success")
      case "failed": ("Failed", "xmark.circle.fill", "danger")
      case "spawn_failed": ("Failed to start", "xmark.circle.fill", "danger")
      case "interrupted": ("Interrupted", "exclamationmark.circle.fill", "danger")
      case "timed_out": ("Timed out", "clock.fill", "danger")
      case "queue_expired": ("Expired in queue", "clock.badge.exclamationmark", "danger")
      case "cancelled": ("Cancelled", "stop.circle.fill", "neutral")
      default:
        (job.state.replacingOccurrences(of: "_", with: " "), "questionmark.circle", "neutral")
      }
    return .init(label: face.0, symbol: face.1, tone: face.2)
  }
  public static func elapsed(_ job: ProcessJobProjection, now: Date) -> Double? {
    guard let start = date(job.timestamps.startedAt ?? job.timestamps.admittedAt) else {
      return nil
    }
    if terminal(job) && job.timestamps.startedAt == nil { return nil }
    if let duration = job.durationMs, duration.isFinite, duration >= 0 { return duration }
    if let finish = date(job.timestamps.completedAt) {
      return max(0, finish.timeIntervalSince(start) * 1000)
    }
    return terminal(job) ? nil : max(0, now.timeIntervalSince(start) * 1000)
  }
  public static func duration(_ milliseconds: Double?) -> String {
    guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else {
      return "Unknown duration"
    }
    let seconds = min(milliseconds / 1000, Double(Int.max / 1000))
    if seconds < 1 { return "\(Int(milliseconds))ms" }
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds)
    if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
    return "\(whole / 3600)h \(whole % 3600 / 60)m"
  }
  public struct Preview: Sendable, Equatable {
    public var text: String
    public var bounded: Bool
  }
  /// Defence in depth over server-redacted content. Never interpret output as instructions,
  /// ANSI controls or a filesystem/capability URL. Bound before regex work, then redact.
  public static func preview(_ source: String, limit: Int = 2048) -> Preview {
    let cap = max(0, min(limit, 65_536))
    var text = String(source.prefix(cap))
    for (pattern, replacement) in [
      (#"\x1B\[[0-?]*[ -/]*[@-~]"#, ""),
      (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[redacted]"),
      (
        #"(?i)(["']?(?:api[_-]?key|access[_-]?token|token|password|secret|credential|signature|x-amz-signature)["']?\s*[=:]\s*["']?)[^"'\s,;}&]+"#,
        "$1[redacted]"
      ),
      (#"(https?://)[^\s/@]+:[^\s/@]+@"#, "$1[redacted]@"),
    ] {
      text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    text = String(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
    return .init(text: String(text.prefix(cap)), bounded: source.count > cap)
  }
  /// Do not regress lifecycle, output, immutable identity or settled facts after a slow poll.
  public static func merge(_ held: ProcessJobProjection, _ next: ProcessJobProjection)
    -> ProcessJobProjection
  {
    guard held.schema == next.schema, held.jobId == next.jobId, held.tool == next.tool,
      held.instanceId == next.instanceId, held.summary == next.summary,
      held.origin == next.origin, held.limits == next.limits,
      held.timestamps.admittedAt == next.timestamps.admittedAt,
      held.timestamps.queueDeadlineAt == next.timestamps.queueDeadlineAt,
      held.wake.deliveryKey == next.wake.deliveryKey
    else { return held }
    let ranks = ["queued": 0, "starting": 1, "running": 2]
    if held.state != next.state && (ranks[next.state] ?? 3) <= (ranks[held.state] ?? 3) {
      return held
    }
    var result = next
    result.timestamps.startedAt = held.timestamps.startedAt ?? next.timestamps.startedAt
    result.timestamps.runtimeDeadlineAt =
      held.timestamps.runtimeDeadlineAt ?? next.timestamps.runtimeDeadlineAt
    result.timestamps.completedAt = held.timestamps.completedAt ?? next.timestamps.completedAt
    result.durationMs = held.durationMs ?? next.durationMs
    result.exitCode = held.exitCode ?? next.exitCode
    result.signal = held.signal ?? next.signal
    result.cancelRequested = held.cancelRequested || next.cancelRequested
    result.lastError = held.lastError ?? next.lastError
    if next.output.stdoutBytes < held.output.stdoutBytes
      || next.output.stderrBytes < held.output.stderrBytes
    {
      result.output = held.output
    } else {
      result.output.truncated = held.output.truncated || next.output.truncated
      if next.output.stdoutBytes == held.output.stdoutBytes,
        next.output.stderrBytes == held.output.stderrBytes,
        next.output.preview.count < held.output.preview.count
      {
        result.output.preview = held.output.preview
      }
    }
    if next.wake.attempts < held.wake.attempts
      || (held.wake.state != "pending" && next.wake.state != held.wake.state)
    {
      result.wake = held.wake
    }
    if let old = held.subagentProgress, old.revision > (next.subagentProgress?.revision ?? -1) {
      result.subagentProgress = old
    }
    return result
  }
}

public struct JobShelfItem: Identifiable, Sendable, Equatable {
  public var id: String
  public var jobs: [ProcessJobProjection]
  public var family: String?
  public var instanceID: String?
  public var newest: ProcessJobProjection { jobs[jobs.count - 1] }
  public func lead(now: Date) -> ProcessJobProjection {
    jobs.reversed().first { JobPresentation.pending($0, now: now) }
      ?? jobs.reversed().first { !JobPresentation.terminal($0) } ?? newest
  }
  public func bucket(now: Date) -> JobShelfBucket {
    if jobs.contains(where: {
      JobPresentation.pending($0, now: now)
        || (JobPresentation.terminal($0) && JobPresentation.current($0, now: now))
    }) {
      return .question
    }
    if jobs.contains(where: { !JobPresentation.terminal($0) }) { return .active }
    if JobPresentation.issue(newest) { return .issue }
    return newest.state == "cancelled" ? .cancelled : .done
  }
  public func visibleJobs(unfolded: Bool, now: Date) -> [ProcessJobProjection] {
    guard !unfolded, jobs.count > 4 else { return jobs }
    let kept = Set(jobs.suffix(2).map(\.jobId))
    return jobs.filter { kept.contains($0.jobId) || JobPresentation.pending($0, now: now) }
  }
}
public enum JobShelfBucket: String, CaseIterable, Sendable {
  case question, active, issue, cancelled, done
  public var current: Bool { self == .question || self == .active }
}
public enum JobShelf {
  /// De-duplicate projections by job identity; agent groups sit at their newest turn's slot.
  public static func items(messages: [WebMessage]) -> [JobShelfItem] {
    var jobs: [ProcessJobProjection] = []
    for message in messages {
      for part in message.parts {
        guard case .processJob(let part) = part else { continue }
        if let index = jobs.firstIndex(where: { $0.jobId == part.job.jobId }) {
          jobs[index] = JobPresentation.merge(jobs[index], part.job)
        } else {
          jobs.append(part.job)
        }
      }
    }
    return items(jobs: jobs)
  }
  public static func items(jobs: [ProcessJobProjection]) -> [JobShelfItem] {
    var projections: [ProcessJobProjection] = []
    for job in jobs {
      if let index = projections.firstIndex(where: { $0.jobId == job.jobId }) {
        projections[index] = JobPresentation.merge(projections[index], job)
      } else {
        projections.append(job)
      }
    }
    var items: [JobShelfItem] = []
    for job in projections {
      let family =
        job.kind == "internal"
        ? ((job.tool == "PeerAgent" || job.tool.hasSuffix("__PeerAgent"))
          ? "peer" : ["Agent", "AgentManage", "AgentSend"].contains(job.tool) ? "agent" : nil) : nil
      let key = family.flatMap { family in job.instanceId.map { family + ":" + $0 } } ?? job.jobId
      let old = items.first { $0.id == key }
      items.removeAll { $0.id == key }
      items.append(
        .init(id: key, jobs: (old?.jobs ?? []) + [job], family: family, instanceID: job.instanceId))
    }
    return items
  }
  public static func counts(_ items: [JobShelfItem], now: Date) -> [JobShelfBucket: Int] {
    Dictionary(grouping: items, by: { $0.bucket(now: now) }).mapValues(\.count)
  }
  public static func summary(_ items: [JobShelfItem], now: Date) -> String {
    let counts = counts(items, now: now)
    return JobShelfBucket.allCases.compactMap { bucket in
      counts[bucket].map {
        "\($0) \(bucket == .question ? ($0 == 1 ? "question awaiting the agent" : "questions awaiting the agent") : bucket == .issue ? ($0 == 1 ? "issue" : "issues") : bucket.rawValue)"
      }
    }.joined(separator: " · ")
  }
}
