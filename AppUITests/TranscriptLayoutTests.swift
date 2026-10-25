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
      // The reading edge is the first transcript row: the stale notice, else the first message
      // (the web shows no "up to date" marker).
      let notice =
        scenario == "conversation-streaming"
        ? app.descendants(matching: .any)["transcript-stale"].firstMatch
        : app.descendants(matching: .any).matching(
          NSPredicate(
            format:
              "identifier BEGINSWITH 'message-' AND NOT (identifier IN {'message-copy', 'message-error', 'message-error-part'})"
          )
        ).firstMatch
      let header = app.descendants(matching: .any)["conversation-top-bar"].firstMatch
      let nativeHeader = app.navigationBars.firstMatch
      let headerBottom = header.exists ? header.frame.maxY : nativeHeader.frame.maxY
      let top = max(scroll.frame.minY, headerBottom)
      let aligned = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          // The row's top edge: a message row is taller than the notice it replaced.
          notice.exists && notice.frame.minY >= top - 1
            && notice.frame.minY <= top + 80
        }, object: nil)
      XCTAssertEqual(
        XCTWaiter.wait(for: [aligned], timeout: 10), .completed,
        "Short transcript must not retain a blank refresh-control over-pull: \(scenario), top=\(top), notice=\(notice.frame)"
      )
      app.terminate()
    }
  }
}
