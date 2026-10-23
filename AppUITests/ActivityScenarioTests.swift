// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class ActivityScenarioTests: XCTestCase {
  func testJobsLight() { capture("conversation-jobs", "light") }
  func testJobsDark() { capture("conversation-jobs", "dark") }
  func testJobsPlum() { capture("conversation-jobs", "dark", variant: "plum") }
  func testJobsAccessibility() { capture("conversation-jobs", "light", variant: "ax3") }
  func testStackLight() { capture("conversation-job-stack", "light") }
  func testStackDark() { capture("conversation-job-stack", "dark") }
  func testStackPlum() { capture("conversation-job-stack", "dark", variant: "plum") }
  func testStackAccessibility() { capture("conversation-job-stack", "light", variant: "ax3") }
  func testSubagentsLight() { capture("conversation-subagents", "light") }
  func testSubagentsDark() { capture("conversation-subagents", "dark") }
  func testSubagentsPlum() { capture("conversation-subagents", "dark", variant: "plum") }
  func testSubagentsAccessibility() { capture("conversation-subagents", "light", variant: "ax3") }
  func testContextLight() { capture("conversation-context", "light") }
  func testContextDark() { capture("conversation-context", "dark") }
  func testContextPlum() { capture("conversation-context", "dark", variant: "plum") }
  func testContextAccessibility() { capture("conversation-context", "light", variant: "ax3") }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }
  private func scroll(_ app: XCUIApplication) -> XCUIElement {
    app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
  }
  private func reveal(_ app: XCUIApplication, _ id: String, towardHeader: Bool = false)
    -> XCUIElement
  {
    let target = element(app, id)
    for _ in 0..<24 {
      let top = app.navigationBars.firstMatch.frame.maxY + 8
      let jump = element(app, "jump-to-latest")
      let bottom = jump.exists ? jump.frame.minY - 8 : scroll(app).frame.maxY - 34
      if target.exists {
        let middle = target.frame.midY
        if target.isHittable && middle >= top && middle <= bottom { return target }
        if middle < top { scroll(app).swipeDown() } else { scroll(app).swipeUp() }
      } else if towardHeader {
        scroll(app).swipeDown()
      } else {
        scroll(app).swipeUp()
      }
    }
    XCTAssertTrue(target.exists && target.isHittable, "Missing visible control: " + id)
    return target
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
    XCTAssertTrue(scroll(app).waitForExistence(timeout: 10))
    _ = reveal(app, "context-display", towardHeader: true)
    XCTAssertTrue(element(app, "conversation-header").exists)
    XCTAssertTrue(app.staticTexts["Native transcript sample"].firstMatch.exists)
    if scenario != "conversation-context" { XCTAssertTrue(element(app, "job-stack").exists) }
    if scenario == "conversation-context" {
      reveal(app, "context-display", towardHeader: true).tap()
      let cost = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Known cost $0.42")
      ).firstMatch
      XCTAssertTrue(cost.waitForExistence(timeout: 10), "Unknown totals must preserve known spend")
      XCTAssertTrue(
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "84k / 200k tokens"))
          .firstMatch.exists)
    } else {
      reveal(app, "job-stack", towardHeader: true).tap()
      if scenario == "conversation-jobs" {
        reveal(app, "job-card-running").tap()
        reveal(app, "job-output-running").tap()
        XCTAssertTrue(
          app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Ready for the next stage")
          ).firstMatch.exists)
        XCTAssertTrue(element(app, "job-refresh-running").exists)
      } else if scenario == "conversation-job-stack" {
        reveal(app, "job-group-agent:garden-helper").tap()
        let current = reveal(app, "job-card-turn-5")
        XCTAssertTrue(current.label.contains("Current job"))
        XCTAssertTrue(
          app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "earlier turns"))
            .firstMatch.exists)
      } else {
        reveal(app, "job-group-peer:seed-bank").tap()
        reveal(app, "job-card-peer-pending").tap()
        let answer = reveal(app, "peer-question-answer")
        XCTAssertFalse(answer.isEnabled)
        XCTAssertTrue(answer.label.contains("coming in composer"))
        XCTAssertTrue(element(app, "subagent-progress").exists)
        XCTAssertTrue(element(app, "peer-question").exists)
        if variant != "ax3" { _ = reveal(app, "subagent-progress", towardHeader: true) }
      }
    }
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot())
      }, object: nil)
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
}
