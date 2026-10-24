// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

struct TranscriptClockTests {
  @Test func sharedMinuteAgeAdvancesWithWallClockAndResolvesOffsetOnce() throws {
    let created = "2030-01-01T12:00:00Z"
    let start = try #require(TranscriptPresentation.date(created))
    let wall = start.addingTimeInterval(-3600)
    let first = TranscriptClock.ageDate(wall: wall, offset: 3600)
    let later = TranscriptClock.ageDate(wall: wall.addingTimeInterval(120), offset: 3600)
    #expect(DashboardModel.relativeTime(created, now: first) == "now")
    #expect(DashboardModel.relativeTime(created, now: later) == "2m")
    #expect(TranscriptClock.ageDate(wall: later, offset: 3600, fixture: start) == start)
  }
  @Test func runningToSettledElapsedStopsAdvancingButRelativeAgeDoesNot() throws {
    var message = try TranscriptFixture.message(
      id: "clock-transition", role: "assistant", text: "Sample")
    message.createdAt = "2030-01-01T12:00:00Z"
    message.finishedAt = nil
    message.status = "running"
    let start = try #require(TranscriptPresentation.date(message.createdAt))
    for seconds in [30, 90] {
      let date = TranscriptClock.elapsedDate(
        running: true, serverDate: start.addingTimeInterval(Double(seconds)))
      #expect(
        TranscriptPresentation.elapsed(message, now: date) == (seconds == 30 ? "30s" : "1m 30s"))
    }
    message.status = "complete"
    message.finishedAt = "2030-01-01T12:01:30Z"
    for seconds in [120, 240] {
      let live = start.addingTimeInterval(Double(seconds))
      let frozen = TranscriptClock.elapsedDate(running: false, serverDate: live)
      #expect(frozen == .distantPast)
      #expect(TranscriptPresentation.elapsed(message, now: frozen) == "1m 30s")
      #expect(DashboardModel.relativeTime(message.createdAt, now: live) == "\(seconds / 60)m")
    }
  }
}
