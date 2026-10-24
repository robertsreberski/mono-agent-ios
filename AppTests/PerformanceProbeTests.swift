// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Testing
  @testable import MonoAgent

  struct PerformanceProbeCounterTests {
    @MainActor @Test func countersAreIndependentAndResetAtWindowStart() {
      var counts = PerformanceProbe.BodyCounts()
      counts.record("Row")
      counts.record("Row")
      counts.record("Screen")
      #expect(counts.values == ["Row": 2, "Screen": 1])
      counts.reset()
      #expect(counts.values.isEmpty)
    }
  }
#endif
