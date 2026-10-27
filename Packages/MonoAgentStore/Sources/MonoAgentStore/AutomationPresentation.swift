// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum AutomationPresentation {
  public static func schedule(_ job: WebCronJob) -> String {
    [job.expression ?? "Unknown schedule", job.timezone ?? "Unknown timezone"].joined(
      separator: " · ")
  }
  public static func state(_ job: WebCronJob, live: Bool) -> String {
    !job.configured ? "Removed" : !live ? "Snapshot" : job.effectiveEnabled ? "Enabled" : "Disabled"
  }
  public static func lastInvocation(_ job: WebCronJob) -> Date? {
    guard let run = job.lastRun else { return nil }
    let stamp = run.completedAt ?? run.startedAt ?? run.orderedAt
    return ServerTimestamp.date(stamp)
  }
  public static func jobs(_ overview: WebCronOverview?, query: String) -> [WebCronJob] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (overview?.jobs ?? []).filter { job in
      let state =
        !job.configured ? "removed historical" : job.effectiveEnabled ? "enabled" : "disabled"
      return needle.isEmpty
        || [
          job.jobId, job.expression ?? "", job.timezone ?? "", state, job.health,
          schedule(job),
        ].contains { $0.lowercased().contains(needle) }
    }.sorted { left, right in
      let a = lastInvocation(left)
      let b = lastInvocation(right)
      if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
      return left.jobId < right.jobId
    }
  }
  public static func nextRun(_ job: WebCronJob, live: Bool, now: Date) -> Date? {
    guard live, job.configured, job.effectiveEnabled,
      let value = job.nextRunAt.flatMap(ServerTimestamp.date), value > now
    else { return nil }
    return value
  }
  public static func runStatus(_ job: WebCronJob) -> String {
    if job.activeRunId != nil { return "Run in progress" }
    guard let run = job.lastRun else { return "No runs yet" }
    return run.status.replacingOccurrences(of: "_", with: " ").capitalized
  }
}
