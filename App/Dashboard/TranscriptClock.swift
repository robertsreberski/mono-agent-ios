// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Wall time is resolved once; fixture clocks remain deterministic in synthetic screenshots.
enum TranscriptClock {
  static func ageDate(wall: Date, offset: TimeInterval, fixture: Date? = nil) -> Date {
    fixture ?? wall.addingTimeInterval(offset)
  }
  static func elapsedDate(running: Bool, serverDate: Date) -> Date {
    running ? serverDate : .distantPast
  }
}

extension EnvironmentValues {
  @Entry var transcriptMinuteDate: Date?
}
