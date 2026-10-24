// SPDX-License-Identifier: GPL-3.0-only
import XCTest

@MainActor final class TranscriptClockTests: XCTestCase {
  func testRunningElapsedUsesResolvedFixtureServerTimeExactlyOnce() {
    for scenario in ["composer-running", "conversation-ask-form"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "--scenario", scenario, "--appearance", "light", "--reset-test-data",
      ]
      app.launch()
      XCTAssertTrue(
        app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 20))
      XCTAssertTrue(
        app.staticTexts["Cost unknown · 1m 0s"].firstMatch.waitForExistence(timeout: 10),
        "Attribution must not apply the server offset twice: \(scenario)")
      XCTAssertFalse(
        app.staticTexts.containing(NSPredicate(format: "label MATCHES %@", ".*[0-9]{4,}m.*"))
          .firstMatch.exists)
      app.terminate()
    }
  }
}
