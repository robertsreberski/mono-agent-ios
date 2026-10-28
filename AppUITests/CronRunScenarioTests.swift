// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class CronRunScenarioTests: XCTestCase {
  func testRunListLight() { runs("light", detail: false) }
  func testRunListDark() { runs("dark", detail: false) }
  func testRunDetailLight() { runs("light", detail: true) }
  func testRunDetailDark() { runs("dark", detail: true) }
  func testRunCardLight() { card("light") }
  func testRunCardDark() { card("dark") }
  func testReplyRetryLight() { reply("light", variant: nil) }
  func testReplyRetryDark() { reply("dark", variant: nil) }
  func testReplyImportingLight() { reply("light", variant: "importing") }
  func testReplyImportingDark() { reply("dark", variant: "importing") }
  func testReplyContextLight() { reply("light", variant: "context") }
  func testReplyContextDark() { reply("dark", variant: "context") }
  func testRunPaginationAndActivityAndSessionCopy() {
    let app = launch("cron-run-detail", "light")
    reveal(app, "cron-run-history")
    tap(app, "cron-run-history")
    WaitFor.value(element(app, "cron-run-history"), contains: "Expanded", timeout: 30)
    WaitFor.hittable(element(app, "cron-history-run-sample"), timeout: 30)
    reveal(app, "cron-runs-older")
    tap(app, "cron-runs-older")
    WaitFor.hittable(element(app, "cron-history-run-sample-older"), timeout: 30)
    WaitFor.absent(element(app, "cron-runs-older"), timeout: 30)
    tap(app, "cron-history-run-sample-older")
    WaitFor.hittable(element(app, "cron-history-detail"), timeout: 30)
  }
  private func runs(_ appearance: String, detail: Bool) {
    let app = launch("cron-run-detail", appearance)
    reveal(app, "cron-run-history")
    tap(app, "cron-run-history")
    WaitFor.value(element(app, "cron-run-history"), contains: "Expanded", timeout: 30)
    WaitFor.hittable(element(app, "cron-history-run-sample"), timeout: 30)
    if detail {
      tap(app, "cron-history-run-sample")
      WaitFor.hittable(element(app, "cron-history-detail"), timeout: 30)
    }
    capture(app, "cron-run-detail", appearance, variant: detail ? nil : "list")
  }
  private func card(_ appearance: String) {
    let app = launch("cron-run-detail", appearance)
    reveal(app, "cron-run-details-run-sample")
    tap(app, "cron-run-details-run-sample")
    tap(app, "cron-session-run-sample")
    WaitFor.label(element(app, "cron-session-run-sample"), contains: "copied", timeout: 30)
    tap(app, "cron-activity-run-sample")
    WaitFor.label(
      element(app, "cron-activity-run-sample"), contains: "Refresh activity", timeout: 30)
    capture(app, "cron-run-detail", appearance, variant: "card")
  }
  private func reply(_ appearance: String, variant: String?) {
    let app = launch("cron-reply-retry", appearance, hold: variant == "importing")
    reveal(app, "cron-reply-run-sample")
    tap(app, "cron-reply-run-sample")
    WaitFor.label(element(app, "cron-reply-run-sample"), contains: "Retry Reply", timeout: 30)
    WaitFor.label(element(app, "cron-reply-message-run-sample"), contains: "unknown", timeout: 30)
    if let variant {
      tap(app, "cron-reply-run-sample")
      if variant == "importing" {
        WaitFor.label(element(app, "cron-reply-run-sample"), contains: "Importing", timeout: 30)
        WaitFor.enabled(element(app, "cron-reply-run-sample"), false, timeout: 30)
        capture(app, "cron-reply-retry", appearance, variant: variant)
        tap(app, "fixture-complete-cron-reply")
      }
      WaitFor.hittable(element(app, "cron-reply-context"), timeout: 30)
      // No tap: typing goes to the composer only if import requested focus.
      app.typeText("Fictional follow-up")
      WaitFor.value(element(app, "composer-field"), contains: "Fictional follow-up", timeout: 30)
      if variant == "context" {
        element(app, "conversation-transcript").swipeDown()
        WaitFor.hittable(element(app, "cron-context-failure"), timeout: 30)
        capture(app, "cron-reply-retry", appearance, variant: variant)
      }
    } else {
      capture(app, "cron-reply-retry", appearance)
    }
  }
  private func launch(_ scenario: String, _ appearance: String, hold: Bool = false)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if hold { app.launchArguments.append("--cron-hold-reply") }
    app.launch()
    WaitFor.value(element(app, "cron-header"), contains: "Collapsed", timeout: 30)
    return app
  }
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func tap(_ app: XCUIApplication, _ id: String) {
    let target = element(app, id)
    WaitFor.element(target, timeout: 30, "enabled hittable control") {
      $0.isEnabled && $0.isHittable && !$0.frame.isEmpty
    }
    target.tap()
  }
  private func reveal(_ app: XCUIApplication, _ id: String) {
    let target = element(app, id)
    let scroll = element(app, "conversation-transcript")
    WaitFor.element(scroll, timeout: 30, "transcript geometry") { !$0.frame.isEmpty }
    var bounds = scroll.frame
    let bar = element(app, "conversation-top-bar")
    let composer = element(app, "composer")
    WaitFor.element(composer, timeout: 30, "composer geometry") { !$0.frame.isEmpty }
    let top = bar.exists ? bar.frame.maxY + 8 : bounds.minY
    let bottom = composer.frame.minY - 8
    bounds = CGRect(
      x: bounds.minX, y: max(bounds.minY, top), width: bounds.width,
      height: max(1, bottom - max(bounds.minY, top)))
    for _ in 0..<8 {
      if target.exists {
        let frame = target.frame
        if !frame.isEmpty && bounds.contains(frame) && target.isHittable { break }
        if !frame.isEmpty && frame.midY < bounds.midY {
          scroll.swipeDown()
        } else {
          scroll.swipeUp()
        }
      } else {
        scroll.swipeDown()
      }
    }
    WaitFor.hittable(target, timeout: 30)
  }
  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String? = nil
  ) {
    let sidebar = screenshotChecksSidebar(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: sidebar)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    let image = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(image, checkSidebar: sidebar))
    let attachment = XCTAttachment(screenshot: image)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
