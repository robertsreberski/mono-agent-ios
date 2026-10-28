// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum AutomationPresentation {
  public static func schedule(_ job: WebCronJob) -> String {
    let expression = (job.expression ?? "").split(whereSeparator: { $0.isWhitespace }).joined(
      separator: " ")
    guard !expression.isEmpty else { return "Schedule unavailable" }
    let zone = (job.timezone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let timezone = zone.isEmpty ? "UTC" : zone
    let fallback = expression + " (" + timezone + ")"
    let fields = expression.split(separator: " ").map(String.init)
    guard fields.count == 5, fields[2] == "*", fields[3] == "*" else { return fallback }
    func integer(_ value: String, max: Int) -> Int? {
      guard (1...2).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let number = Int(value), number <= max
      else { return nil }
      return number
    }
    if fields[1] == "*", fields[4] == "*" {
      if fields[0] == "*" { return "Every minute" }
      if fields[0].hasPrefix("*/"), let step = integer(String(fields[0].dropFirst(2)), max: 59),
        step > 0, 60 % step == 0
      {
        return step == 1 ? "Every minute" : "Every \(step) minutes"
      }
    }
    guard let minute = integer(fields[0], max: 59) else { return fallback }
    let minutes = String(format: "%02d", minute)
    if fields[1] == "*", fields[4] == "*" { return "Every hour at :\(minutes) (\(timezone))" }
    guard let hour = integer(fields[1], max: 23) else { return fallback }
    let time = String(format: "%02d", hour) + ":" + minutes + " (" + timezone + ")"
    if fields[4] == "*" { return "Every day at " + time }
    if fields[4] == "1-5" { return "Weekdays at " + time }
    guard let day = integer(fields[4], max: 7) else { return fallback }
    let weekdays = [
      "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
    return "Every " + weekdays[day] + " at " + time
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
      let value = futureInstant(job.nextRunAt, now: now)
    else { return nil }
    return value
  }
  /// Reject normalized calendar dates and zone-less wall times, matching the web list.
  public static func futureInstant(_ stamp: String?, now: Date) -> Date? {
    guard let stamp,
      stamp.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
        options: .regularExpression) != nil
    else { return nil }
    let fields = stamp.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap {
      Int($0)
    }
    guard fields.count == 6 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      year: fields[0], month: fields[1], day: fields[2],
      hour: fields[3], minute: fields[4], second: fields[5])
    guard components.isValidDate(in: calendar), let date = ServerTimestamp.date(stamp), date > now
    else { return nil }
    return date
  }
  public static func runStatus(_ job: WebCronJob) -> String {
    if job.activeRunId != nil { return "Run in progress" }
    guard let run = job.lastRun else { return "No runs yet" }
    return run.status.replacingOccurrences(of: "_", with: " ").capitalized
  }
}
