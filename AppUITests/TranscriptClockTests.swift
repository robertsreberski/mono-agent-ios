// SPDX-License-Identifier: GPL-3.0-only
import XCTest

@MainActor final class TranscriptClockTests: XCTestCase {
  func testRunningElapsedUsesResolvedFixtureServerTimeExactlyOnce() {
    for scenario in ["composer-running"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "--scenario", scenario, "--appearance", "light", "--reset-test-data",
      ]
      app.launch()
      XCTAssertTrue(
        app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 20))
      // The running turn's clock lives in its Activity header (web `ActivityElapsed`).
      let band = app.descendants(matching: .any)["activity-band"].firstMatch
      let resolved = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in band.exists && band.label.contains("1 step · 1m 0s") },
        object: nil)
      XCTAssertEqual(
        XCTWaiter.wait(for: [resolved], timeout: 10), .completed,
        "The elapsed clock must not apply the server offset twice: \(scenario)")
      XCTAssertFalse(
        app.staticTexts.containing(NSPredicate(format: "label MATCHES %@", ".*[0-9]{4,}m.*"))
          .firstMatch.exists)
      app.terminate()
    }
  }
}
