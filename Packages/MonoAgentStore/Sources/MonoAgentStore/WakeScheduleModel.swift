// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import os

/// Wall-clock values only. The server resolves DST gaps, overlaps and future instants.
public struct WakeDraft: Sendable, Equatable {
  public var kind = "once"
  public var timezone = "UTC"
  public var date = ""
  public var time = "09:00"
  public var days: [Int] = []
  public var times = ["09:00"]
  public var message = ""
  public var compactFirst = false
  public init() {}
}
public struct WakeIssues: Sendable, Equatable {
  public var timezone: String?
  public var when: String?
  public var days: String?
  public var times: String?
  public var badTimes: [Int] = []
  public var message: String?
  public var hasIssues: Bool {
    timezone != nil || when != nil || days != nil || times != nil || message != nil
  }
}
public struct WakeFailure: Sendable, Equatable {
  public var message: String
  public var conflict = false
  public var detail: String?
  public init(message: String, conflict: Bool = false, detail: String? = nil) {
    self.message = message
    self.conflict = conflict
    self.detail = detail
  }
}
public enum WakeScheduleModel {
  public static let maxTimes = 8
  public static let maxMessageBytes = 1000
  public static let messageCounterFrom = 800
  public static let weekdays = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  public static let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  public static func utf8Bytes(_ text: String) -> Int { text.utf8.count }
  private static let zoneNames: [String: String] = {
    var names = Dictionary(
      uniqueKeysWithValues: TimeZone.knownTimeZoneIdentifiers.map { ($0.lowercased(), $0) })
    // Intl canonical links used by the web. Never infer identity from equal TZif bytes:
    // distinct jurisdictions can share rules today and diverge in the future.
    for (link, name) in [
      "GB": "Europe/London", "GB-Eire": "Europe/London", "Eire": "Europe/Dublin",
      "US/Eastern": "America/New_York", "US/Central": "America/Chicago",
      "US/Mountain": "America/Denver",
      "US/Pacific": "America/Los_Angeles", "US/Alaska": "America/Anchorage",
      "US/Hawaii": "Pacific/Honolulu",
      "UTC": "UTC", "Etc/UTC": "UTC", "GMT": "UTC", "Etc/GMT": "UTC",
    ] { names[link.lowercased()] = name }
    for offset in -14...14 {
      let name = "Etc/GMT" + (offset >= 0 ? "+" : "") + String(offset)
      names[name.lowercased()] = name
    }
    return names
  }()
  private static let zoneCache = OSAllocatedUnfairLock(initialState: [String: String]())
  // Value formatters are Sendable on the package's macOS 14 floor; unlike a shared
  // ISO8601DateFormatter they need no unsafe isolation escape hatch.
  private static let fractionalParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let plainParser = Date.ISO8601FormatStyle()
  private static func parseInstant(_ iso: String) -> Date? {
    (try? fractionalParser.parse(iso)) ?? (try? plainParser.parse(iso))
  }
  public static func normalizeTimeZone(_ input: String) -> String? {
    let zone = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !zone.isEmpty, zone.count <= 128 else { return nil }
    return zoneCache.withLock { cache in
      if let result = cache[zone] { return result.isEmpty ? nil : result }
      let result = zoneNames[zone.lowercased()] ?? TimeZone(identifier: zone)?.identifier
      let valid = result.flatMap { name in
        name.hasPrefix("GMT+") || name.hasPrefix("GMT-") ? nil : name
      }
      // Bound arbitrary text typed into the timezone field as well as valid results.
      if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
      cache[zone] = valid ?? ""
      return valid
    }
  }
  public static func validTime(_ time: String) -> Bool {
    time.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil
  }
  public static func validDate(_ date: String) -> Bool {
    date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
  }
  static func formatter(
    _ format: String, zone: String = "UTC", locale: Locale = Locale(identifier: "en_US_POSIX")
  ) -> DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = locale
    f.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
    f.dateFormat = format
    return f
  }
  public static func wallClock(_ instant: Date, zone: String) -> String {
    formatter("yyyy-MM-dd'T'HH:mm", zone: zone).string(from: instant)
  }
  public static func newDraft(timezone: String = TimeZone.current.identifier, now: Date = Date())
    -> WakeDraft
  {
    var draft = WakeDraft()
    draft.timezone = normalizeTimeZone(timezone) ?? "UTC"
    let calendarDate = String(wallClock(now, zone: draft.timezone).prefix(10))
    let f = formatter("yyyy-MM-dd")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    draft.date = f.string(
      from: calendar.date(byAdding: .day, value: 1, to: f.date(from: calendarDate)!)!)
    return draft
  }
  public static func draft(from definition: WebWakeScheduleDefinition) -> WakeDraft {
    var value = WakeDraft()
    value.kind = definition.kind
    value.timezone = definition.timezone
    value.message = definition.message ?? ""
    value.compactFirst = definition.compactFirst == true
    if definition.kind == "once" {
      let parts = (definition.localAt ?? "").components(separatedBy: "T")
      value.date = parts.first ?? ""
      value.time = parts.count > 1 ? parts[1] : ""
    } else {
      value.days = definition.days ?? []
      value.times = definition.times ?? []
    }
    return value
  }
  public static func definition(from draft: WakeDraft) -> WebWakeScheduleDefinition {
    .init(
      kind: draft.kind, timezone: normalizeTimeZone(draft.timezone) ?? draft.timezone,
      localAt: draft.kind == "once" ? "\(draft.date)T\(draft.time)" : nil,
      days: draft.kind == "weekly" ? draft.days.sorted() : nil,
      times: draft.kind == "weekly" ? draft.times : nil,
      message: draft.message.isEmpty ? nil : draft.message,
      compactFirst: draft.compactFirst ? true : nil)
  }
  public static func isDirty(_ draft: WakeDraft, baseline: WebWakeScheduleDefinition?) -> Bool {
    guard let baseline else { return true }
    func canonical(_ value: WebWakeScheduleDefinition) -> WebWakeScheduleDefinition {
      var value = definition(from: self.draft(from: value))
      value.times = value.times?.sorted()
      return value
    }
    return canonical(definition(from: draft)) != canonical(baseline)
  }
  public static func validate(_ draft: WakeDraft) -> WakeIssues {
    var issues = WakeIssues()
    if normalizeTimeZone(draft.timezone) == nil {
      issues.timezone = "Choose a valid timezone, such as Europe/Berlin."
    }
    if draft.kind == "once" {
      if !validDate(draft.date) || !validTime(draft.time) {
        issues.when = "Choose a date and a time."
      }
    } else {
      if draft.days.isEmpty { issues.days = "Pick at least one day." }
      issues.badTimes = draft.times.indices.filter {
        !validTime(draft.times[$0]) || draft.times.firstIndex(of: draft.times[$0]) != $0
      }
      if !issues.badTimes.isEmpty {
        issues.times =
          draft.times.contains(where: { !validTime($0) })
          ? "Enter every time, or remove the empty one." : "Each time can be used only once."
      }
      if draft.times.isEmpty || draft.times.count > maxTimes {
        issues.times = "Choose between one and eight times."
      }
      if draft.days.contains(where: { !(0...6).contains($0) }) {
        issues.days = "Choose valid weekdays."
      }
    }
    let bytes = utf8Bytes(draft.message)
    if bytes > maxMessageBytes {
      issues.message =
        "\(bytes - maxMessageBytes) bytes over the limit. Emoji and accented letters use more than one byte."
    }
    return issues
  }
  public static func onceLooksPast(_ draft: WakeDraft, now: Date = Date()) -> Bool {
    guard let zone = normalizeTimeZone(draft.timezone), validDate(draft.date), validTime(draft.time)
    else { return false }
    return "\(draft.date)T\(draft.time)" < wallClock(now.addingTimeInterval(-3600), zone: zone)
  }
  public static func onceHasElapsed(_ definition: WebWakeScheduleDefinition, now: Date = Date())
    -> Bool
  {
    let draft = self.draft(from: definition)
    guard definition.kind == "once", let zone = normalizeTimeZone(draft.timezone),
      validDate(draft.date), validTime(draft.time)
    else { return false }
    return "\(draft.date)T\(draft.time)" <= wallClock(now, zone: zone)
  }
  public static func nextTimeSlot(_ times: [String]) -> String {
    let last = times.reversed().first(where: validTime) ?? "08:00"
    let parts = last.split(separator: ":").compactMap { Int($0) }
    for step in 1...24 {
      let next = String(format: "%02d:%02d", (parts[0] + step) % 24, parts[1])
      if !times.contains(next) { return next }
    }
    return last
  }
  public static func weekOrder(locale: Locale = .current) -> [Int] {
    var c = Calendar(identifier: .gregorian)
    c.locale = locale
    let first = c.firstWeekday - 1
    return (0..<7).map { (first + $0) % 7 }
  }
  public static func formatWallTime(_ time: String, locale: Locale = .current) -> String {
    guard validTime(time), let date = formatter("HH:mm").date(from: time) else { return time }
    let f = formatter("HH:mm", locale: locale)
    f.setLocalizedDateFormatFromTemplate("jjmm")
    return f.string(from: date)
  }
  public static func formatWallDate(_ date: String, locale: Locale = .current) -> String {
    guard validDate(date), let instant = formatter("yyyy-MM-dd").date(from: date) else {
      return date
    }
    let f = formatter("", locale: locale)
    f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
    return f.string(from: instant)
  }
  private static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
  }
  public static func describe(_ draft: WakeDraft, locale: Locale = .current, order: [Int]? = nil)
    -> String?
  {
    let sentence: String
    if draft.kind == "once" {
      guard validDate(draft.date), validTime(draft.time) else { return nil }
      sentence =
        "\(formatWallDate(draft.date, locale: locale)) at \(formatWallTime(draft.time, locale: locale))"
    } else {
      let times = Array(Set(draft.times.filter(validTime))).sorted()
      guard !draft.days.isEmpty, !times.isEmpty else { return nil }
      let days = Set(draft.days)
      let phrase: String
      if days == Set(0...6) {
        phrase = "Every day"
      } else if days == Set(1...5) {
        phrase = "Every weekday"
      } else if days == [0, 6] {
        phrase = "Every Saturday and Sunday"
      } else {
        phrase =
          "Every "
          + list(
            (order ?? weekOrder(locale: locale)).filter { days.contains($0) }.map { shortDays[$0] })
      }
      sentence =
        times.count > 3
        ? "\(phrase), \(times.count) times on each selected day"
        : "\(phrase) at \(list(times.map { formatWallTime($0, locale: locale) }))"
    }
    return sentence + (draft.compactFirst ? " · Compact conversation first" : "")
  }
  public static func instant(
    _ iso: String, zone: String = TimeZone.current.identifier, locale: Locale = .current
  ) -> String {
    guard let date = parseInstant(iso) else { return iso }
    let f = formatter("", zone: zone, locale: locale)
    f.setLocalizedDateFormatFromTemplate("EEE d MMM jjmm")
    return f.string(from: date)
  }
  public static func nextFire(
    _ iso: String, scheduleZone: String, deviceZone: String = TimeZone.current.identifier,
    locale: Locale = .current
  ) -> (scheduled: String, local: String?) {
    let scheduled = instant(iso, zone: scheduleZone, locale: locale)
    guard normalizeTimeZone(scheduleZone) != normalizeTimeZone(deviceZone),
      let date = parseInstant(iso)
    else { return (scheduled, nil) }
    let scheduleWall = wallClock(date, zone: scheduleZone)
    let deviceWall = wallClock(date, zone: deviceZone)
    if scheduleWall == deviceWall { return (scheduled, nil) }
    let local =
      scheduleWall.prefix(10) == deviceWall.prefix(10)
      ? formatWallTime(String(deviceWall.suffix(5)), locale: locale)
      : instant(iso, zone: deviceZone, locale: locale)
    return (scheduled, local)
  }
  public static func status(_ summary: WakeSummary, locale: Locale = .current) -> String {
    let kind = summary.kind == "once" ? "Once" : "Weekly"
    let state =
      ["paused", "completed"].contains(summary.state)
      ? summary.state : summary.nextFireAt.map { "next " + instant($0, locale: locale) } ?? "active"
    return "\(kind) · \(state)" + (summary.compactFirst == true ? " · compact first" : "")
  }
  public static func outcome(_ outcome: String) -> String {
    switch outcome {
    case "fired": "Last wake-up ran."
    case "skipped": "Last wake-up was skipped because it was more than an hour late."
    case "failed": "Last wake-up started but its turn failed."
    case "uncertain": "Last wake-up started; its result isn't confirmed yet."
    default: "Last wake-up: \(outcome)."
    }
  }
  public static func failure(_ error: any Error) -> WakeFailure {
    let code = (error as? APIError)?.code ?? ""
    switch code {
    case "wake_revision_conflict", "wake_schedule_exists":
      return .init(
        message: code == "wake_revision_conflict"
          ? "This schedule changed since you opened it."
          : "A schedule was created for this conversation elsewhere.", conflict: true,
        detail: "Load the latest version to continue. This replaces your unsaved changes.")
    case "wake_schedule_not_found":
      return .init(
        message: "This schedule was deleted elsewhere.", conflict: true,
        detail:
          "Load the latest version to continue. Your edits stay, and Save creates the schedule again."
      )
    case "invalid_wake_schedule":
      return .init(
        message:
          "Check the date, timezone, days, times and message. The server validates future times and daylight-saving gaps."
      )
    default:
      return .init(
        message: (error as? LocalizedError)?.errorDescription
          ?? "The schedule change was not confirmed. Try again.")
    }
  }
}
