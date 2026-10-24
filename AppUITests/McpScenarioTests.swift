// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class McpScenarioTests: XCTestCase {
  func testReadyLight() { interactive("light") }
  func testReadyDark() { interactive("dark") }
  func testUnavailableLight() { unavailable("conversation-mcp-unavailable", "light") }
  func testUnavailableDark() { unavailable("conversation-mcp-unavailable", "dark") }
  func testLongTitleLight() { unavailable("conversation-mcp-long-title", "light") }
  func testLongTitleAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-mcp-long-title", "--appearance", "light", "--reset-test-data",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()
    XCTAssertTrue(element(app, "mcp-part-garden").waitForExistence(timeout: 20))
    wait(element(app, "mcp-status-garden"), contains: "unavailable")
    let action = app.buttons["mcp-action-garden"]
    XCTAssertGreaterThanOrEqual(action.frame.height, 44)
    XCTAssertLessThanOrEqual(action.frame.maxX, app.frame.maxX)
    XCTAssertTrue(element(app, "mcp-part-garden").label.contains("complete accessible app name"))
    capture(app, "conversation-mcp-long-title", "light", variant: "ax3")
  }
  func testLongTitleDark() { unavailable("conversation-mcp-long-title", "dark") }

  func testLongLinkConsentAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-mcp-app", "--appearance", "light", "--reset-test-data",
      "--mcp-long-link",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()
    // Cold launch: same fresh-WebKit startup bound as `interactive(_:)`.
    wait(element(app, "mcp-status-garden"), contains: "ready", timeout: 30)
    XCTAssertTrue(app.buttons["Open guide"].waitForExistence(timeout: 10))
    app.buttons["Open guide"].tap()
    let cancel = app.buttons["mcp-consent-cancel"]
    let allow = app.buttons["mcp-consent-allow"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    XCTAssertTrue(cancel.isHittable && allow.isHittable)
    XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
    XCTAssertGreaterThanOrEqual(allow.frame.height, 44)
    XCTAssertLessThanOrEqual(allow.frame.maxY, app.frame.maxY)
    XCTAssertEqual(element(app, "mcp-consent-host").label, "Destination host: garden.example")
    XCTAssertGreaterThanOrEqual(element(app, "mcp-consent-url").label.count, 8000)
    capture(app, "conversation-mcp-app", "light", variant: "linkax3")
    cancel.tap()
    wait(element(app, "mcp-native-counters"), contains: "Link POSTs: 0")
    showHeader(app)
    XCTAssertTrue(app.buttons["mcp-action-garden"].isEnabled)
    wait(element(app, "mcp-native-counters"), contains: "Link POSTs: 0")
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func launch(_ scenario: String, _ appearance: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--scenario", scenario, "--appearance", appearance, "--reset-test-data"]
    app.launch()
    XCTAssertTrue(element(app, "mcp-part-garden").waitForExistence(timeout: 20))
    return app
  }
  private func wait(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 15) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }
  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String? = nil
  ) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func showHeader(_ app: XCUIApplication) {
    let action = app.buttons["mcp-action-garden"]
    for _ in 0..<4 where !action.isHittable {
      let transcript = element(app, "conversation-transcript")
      transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.2)).press(
        forDuration: 0.05,
        thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.85)))
    }
    XCTAssertTrue(action.isHittable)
  }
  private func unavailable(_ scenario: String, _ appearance: String) {
    let app = launch(scenario, appearance)
    wait(element(app, "mcp-status-garden"), contains: "unavailable")
    XCTAssertTrue(app.buttons["mcp-action-garden"].label.hasPrefix("Reopen"))
    XCTAssertFalse(element(app, "mcp-web-garden").exists)
    if scenario == "conversation-mcp-long-title" {
      XCTAssertTrue(element(app, "mcp-part-garden").label.contains("complete accessible app name"))
    }
    capture(app, scenario, appearance)
  }
  private func interactive(_ appearance: String) {
    let scenario = "conversation-mcp-app"
    let app = launch(scenario, appearance)
    // A fresh WebKit process can need longer than an already-loaded app on hosted simulators.
    // Only this cold startup gets the larger bound; warm transitions retain the 15-second bound.
    wait(element(app, "mcp-status-garden"), contains: "ready", timeout: 30)
    XCTAssertTrue(app.buttons["Plan beds"].waitForExistence(timeout: 10))
    wait(element(app, "mcp-native-counters"), contains: "Native tool POSTs: 0")
    XCTAssertGreaterThanOrEqual(
      app.buttons["Plan beds"].frame.height, 43.5, "Native viewport must not shrink app hit targets"
    )
    capture(app, scenario, appearance)
    app.buttons["Plan beds"].tap()
    XCTAssertTrue(app.buttons["mcp-consent-cancel"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Plan beds"].isHittable)
    XCTAssertTrue(element(app, "mcp-consent-preview").exists)
    capture(app, scenario, appearance, variant: "consent")
    app.buttons["mcp-consent-cancel"].tap()
    XCTAssertTrue(app.buttons["Plan beds"].waitForExistence(timeout: 10))
    wait(element(app, "mcp-native-counters"), contains: "Native tool POSTs: 0")
    app.buttons["Plan beds"].tap()
    XCTAssertTrue(app.buttons["mcp-consent-cancel"].waitForExistence(timeout: 10))
    let sheet = element(app, "mcp-consent")
    sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["mcp-consent-cancel"])
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
    wait(element(app, "mcp-native-counters"), contains: "Native tool POSTs: 0")
    app.buttons["Plan beds"].tap()
    XCTAssertTrue(app.buttons["mcp-consent-allow"].waitForExistence(timeout: 10))
    app.buttons["mcp-consent-allow"].tap()
    wait(element(app, "mcp-native-counters"), contains: "Native tool POSTs: 1")
    app.buttons["Open guide"].tap()
    XCTAssertTrue(app.buttons["mcp-consent-cancel"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Open external link?"].exists)
    app.buttons["mcp-consent-cancel"].tap()
    wait(element(app, "mcp-native-counters"), contains: "Link POSTs: 0")
    let web = element(app, "mcp-web-garden")
    let originalHeight = web.frame.height
    app.buttons["Resize app"].tap()
    let resized = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in web.frame.height > originalHeight + 10 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 10), .completed)
    showHeader(app)
    app.buttons["mcp-action-garden"].tap()
    wait(element(app, "mcp-status-garden"), contains: "hidden")
    XCTAssertFalse(element(app, "mcp-web-garden").exists)
    capture(app, scenario, appearance, variant: "hidden")
    app.buttons["mcp-action-garden"].tap()
    wait(element(app, "mcp-status-garden"), contains: "ready")
    app.buttons["Close app"].tap()
    wait(element(app, "mcp-status-garden"), contains: "closed")
    XCTAssertTrue(app.buttons["mcp-action-garden"].label.hasPrefix("Reopen"))
    app.buttons["mcp-action-garden"].tap()
    wait(element(app, "mcp-status-garden"), contains: "ready")
    wait(element(app, "mcp-native-counters"), contains: "Native tool POSTs: 1")
    wait(element(app, "mcp-native-counters"), contains: "Link POSTs: 0")
  }
}
