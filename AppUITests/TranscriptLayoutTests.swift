// SPDX-License-Identifier: GPL-3.0-only
import XCTest

@MainActor final class TranscriptLayoutTests: XCTestCase {
  func testShortTranscriptsStartAtReadingEdgeAfterDockAndMarkdownLayout() {
    for scenario in ["conversation-placeholder", "conversation-markdown", "conversation-streaming"]
    {
      let app = XCUIApplication()
      app.launchArguments = [
        "--scenario", scenario, "--appearance", "light", "--reset-test-data",

      ]
      app.launch()
      XCTAssertTrue(
        app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 20))
      if scenario == "conversation-streaming" {
        XCTAssertTrue(
          app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Stream complete"))
            .firstMatch.waitForExistence(timeout: 20))
      }
      let scroll = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
      let notice = app.descendants(matching: .any)[
        scenario == "conversation-streaming" ? "transcript-stale" : "transcript-fresh"
      ].firstMatch
      let header = app.descendants(matching: .any)["conversation-top-bar"].firstMatch
      let nativeHeader = app.navigationBars.firstMatch
      let headerBottom = header.exists ? header.frame.maxY : nativeHeader.frame.maxY
      let top = max(scroll.frame.minY, headerBottom)
      let aligned = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          notice.exists && notice.frame.midY >= top
            && notice.frame.midY <= top + 80
        }, object: nil)
      XCTAssertEqual(
        XCTWaiter.wait(for: [aligned], timeout: 10), .completed,
        "Short transcript must not retain a blank refresh-control over-pull: \(scenario), top=\(top), notice=\(notice.frame)"
      )
      app.terminate()
    }
  }
}
