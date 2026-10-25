// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

/// Additional visual review captures; the existing scenario suites retain behavioural proof.
@MainActor final class AccessibilityReviewTests: XCTestCase {
  func testModelAX3() { review("composer-model-selector", variant: "ax3") }
  func testModelOpaque() { review("composer-model-selector", variant: "opaque") }
  func testSkillsAX3() { review("skill-browser", variant: "ax3") }
  func testSkillsOpaque() { review("skill-browser", variant: "opaque") }
  func testAskAX3() { review("conversation-ask-form", variant: "ax3") }
  func testAskOpaque() { review("conversation-ask-form", variant: "opaque") }
  func testRepliesAX3() { review("conversation-quick-replies", variant: "ax3") }
  func testRepliesOpaque() { review("conversation-quick-replies", variant: "opaque") }
  func testPeerAX3() { review("peer-question-sheet", variant: "ax3") }
  func testPeerOpaque() { review("peer-question-sheet", variant: "opaque") }
  func testConnectionEditorAX3() { review("connection-empty", variant: "editorax3") }
  func testConnectionEditorOpaque() { review("connection-empty", variant: "editoropaque") }

  private func review(_ scenario: String, variant: String) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario == "skill-browser" ? "composer-skill-picker" : scenario,
      "--appearance", "light", "--reset-test-data", "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
    ]
    if variant.hasSuffix("ax3") {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    } else {
      app.launchArguments += ["--fixture-opaque"]
    }
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    switch scenario {
    case "composer-model-selector":
      element(app, "composer-model").tap()
      XCTAssertTrue(app.staticTexts["Run settings"].waitForExistence(timeout: 5))
    case "skill-browser":
      element(app, "composer-skills").tap()
      XCTAssertTrue(element(app, "skill-browse-weekly-digest").waitForExistence(timeout: 5))
    case "connection-empty":
      app.buttons["add-console"].tap()
      XCTAssertTrue(app.textFields["console-url"].waitForExistence(timeout: 5))
    case "conversation-ask-form":
      XCTAssertTrue(element(app, "ask-card").waitForExistence(timeout: 10))
      let transcript = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
      for _ in 0..<8 {
        if app.staticTexts["Input needed"].isHittable { break }
        transcript.swipeDown()
      }
    case "peer-question-sheet":
      element(app, "job-stack").tap()
      let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
      for id in ["job-group-peer:seed-bank", "job-card-job-peer-sample", "peer-question-answer"] {
        let target = dock.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        for _ in 0..<12 {
          if target.isHittable { break }
          let down = target.frame.midY < dock.frame.minY
          dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
            .press(
              forDuration: 0.05,
              thenDragTo: dock.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3)))
        }
        XCTAssertTrue(target.isHittable)
        target.tap()
      }
      XCTAssertTrue(element(app, "peer-sheet").waitForExistence(timeout: 5))
    default:
      XCTAssertTrue(element(app, "quick-reply-Ship it").waitForExistence(timeout: 5))
    }
    let checkSidebar = screenshotChecksSidebar(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: checkSidebar)
      },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "synthetic-fixture__\(scenario)__light__\(variant)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }
}
