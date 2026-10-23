// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class TranscriptScenarioTests: XCTestCase {
  func testTranscriptLight() { capture("conversation-transcript", "light") }
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
