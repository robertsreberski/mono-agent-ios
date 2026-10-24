// SPDX-License-Identifier: GPL-3.0-only
import XCTest

@MainActor final class DashboardLayoutTests: XCTestCase {
  func testAccessibilitySidebarStaysVisibleBesideJobDisclosure() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-jobs", "--appearance", "light", "--reset-test-data",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(
      app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 20))
    let window = app.windows.firstMatch.frame
    guard window.width > 900 else { throw XCTSkip("Split-view sidebar regression is iPad-only") }
    let newConversation = app.buttons["new-conversation"].firstMatch
    XCTAssertTrue(newConversation.exists)
    XCTAssertTrue(newConversation.isHittable, "Sidebar header must remain onscreen")
    XCTAssertGreaterThanOrEqual(newConversation.frame.minY, window.minY)
    XCTAssertLessThan(newConversation.frame.maxY, window.midY)
    app.buttons["job-stack"].firstMatch.tap()
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    for identifier in ["job-card-running", "job-output-running"] {
      let control = dock.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      for _ in 0..<12 {
        if control.isHittable { break }
        let down = control.frame.midY < dock.frame.minY
        dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
          .press(
            forDuration: 0.05,
            thenDragTo: dock.coordinate(
              withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3)))
      }
      XCTAssertTrue(control.isHittable)
      control.tap()
    }
    XCTAssertTrue(newConversation.isHittable, "Job disclosure must not hide the sidebar")
    let snapshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    snapshot.lifetime = .keepAlways
    add(snapshot)
  }
}
