// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class AgentRestartScenarioTests: XCTestCase {
  func testIdleLight() { idle("light") }
  func testIdleDark() { idle("dark") }
  func testConfirmLight() { confirmation("light") }
  func testConfirmDark() { confirmation("dark") }
  func testProgressLight() { restart("agent-restart-progress", "light") }
  func testProgressDark() { restart("agent-restart-progress", "dark") }
  func testSuccessLight() { restart("agent-restart-success", "light") }
  func testSuccessDark() { restart("agent-restart-success", "dark") }
  func testFailureLight() { restart("agent-restart-failure", "light") }
  func testFailureDark() { restart("agent-restart-failure", "dark") }
  func testUncertainRequestNeedsAnotherConfirmation() {
    let app = launch("agent-restart-uncertain", "light")
    tap(app, "agent-restart-open-confirmation")
    tap(app, "agent-restart-confirm")
    WaitFor.label(
      element(app, "agent-restart-unknown"), contains: "Couldn't confirm the request was received")
    WaitFor.absent(element(app, "agent-restart-outcome"))
    tap(app, "agent-restart-open-confirmation")
    WaitFor.hittable(element(app, "agent-restart-confirm"))
    tap(app, "agent-restart-cancel")
    WaitFor.absent(element(app, "agent-restart-confirm"))
  }
  func testNotConfirmedIsNotSuccessOrFailure() {
    let app = launch("agent-restart-not-confirmed", "dark")
    tap(app, "agent-restart-open-confirmation")
    tap(app, "agent-restart-confirm")
    WaitFor.label(
      element(app, "agent-restart-outcome"), contains: "Restart not confirmed — check the agent")
    WaitFor.label(element(app, "agent-restart-last"), contains: "Not confirmed")
    WaitFor.absent(element(app, "agent-restart-progress"))
  }
  func testBackgroundAndReopenKeepKnownProgress() {
    let app = launch("agent-restart-progress", "light")
    tap(app, "agent-restart-open-confirmation")
    tap(app, "agent-restart-confirm")
    WaitFor.element(element(app, "agent-restart-progress"), "Restarting progress") {
      ($0.value as? String) == "Restarting"
    }
    XCUIDevice.shared.press(.home)
    app.activate()
    WaitFor.element(element(app, "agent-restart-progress"), "Restarting progress") {
      ($0.value as? String) == "Restarting"
    }
    let close =
      app.buttons["agent-settings-back"].exists ? "agent-settings-back" : "agent-settings-close"
    tap(app, close)
    tap(app, "agent-settings-button")
    reveal(app, "agent-restart-progress")
    WaitFor.element(element(app, "agent-restart-progress"), "Restarting progress") {
      ($0.value as? String) == "Restarting"
    }
    WaitFor.absent(element(app, "agent-restart-confirm"))
  }
  private func idle(_ appearance: String) {
    let app = launch("agent-restart", appearance)
    WaitFor.label(element(app, "agent-restart-last"), contains: "No recent restart")
    WaitFor.label(element(app, "agent-restart-running"), contains: "conversation")
    capture(app, "agent-restart", appearance)
  }
  private func confirmation(_ appearance: String) {
    let app = launch("agent-restart-confirm", appearance)
    tap(app, "agent-restart-open-confirmation")
    WaitFor.label(element(app, "agent-restart-title"), contains: "now?")
    WaitFor.label(
      element(app, "agent-restart-explanation"), contains: "will be interrupted (approximate)")
    WaitFor.element(element(app, "agent-restart-confirm"), "enabled confirmation with frame") {
      $0.isEnabled && !$0.frame.isEmpty && $0.isHittable
    }
    capture(app, "agent-restart-confirm", appearance)
    tap(app, "agent-restart-cancel")
    WaitFor.absent(element(app, "agent-restart-confirm"))
    WaitFor.hittable(element(app, "agent-restart-open-confirmation"))
    WaitFor.label(element(app, "agent-restart-last"), contains: "No recent restart")
  }
  private func restart(_ scenario: String, _ appearance: String) {
    let app = launch(scenario, appearance)
    tap(app, "agent-restart-open-confirmation")
    tap(app, "agent-restart-confirm")
    switch scenario {
    case "agent-restart-progress":
      WaitFor.element(element(app, "agent-restart-progress"), "Restarting progress") {
        ($0.value as? String) == "Restarting"
      }
      WaitFor.absent(element(app, "agent-restart-open-confirmation"))
    case "agent-restart-success":
      WaitFor.label(element(app, "agent-restart-title"), contains: "is back online")
      WaitFor.label(element(app, "agent-restart-explanation"), contains: "Restarted just now")
      WaitFor.absent(element(app, "agent-restart-last"))
    default:
      WaitFor.label(element(app, "agent-restart-outcome"), contains: "Restart failed")
      WaitFor.label(element(app, "agent-restart-last"), contains: "sample agent could not relaunch")
    }
    capture(app, scenario, appearance)
  }
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func launch(_ scenario: String, _ appearance: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data", "--open-settings",
      "agent", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    WaitFor.element(element(app, "agent-settings-ready"), "settings ready with frame") {
      !$0.frame.isEmpty
    }
    WaitFor.label(element(app, "agent-restart-title"), contains: "Restart")
    reveal(app, "agent-restart-open-confirmation")
    WaitFor.enabled(element(app, "agent-restart-open-confirmation"))
    return app
  }
  private func reveal(_ app: XCUIApplication, _ id: String) {
    let target = element(app, id)
    let scroll = element(app, "agent-settings-ready")
    WaitFor.element(scroll, "settings scroll view with frame") { !$0.frame.isEmpty }
    let bounds = scroll.frame
    for _ in 0..<7 {
      if target.exists {
        let frame = target.frame
        if !frame.isEmpty && bounds.contains(frame) && target.isHittable { break }
        let down = !frame.isEmpty && frame.midY < bounds.midY
        let start = scroll.coordinate(
          withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.65))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
      } else {
        scroll.swipeUp()
      }
    }
    WaitFor.element(target, "hittable element with non-empty visible frame") {
      let frame = $0.frame
      return !frame.isEmpty && bounds.contains(frame) && $0.isHittable
    }
  }
  private func tap(_ app: XCUIApplication, _ id: String) {
    let target = element(app, id)
    if id != "agent-settings-button" && id != "agent-settings-back" && id != "agent-settings-close"
    {
      reveal(app, id)
    }
    WaitFor.element(target, "enabled hittable control with frame") {
      !$0.frame.isEmpty && $0.isEnabled && $0.isHittable
    }
    target.tap()
  }
  private func capture(_ app: XCUIApplication, _ scenario: String, _ appearance: String) {
    WaitFor.element(element(app, "agent-restart-section"), "restart section with frame") {
      !$0.frame.isEmpty
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
    attachment.name = "synthetic-fixture__\(scenario)__\(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
