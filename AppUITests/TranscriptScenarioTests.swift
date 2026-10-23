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
    let older = element(app, "transcript-load-older")
    for _ in 0..<120 {
      if older.exists && older.isHittable { break }
      transcriptScroll(app).swipeDown(velocity: .fast)
    }
    XCTAssertTrue(older.exists && older.isHittable)
    XCTAssertTrue(
      element(app, "conversation-header").exists,
      "The eager header must return to the accessibility hierarchy")
    let anchor = element(app, "message-long-40")
    XCTAssertTrue(anchor.exists)
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
