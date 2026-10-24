// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentStore

struct ServerTimestampTests {
  @Test func reusableStrategiesAcceptBothPrecisions() {
    for _ in 0..<100 {
      #expect(
        ServerTimestamp.date("2030-01-02T12:00:00Z")
          == ServerTimestamp.date("2030-01-02T12:00:00.000Z"))
      #expect(
        ServerTimestamp.date("2030-01-02T13:00:00+01:00")
          == ServerTimestamp.date("2030-01-02T12:00:00Z"))
    }
    #expect(ServerTimestamp.date(nil) == nil)
    #expect(ServerTimestamp.date("not a date") == nil)
  }
  @Test func clockOnlyCorrectsMeaningfulDrift() {
    #expect(ServerTimestamp.correctedOffset(current: 10, proposed: 10.9) == 10)
    #expect(ServerTimestamp.correctedOffset(current: 10, proposed: 11) == 10)
    #expect(ServerTimestamp.correctedOffset(current: 10, proposed: 11.1) == 11.1)
    #expect(ServerTimestamp.correctedOffset(current: 10, proposed: 8) == 8)
    #expect(ServerTimestamp.correctedOffset(current: 10, proposed: .nan) == 10)
  }
}
