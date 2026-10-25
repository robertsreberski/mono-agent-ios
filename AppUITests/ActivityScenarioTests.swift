// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class ActivityScenarioTests: XCTestCase {
  func testJobsOpaque() { capture("conversation-jobs", "light", variant: "opaque") }
  func testContextOpaque() { capture("conversation-context", "light", variant: "opaque") }
  func testStackOpaque() { capture("conversation-job-stack", "light", variant: "opaque") }
  func testSubagentsOpaque() { capture("conversation-subagents", "light", variant: "opaque") }
  func testJobsLight() { capture("conversation-jobs", "light") }
  func testJobsDark() { capture("conversation-jobs", "dark") }
  func testJobsPlum() { capture("conversation-jobs", "dark", variant: "plum") }
  func testJobsAccessibility() { capture("conversation-jobs", "light", variant: "ax3") }
  func testStackLight() { capture("conversation-job-stack", "light") }
  func testStackOverCodeLight() { capture("conversation-job-stack", "light", variant: "bleed") }
  func testStackOverCodeDark() { capture("conversation-job-stack", "dark", variant: "bleed") }
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
  func testContextLargeLight() { capture("conversation-context", "light", variant: "large") }
  func testContextLargeDark() { capture("conversation-context", "dark", variant: "large") }
  func testContextOverMarkdownLight() { captureContextOver("conversation-markdown", "light") }
  func testContextOverMarkdownDark() { captureContextOver("conversation-markdown", "dark") }

  func testFailedJobCard() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-jobs", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    element(app, "job-stack").tap()
    let history = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "History,"))
      .firstMatch
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    for _ in 0..<12 {
      if history.isHittable { break }
      dragDock(dock, down: false)
    }
    XCTAssertTrue(history.isHittable)
    history.tap()
    dockReveal(app, "job-card-failed").tap()
    let refresh = dockReveal(app, "job-refresh-failed")
    XCTAssertTrue(refresh.isEnabled)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "synthetic-fixture__conversation-jobs__light__failed"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }

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
      // Phones: the web chat header replaces the system bar; iPad keeps the system bar.
      let bar = element(app, "conversation-top-bar")
      let top = (bar.exists ? bar.frame.maxY : app.navigationBars.firstMatch.frame.maxY) + 8
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
  /// Activity now lives in the composer dock (web layout): reveal cards inside the dock's own
  /// bounded scroll view, not the transcript.
  private func dockReveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    let target = dock.descendants(matching: .any)[id].firstMatch
    for _ in 0..<12 {
      if target.exists && target.isHittable { return target }
      guard dock.exists else { break }
      dragDock(dock, down: target.exists && target.frame.midY < dock.frame.minY)
    }
    XCTAssertTrue(
      target.exists && target.isHittable,
      "Missing dock control: \(id) dock=\(dock.exists ? dock.frame.debugDescription : "absent") target=\(target.exists ? target.frame.debugDescription : "absent")"
    )
    return target
  }
  private func capture(_ scenario: String, _ appearance: String, variant: String? = nil) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if variant == "opaque" { app.launchArguments += ["--fixture-opaque"] }
    if variant == "plum" { app.launchArguments += ["--fixture-theme", "plum"] }
    if variant == "ax3" {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    XCTAssertTrue(scroll(app).waitForExistence(timeout: 10))
    // Context sits beside the model selector and the job shelf above the input, as on the web.
    XCTAssertTrue(element(app, "context-display").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "composer").exists)
    XCTAssertFalse(
      element(app, "conversation-header").descendants(matching: .any)["context-display"].exists,
      "Activity is no longer in the conversation header")
    XCTAssertTrue(element(app, "conversation-header").exists)
    let title = element(app, "rename-conversation")
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "Native transcript sample")
    XCTAssertEqual(title.elementType, .button)
    if scenario != "conversation-context" {
      XCTAssertTrue(element(app, "composer-dock-scroll").exists)
      XCTAssertTrue(element(app, "job-stack").exists)
    }
    if scenario == "conversation-context" {
      element(app, "context-display").tap()
      let cost = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Known cost $0.42")
      ).firstMatch
      XCTAssertTrue(cost.waitForExistence(timeout: 10), "Unknown totals must preserve known spend")
      // The figure now mirrors the web: a large numerator and a smaller capacity label.
      XCTAssertTrue(app.staticTexts["84k"].firstMatch.exists)
      if variant == "ax3" {
        XCTAssertGreaterThanOrEqual(
          app.staticTexts["42%"].firstMatch.frame.minY,
          app.staticTexts["84k"].firstMatch.frame.maxY,
          "The percentage must have its own reading line at AX3")
      }
      XCTAssertTrue(app.staticTexts["/ 200k tokens"].firstMatch.exists)
      XCTAssertTrue(app.staticTexts["42%"].firstMatch.exists)
      if variant == "large" && UIDevice.current.userInterfaceIdiom == .phone {
        // The large detent: the system makes the sheet opaque; its content must still read.
        expandSheet(app, title: app.staticTexts["Context and cost"].firstMatch)
      }
    } else {
      if scenario == "conversation-job-stack" && variant == nil {
        // The closed shelf (current jobs inline, count chips) before it opens.
        let closed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closed.name = "synthetic-fixture__\(scenario)__\(appearance)__closed"
        closed.lifetime = .keepAlways
        add(closed)
      }
      element(app, "job-stack").tap()
      if scenario == "conversation-jobs" {
        dockReveal(app, "job-card-running").tap()
        dockReveal(app, "job-output-running").tap()
        XCTAssertTrue(
          app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Ready for the next stage")
          ).firstMatch.exists)
        XCTAssertTrue(element(app, "job-refresh-running").exists)
      } else if scenario == "conversation-job-stack" {
        dockReveal(app, "job-group-agent:garden-helper").tap()
        let current = dockReveal(app, "job-card-turn-5")
        XCTAssertTrue(current.label.contains("Current job"))
        XCTAssertTrue(
          app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "earlier turns"))
            .firstMatch.exists)
      } else {
        dockReveal(app, "job-group-peer:seed-bank").tap()
        dockReveal(app, "job-card-peer-pending").tap()
        let answer = dockReveal(app, "peer-question-answer")
        XCTAssertTrue(answer.isEnabled, "C8 wires Answer to the peer-question sheet")
        XCTAssertEqual(answer.label, "Answer")
        XCTAssertTrue(element(app, "subagent-progress").exists)
        XCTAssertTrue(element(app, "peer-question").exists)
        let peerShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        peerShot.name =
          "synthetic-fixture__peer-question__" + appearance + (variant.map { "__" + $0 } ?? "")
        peerShot.lifetime = .keepAlways
        add(peerShot)
        answer.tap()
        XCTAssertTrue(element(app, "peer-sheet").waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(element(app, "composer").waitForExistence(timeout: 10))
        if variant != "ax3" { _ = dockReveal(app, "subagent-progress") }
      }
    }
    let checkSidebar = screenshotChecksSidebar(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: checkSidebar)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(screenshot, checkSidebar: checkSidebar))
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }

  /// Sheet legibility over busy content: the context sheet opened above a rich transcript.
  private func captureContextOver(_ scenario: String, _ appearance: String) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    XCTAssertTrue(scroll(app).waitForExistence(timeout: 10))
    let trigger = element(app, "context-display")
    XCTAssertTrue(trigger.waitForExistence(timeout: 10))
    trigger.tap()
    XCTAssertTrue(app.staticTexts["Context and cost"].firstMatch.waitForExistence(timeout: 10))
    let checkSidebar = screenshotChecksSidebar(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: checkSidebar)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "synthetic-fixture__\(scenario)__\(appearance)__context"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }

  /// Drags a medium-detent sheet by its header to the large detent and waits for it to settle.
  private func expandSheet(_ app: XCUIApplication, title: XCUIElement) {
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
    let expanded = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in title.frame.minY < app.frame.height * 0.25 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 10), .completed)
  }

  /// A short, slow drag inside the dock's bounded scroll view (flicks overshoot it).
  private func dragDock(_ dock: XCUIElement, down: Bool) {
    let from = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
    let to = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
    from.press(forDuration: 0.05, thenDragTo: to)
  }

}
