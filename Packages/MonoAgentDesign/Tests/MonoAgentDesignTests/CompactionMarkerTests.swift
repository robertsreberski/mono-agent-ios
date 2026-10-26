// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgentDesign

struct CompactionMarkerTests {
  @MainActor @Test func pulseIsOnlyScheduledForAnAnimatedRunningRow() {
    #expect(
      CompactionMarkerRow.animates(running: true, reduceMotion: false, animationsEnabled: true))
    #expect(
      !CompactionMarkerRow.animates(running: false, reduceMotion: false, animationsEnabled: true))
    #expect(
      !CompactionMarkerRow.animates(running: true, reduceMotion: true, animationsEnabled: true))
    #expect(
      !CompactionMarkerRow.animates(running: true, reduceMotion: false, animationsEnabled: false))
    #expect(CompactionMarkerRow.opacity(at: 0) == 1)
    #expect(abs(CompactionMarkerRow.opacity(at: 0.6) - 0.55) < 0.0001)
  }
}
