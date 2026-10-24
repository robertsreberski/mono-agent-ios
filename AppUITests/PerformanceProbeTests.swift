// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// Explicit opt-in timing drill; does not alter transcript regression assertions.
@MainActor final class PerformanceProbeTests: XCTestCase {
  func testLongSwipeTiming() throws {
    guard ProcessInfo.processInfo.environment["MONO_PERF_PROBE"] == "1" else {
      throw XCTSkip("Opt-in performance timing drill")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-long", "--reset-test-data", "--performance-probe",
    ]
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 20))
    let start = ContinuousClock.now
    let scroll = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
    let older = app.descendants(matching: .any)["transcript-load-older"].firstMatch
    var swipes = 0
    for _ in 0..<120 {
      if older.exists && older.isHittable { break }
      scroll.swipeDown(velocity: .fast)
      swipes += 1
    }
    print(
      "PERF_SWIPES count=\(swipes) elapsed=\(start.duration(to: .now)) reachedOlder=\(older.exists && older.isHittable)"
    )
    app.terminate()
  }
}
