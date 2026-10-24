// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class TranscriptScenarioTests: XCTestCase {
  func testTranscriptLight() { capture("conversation-transcript", "light") }
  func testShortTranscriptOpensAtFirstRow() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-transcript", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let first = element(app, "message-sample-user")
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.isHittable)
    XCTAssertGreaterThanOrEqual(first.frame.minY, transcriptScroll(app).frame.minY)
    XCTAssertFalse(element(app, "jump-to-latest").exists)
    app.terminate()
  }
  func testPullToRefreshBelowPhoneHeaderKeepsContentReachable() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-transcript", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let scroll = transcriptScroll(app)
    let first = element(app, "message-sample-user")
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
    start.press(
      forDuration: 0.1,
      thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
    let header = element(app, "conversation-header")
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        first.isHittable && first.frame.minY >= scroll.frame.minY
          && header.isHittable
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
    // A user drag can enter reading mode on phones; its Jump control must still resume following.
    let jump = element(app, "jump-to-latest")
    if jump.exists {
      jump.tap()
      let following = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in !jump.exists }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [following], timeout: 10), .completed)
    }
    XCTAssertTrue(element(app, "composer").isHittable)
    app.terminate()
  }

  func testTranscriptDark() { capture("conversation-transcript", "dark") }
  func testStreamingLight() { capture("conversation-streaming", "light") }
  func testStreamingDark() { capture("conversation-streaming", "dark") }
  func testToolsLight() { capture("conversation-tools", "light") }
  func testToolsDark() { capture("conversation-tools", "dark") }
  func testLongLight() { capture("conversation-long", "light") }
  func testLongDark() { capture("conversation-long", "dark") }
  func testMarkdownLight() { capture("conversation-markdown", "light") }
  func testMarkdownDark() { capture("conversation-markdown", "dark") }
  func testMarkdownPlumDark() { capture("conversation-markdown", "dark", variant: "plum") }
  func testMarkdownAccessibility() { capture("conversation-markdown", "light", variant: "ax3") }

  func testLongPagingPreservesMessageAnchorAndHeaderAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-long", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let scroll = transcriptScroll(app)
    // Establish user reading intent before using the native scroll-to-top gesture. Hundreds
    // of inertial swipes are slow and can expose an AX-hittable button behind the status bar.
    scroll.swipeDown(velocity: .fast)
    XCTAssertTrue(element(app, "jump-to-latest").waitForExistence(timeout: 5))
    let header = element(app, "conversation-header")
    let window = app.windows.firstMatch
    // iOS does not expose the status bar in this app's AX tree. Tap the top system region,
    // outside the Dynamic Island and over the detail column on a split-view tablet.
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: scroll.frame.maxX - window.frame.minX - 24,
        dy: (header.frame.minY - window.frame.minY) / 4)
    ).tap()
    let older = element(app, "transcript-load-older")
    let reachable = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard older.exists, older.isHittable, older.isEnabled, header.exists else { return false }
        let frame = older.frame
        return frame.minY >= max(scroll.frame.minY, header.frame.maxY)
          && app.windows.firstMatch.frame.contains(frame)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 20), .completed)
    XCTAssertTrue(header.exists, "The eager header must return to the accessibility hierarchy")
    let anchor = element(app, "message-long-40")
    XCTAssertTrue(anchor.exists && anchor.isHittable)
    older.tap()
    let paged = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        !self.element(app, "transcript-load-older").exists
          && self.element(app, "message-long-40").exists
      }, object: nil)
    // Paging is a network read plus layout; allow a loaded simulator to settle.
    XCTAssertEqual(XCTWaiter.wait(for: [paged], timeout: 20), .completed)
    XCTAssertTrue(
      anchor.isHittable,
      "Paging must retain the previously visible message, not jump to the new first row")
    XCTAssertTrue(element(app, "jump-to-latest").exists)
    element(app, "jump-to-latest").tap()
    XCTAssertTrue(element(app, "message-long-539").waitForExistence(timeout: 10))
    app.terminate()
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }
  private func capture(_ scenario: String, _ appearance: String, variant: String? = nil) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if variant == "plum" { app.launchArguments += ["--fixture-theme", "plum"] }
    if variant == "ax3" {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
    if scenario == "conversation-streaming" {
      let complete = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Stream complete")
      ).firstMatch
      XCTAssertTrue(
        complete.waitForExistence(timeout: 20), "Scripted deltas must reach a terminal write")
    } else if scenario == "conversation-tools" {
      XCTAssertTrue(element(app, "tool-cluster").waitForExistence(timeout: 10))
      element(app, "tool-cluster").tap()
      XCTAssertFalse(
        element(app, "jump-to-latest").exists, "Expanding activity is not scrolling away")
      let call = element(app, "tool-call-sample-tool-1")
      XCTAssertTrue(call.waitForExistence(timeout: 5))
      call.tap()
      let load = element(app, "tool-load-full")
      XCTAssertTrue(load.waitForExistence(timeout: 5))
      if !load.isHittable { transcriptScroll(app).swipeUp() }
      load.tap()
      XCTAssertTrue(
        app.staticTexts.containing(
          NSPredicate(format: "label CONTAINS %@", "Full synthetic output loaded")
        ).firstMatch.waitForExistence(timeout: 10))
    } else if scenario == "conversation-long" {
      XCTAssertTrue(element(app, "message-long-539").waitForExistence(timeout: 10))
      // User scrolls away: incoming geometry must not drag them back to the bottom.
      transcriptScroll(app).swipeDown()
      XCTAssertTrue(element(app, "jump-to-latest").waitForExistence(timeout: 5))
    } else if scenario == "conversation-markdown" {
      XCTAssertTrue(element(app, "code-copy").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "markdown-table").waitForExistence(timeout: 10))
    } else {
      XCTAssertTrue(element(app, "tool-cluster").waitForExistence(timeout: 10))
    }
    if scenario == "conversation-tools" {
      XCTAssertFalse(
        element(app, "jump-to-latest").exists, "Tools at the bottom must not offer Jump to latest")
    }
    if scenario == "conversation-transcript" || scenario == "conversation-streaming" {
      let idle = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          self.element(app, "conversation-run-state").label.contains("Idle")
        }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 5), .completed)
      XCTAssertTrue(element(app, "route-badge").label.contains("sample:large"))
    }
    XCTAssertFalse(
      element(app, "running-row-t-atlas-launch").exists, "Settled detail must not remain in Running"
    )
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in screenshotHasContent(XCUIScreen.main.screenshot()) },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(screenshot))
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }
  private func transcriptScroll(_ app: XCUIApplication) -> XCUIElement {
    app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
  }
}
