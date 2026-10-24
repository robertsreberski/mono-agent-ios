// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

struct WakeModelTests {
  let locale = Locale(identifier: "en_GB")
  var weekly: WakeDraft {
    var d = WakeDraft()
    d.kind = "weekly"
    d.days = [3, 1]
    d.times = ["14:30", "09:00"]
    return d
  }
  func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
  @Test func bytesAndValidation() {
    #expect(WakeScheduleModel.utf8Bytes("abc") == 3)
    #expect(WakeScheduleModel.utf8Bytes("é") == 2)
    #expect(WakeScheduleModel.utf8Bytes("😀") == 4)
    var d = weekly
    d.message = String(repeating: "a", count: 996) + "😀"
    #expect(WakeScheduleModel.validate(d).message == nil)
    d.message = String(repeating: "a", count: 997) + "😀"
    #expect(WakeScheduleModel.validate(d).message?.hasPrefix("1 bytes over") == true)
    d = weekly
    d.days = []
    #expect(WakeScheduleModel.validate(d).days == "Pick at least one day.")
    d = weekly
    d.times = ["09:00", "09:00"]
    #expect(WakeScheduleModel.validate(d).badTimes == [1])
    #expect(WakeScheduleModel.validate(d).times == "Each time can be used only once.")
    d.times = ["09:00", ""]
    #expect(WakeScheduleModel.validate(d).times?.hasPrefix("Enter every time") == true)
    d.kind = "once"
    d.date = ""
    #expect(WakeScheduleModel.validate(d).when != nil)
    d.date = "2031-05-14"
    #expect(!WakeScheduleModel.validate(d).hasIssues)
  }
  @Test func zones() {
    #expect(WakeScheduleModel.normalizeTimeZone(" europe/berlin ") == "Europe/Berlin")
    #expect(WakeScheduleModel.normalizeTimeZone("Mars/Olympus") == nil)
    #expect(WakeScheduleModel.normalizeTimeZone("Etc/UTC") == "UTC")
    var d = weekly
    d.timezone = "Nowhere/Else"
    #expect(WakeScheduleModel.validate(d).timezone != nil)
  }
  @Test func hourlySlots() {
    for (times, next) in [
      (["09:00", "14:30"], "15:30"), (["23:15"], "00:15"), (["09:00", "10:00", "11:00"], "12:00"),
      (["10:00", "09:00"], "11:00"),
    ] {
      #expect(WakeScheduleModel.nextTimeSlot(times) == next)
    }
  }
  @Test func tomorrowUsesZoneCalendarAndCrossesYear() {
    #expect(
      WakeScheduleModel.newDraft(timezone: "UTC", now: date("2030-12-31T12:00:00Z")).date
        == "2031-01-01")
    #expect(
      WakeScheduleModel.newDraft(timezone: "Asia/Tokyo", now: date("2031-01-31T23:30:00Z")).date
        == "2031-02-02")
    #expect(
      WakeScheduleModel.newDraft(timezone: "UTC", now: date("2031-05-13T10:00:00Z")).time == "09:00"
    )
  }
  @Test func identityAndRoundTrip() {
    let saved = WakeScheduleModel.definition(from: weekly)
    #expect(saved.days == [1, 3])
    #expect(saved.times == ["14:30", "09:00"])
    #expect(saved.message == nil)
    var d = weekly
    d.days = [1, 3]
    d.times.reverse()
    d.timezone = "utc"
    d.date = "2040-01-01"
    #expect(!WakeScheduleModel.isDirty(d, baseline: saved))
    d.message = " "
    #expect(WakeScheduleModel.isDirty(d, baseline: saved))
    #expect(WakeScheduleModel.isDirty(weekly, baseline: nil))
    let once = WebWakeScheduleDefinition(
      kind: "once", timezone: "UTC", localAt: "2031-05-14T09:00", message: "Hi")
    #expect(WakeScheduleModel.definition(from: WakeScheduleModel.draft(from: once)) == once)
  }
  @Test func elapsedHasNoGraceAndServerResolvesOverlap() {
    var once = WebWakeScheduleDefinition(kind: "once", timezone: "UTC", localAt: "2031-05-14T09:00")
    for minute in ["00", "01", "59"] {
      #expect(WakeScheduleModel.onceHasElapsed(once, now: date("2031-05-14T09:\(minute):00Z")))
    }
    #expect(!WakeScheduleModel.onceHasElapsed(once, now: date("2031-05-14T08:59:00Z")))
    once.timezone = "Asia/Tokyo"
    #expect(WakeScheduleModel.onceHasElapsed(once, now: date("2031-05-14T00:30:00Z")))
    once.timezone = "America/New_York"
    once.localAt = "2026-11-01T01:30"
    #expect(WakeScheduleModel.onceHasElapsed(once, now: date("2026-11-01T05:45:00Z")))
    #expect(!WakeScheduleModel.onceHasElapsed(once, now: date("2026-11-01T06:10:00Z")))
    once.localAt = "not-a-time"
    #expect(!WakeScheduleModel.onceHasElapsed(once))
  }
  @Test func pastIsHintOnly() {
    var d = weekly
    d.kind = "once"
    d.date = "2031-05-14"
    d.time = "09:00"
    #expect(WakeScheduleModel.onceLooksPast(d, now: date("2031-05-14T12:00:00Z")))
    d.time = "11:30"
    #expect(!WakeScheduleModel.onceLooksPast(d, now: date("2031-05-14T12:00:00Z")))
    d.date = "2031-05-15"
    #expect(!WakeScheduleModel.onceLooksPast(d, now: date("2031-05-14T12:00:00Z")))
  }
  @Test func weeklyWording() {
    let order = [1, 2, 3, 4, 5, 6, 0]
    #expect(
      WakeScheduleModel.describe(weekly, locale: locale, order: order)
        == "Every Mon and Wed at 09:00 and 14:30")
    var d = weekly
    d.days = [1, 2, 3, 4, 5]
    #expect(WakeScheduleModel.describe(d, locale: locale) == "Every weekday at 09:00 and 14:30")
    d.days = Array(0...6)
    d.times = ["06:00"]
    #expect(WakeScheduleModel.describe(d, locale: locale) == "Every day at 06:00")
    d = weekly
    d.times = ["06:00", "08:00", "10:00", "12:00"]
    #expect(
      WakeScheduleModel.describe(d, locale: locale, order: order)
        == "Every Mon and Wed, 4 times on each selected day")
    d.days = []
    #expect(WakeScheduleModel.describe(d) == nil)
  }
  @Test func wallDateWording() {
    var d = weekly
    d.kind = "once"
    d.date = "2031-05-14"
    d.time = "09:00"
    let text = WakeScheduleModel.describe(d, locale: locale)!
    #expect(text.contains("14 May 2031"))
    #expect(text.hasSuffix("at 09:00"))
  }
  @Test func savedNextFireZonesAndDifferentCalendarDays() {
    let next = WakeScheduleModel.nextFire(
      "2031-05-12T12:30:00Z", scheduleZone: "America/Chicago", deviceZone: "Europe/Lisbon",
      locale: locale)
    #expect(next.scheduled.contains("07:30"))
    #expect(next.local == "13:30")
    let different = WakeScheduleModel.nextFire(
      "2031-05-12T23:30:00Z", scheduleZone: "America/Chicago", deviceZone: "Asia/Tokyo",
      locale: locale)
    #expect(different.local?.contains("13 May") == true)
    #expect(different.local?.contains("08:30") == true)
    #expect(
      WakeScheduleModel.nextFire("2031-05-12T12:30:00Z", scheduleZone: "UTC", deviceZone: "Etc/UTC")
        .local == nil)
    #expect(
      WakeScheduleModel.nextFire(
        "2031-01-12T12:30:00Z", scheduleZone: "Europe/Lisbon", deviceZone: "UTC"
      ).local == nil)
  }
  @Test func statusAndOutcomes() {
    for (state, kind, text) in [
      ("active", "once", "Once · active"), ("paused", "weekly", "Weekly · paused"),
      ("completed", "once", "Once · completed"),
    ] {
      #expect(
        WakeScheduleModel.status(.init(state: state, revision: 1, nextFireAt: nil, kind: kind))
          == text)
    }
    #expect(
      WakeScheduleModel.status(
        .init(state: "active", revision: 1, nextFireAt: "2031-05-12T12:30:00Z", kind: "weekly")
      ).hasPrefix("Weekly · next "))
    #expect(WakeScheduleModel.outcome("skipped").contains("more than an hour late"))
    #expect(WakeScheduleModel.outcome("uncertain").contains("isn't confirmed"))
  }
  @Test func conflictsAndSafeTransportErrors() {
    for code in ["wake_revision_conflict", "wake_schedule_not_found", "wake_schedule_exists"] {
      #expect(WakeScheduleModel.failure(APIError(status: 409, code: code)).conflict)
    }
    #expect(
      WakeScheduleModel.failure(APIError(status: 404, code: "wake_schedule_not_found")).detail?
        .contains("Your edits stay") == true)
    #expect(
      !WakeScheduleModel.failure(APIError(status: 400, code: "invalid_wake_schedule")).conflict)
    #expect(
      WakeScheduleModel.failure(APIError(status: 409, code: "thread_archived")).message
        == "Console request failed (HTTP 409).")
  }
  @Test func compactFirstIdentityAndSummary() {
    var d = weekly
    d.compactFirst = true
    let def = WakeScheduleModel.definition(from: d)
    #expect(def.compactFirst == true)
    #expect(WakeScheduleModel.draft(from: def).compactFirst)
    #expect(!WakeScheduleModel.draft(from: WakeScheduleModel.definition(from: weekly)).compactFirst)
    #expect(WakeScheduleModel.isDirty(d, baseline: WakeScheduleModel.definition(from: weekly)))
    #expect(WakeScheduleModel.describe(d)?.contains("Compact conversation first") == true)
    #expect(
      WakeScheduleModel.status(
        .init(state: "paused", revision: 1, nextFireAt: nil, kind: "weekly", compactFirst: true)
      ).contains("compact first"))
  }
}
