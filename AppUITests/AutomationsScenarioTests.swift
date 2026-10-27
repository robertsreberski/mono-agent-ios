// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class AutomationsScenarioTests: XCTestCase {
  func testListLight() { list("automations", "light") }
  func testListDark() { list("automations", "dark") }
  func testFilteredLight() { list("automations-filtered", "light") }
  func testFilteredDark() { list("automations-filtered", "dark") }
  func testEmptyLight() { list("automations-empty", "light") }
  func testEmptyDark() { list("automations-empty", "dark") }
  func testOfflineLight() { list("automations-offline", "light") }
  func testOfflineDark() { list("automations-offline", "dark") }
  func testDegradedLight() { list("automations-degraded", "light") }
  func testDegradedDark() { list("automations-degraded", "dark") }
  func testHeaderLight() { header("light") }
  func testConfirmationLight() { confirmation("light") }
  func testConfigLight() { config("light") }
  func testHeaderAx3Light() { header("light", variant: "ax3") }
  func testHeaderOpaqueLight() { header("light", variant: "opaque") }
  func testConfigMediumLight() { config("light", variant: "medium") }
  func testConfigLargeLight() { config("light", variant: "large") }
  func testHeaderDark() { header("dark") }
  func testConfirmationDark() { confirmation("dark") }
  func testConfigDark() { config("dark") }
  func testHeaderAx3Dark() { header("dark", variant: "ax3") }
  func testHeaderOpaqueDark() { header("dark", variant: "opaque") }
  func testConfigMediumDark() { config("dark", variant: "medium") }
  func testConfigLargeDark() { config("dark", variant: "large") }
  func testListNavigationAndSharedSearch() {
    let app = launch("automations", "light")
    tap(app, "recent-chats")
    WaitFor.selected(element(app, "recent-chats"), timeout: 30)
    tap(app, "recent-automations")
    WaitFor.selected(element(app, "recent-automations"), timeout: 30)
    tap(app, "search-field")
    element(app, "search-field").typeText("no-such-sample")
    WaitFor.value(element(app, "search-field"), contains: "no-such-sample", timeout: 30)
    WaitFor.label(
      element(app, "automations-no-match"), contains: "No matching automations", timeout: 30)
    let search = app.keyboards.buttons["Search"]
    WaitFor.hittable(search, timeout: 30)
    search.tap()
    let clear = app.buttons["Clear search"]
    WaitFor.hittable(clear, timeout: 30)
    clear.tap()
    WaitFor.hittable(element(app, "automation-row-sample-digest"), timeout: 30)
    tap(app, "automation-row-sample-digest")
    WaitFor.value(element(app, "cron-header"), contains: "Collapsed", timeout: 30)
    tap(app, "cron-header")
    WaitFor.hittable(element(app, "cron-enabled"), timeout: 30)
    tap(app, "cron-enabled")
    WaitFor.label(element(app, "cron-notice"), contains: "applied", timeout: 30)
    WaitFor.label(element(app, "cron-enabled"), contains: "Enable", timeout: 30)
  }
  func testConfirmationAppliesAndCancelsWithoutAutomaticRetry() {
    let app = launch("cron-confirm", "light")
    expand(app)
    reveal(app, "cron-run-now")
    tap(app, "cron-run-now")
    WaitFor.hittable(element(app, "cron-confirm-submit"), timeout: 30)
    tap(app, "cron-confirm-cancel")
    WaitFor.absent(element(app, "cron-confirm-submit"), timeout: 30)
    tap(app, "cron-run-now")
    tap(app, "cron-confirm-submit")
    WaitFor.absent(element(app, "cron-confirm-submit"), timeout: 30)
    WaitFor.label(element(app, "cron-notice"), contains: "applied", timeout: 30)
  }
  func testControlsRecoverAfterBackgroundWithoutRenavigation() {
    let app = launch("cron-conversation", "light")
    expand(app)
    reveal(app, "cron-run-now")
    WaitFor.enabled(element(app, "cron-run-now"), true, timeout: 30)
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 30))
    app.activate()
    reveal(app, "cron-run-now")
    WaitFor.enabled(element(app, "cron-run-now"), true, timeout: 30)
    tap(app, "cron-run-now")
    WaitFor.label(element(app, "cron-notice"), contains: "applied", timeout: 30)
    WaitFor.enabled(element(app, "cron-enabled"), true, timeout: 30)
    tap(app, "cron-config")
    WaitFor.hittable(element(app, "cron-config-view"), timeout: 30)
  }
  func testOfflineSnapshotCannotRun() {
    let app = launch("automations-offline", "light")
    tap(app, "automation-row-sample-digest")
    expand(app)
    reveal(app, "cron-run-now")
    WaitFor.enabled(element(app, "cron-run-now"), false, timeout: 30)
    WaitFor.enabled(element(app, "cron-enabled"), false, timeout: 30)
    WaitFor.enabled(element(app, "cron-config"), false, timeout: 30)
  }
  private func list(_ scenario: String, _ appearance: String) {
    let app = launch(scenario, appearance)
    switch scenario {
    case "automations-empty": WaitFor.hittable(element(app, "automations-empty"), timeout: 30)
    case "automations-offline", "automations-degraded":
      WaitFor.hittable(element(app, "automations-snapshot"), timeout: 30)
      WaitFor.label(element(app, "automation-row-sample-digest"), contains: "Snapshot", timeout: 30)
    case "automations-filtered":
      WaitFor.hittable(element(app, "automation-row-sample-digest"), timeout: 30)
      WaitFor.absent(element(app, "automation-row-sample-cleanup"), timeout: 30)
    default: WaitFor.hittable(element(app, "automation-row-sample-digest"), timeout: 30)
    }
    capture(app, scenario, appearance)
  }
  private func header(_ appearance: String, variant: String? = nil) {
    let app = launch("cron-conversation", appearance, variant: variant)
    expand(app)
    reveal(app, "cron-header")
    capture(app, "cron-conversation", appearance, variant: variant)
  }
  private func confirmation(_ appearance: String) {
    let app = launch("cron-confirm", appearance)
    expand(app)
    reveal(app, "cron-run-now")
    tap(app, "cron-run-now")
    WaitFor.hittable(element(app, "cron-confirm-submit"), timeout: 30)
    capture(app, "cron-confirm", appearance)
  }
  private func config(_ appearance: String, variant: String? = nil) {
    let app = launch("cron-config", appearance)
    expand(app)
    reveal(app, "cron-config")
    tap(app, "cron-config")
    WaitFor.hittable(element(app, "cron-config-view"), timeout: 30)
    if variant == "large" {
      let sheet = element(app, "cron-config-view")
      WaitFor.element(sheet, timeout: 30, "sheet geometry") { !$0.frame.isEmpty }
      let frame = sheet.frame
      let origin = app.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 8))
        .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: 70)))
      WaitFor.element(sheet, timeout: 30, "large detent") { $0.frame.minY < frame.minY - 50 }
    }
    capture(app, "cron-config", appearance, variant: variant)
  }
  private func expand(_ app: XCUIApplication) {
    reveal(app, "cron-header")
    WaitFor.value(element(app, "cron-header"), contains: "Collapsed", timeout: 30)
    tap(app, "cron-header")
    WaitFor.value(element(app, "cron-header"), contains: "Expanded", timeout: 30)
  }
  private func launch(_ scenario: String, _ appearance: String, variant: String? = nil)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if variant == "ax3" {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    if variant == "opaque" { app.launchArguments += ["--fixture-opaque"] }
    app.launch()
    if scenario.hasPrefix("cron-") {
      WaitFor.value(element(app, "cron-header"), contains: "Collapsed", timeout: 30)
    } else {
      WaitFor.hittable(element(app, "automations-list"), timeout: 30)
    }
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
    let bounds = scroll.frame
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
    WaitFor.element(target, timeout: 30, "visible target") { !$0.frame.isEmpty && $0.isHittable }
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
