// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

/// Agent settings (pin, new-conversation run defaults, About), the dashboard header entry and
/// the notifications explainer. Synthetic per-instance fixtures; every assertion waits.
@MainActor final class AgentSettingsScenarioTests: XCTestCase {
  private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  // MARK: Page

  func testSettingsLight() {
    let app = openSettings("agent-settings", "light")
    WaitFor.label(element(app, "agent-settings-title"), contains: "Atlas Research")
    WaitFor.label(element(app, "agent-settings-status"), contains: "online")
    WaitFor.label(element(app, "settings-start-chip"), contains: "Agent config")
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Large · Medium")
    WaitFor.label(element(app, "settings-agent-config"), contains: "sample:large · medium")
    WaitFor.label(element(app, "settings-console-override"), contains: "None")
    XCTAssertFalse(element(app, "settings-use-agent-config").exists)
    WaitFor.label(element(app, "settings-about-source"), contains: "agent-atlas")
    WaitFor.label(element(app, "settings-about-supports"), contains: "Console restart")
    XCTAssertFalse(element(app, "settings-savebar").exists, "no draft, no save bar")
    capture(app, "agent-settings", "light")
    // Pin is independent of the run defaults and writes through the live console.
    let pin = element(app, "agent-settings-pin")
    WaitFor.value(pin, contains: "1")
    pin.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    WaitFor.value(pin, contains: "0")
    WaitFor.enabled(pin)
    close(app)
  }

  func testSettingsDark() {
    let app = openSettings("agent-settings", "dark")
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Large · Medium")
    capture(app, "agent-settings", "dark")
  }

  /// Opening a section is an explicit intent: the page scrolls to it.
  func testSectionIntentRevealsNewConversations() {
    let app = openSettings("agent-settings", "light", section: "new-conversations")
    WaitFor.hittable(element(app, "settings-section-new-conversations"))
    WaitFor.hittable(element(app, "settings-model-trigger"))
  }

  // MARK: Picker

  func testPickerLight() { picker("light") }
  func testPickerDark() { picker("dark") }

  private func picker(_ appearance: String) {
    let app = openSettings("agent-settings", appearance)
    let trigger = element(app, "settings-model-trigger")
    WaitFor.hittable(trigger)
    trigger.tap()
    XCTAssertTrue(element(app, "settings-picker").waitForExistence(timeout: 10))
    // Both catalog pages arrive: the second Grove page proves the cursor walk.
    XCTAssertTrue(element(app, "settings-model-option-grove:deep").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "settings-model-option-sample:max").exists)
    WaitFor.selected(element(app, "settings-model-option-default"))
    XCTAssertTrue(element(app, "settings-context-1m").exists, "the default route offers 1M")
    capture(app, "agent-settings", appearance, variant: "picker")
    guard appearance == "light" else { return }
    element(app, "settings-model-option-grove:fast").tap()
    WaitFor.selected(element(app, "settings-model-option-grove:fast"))
    WaitFor.absent(element(app, "settings-context-1m"))
    element(app, "settings-effort-option-low").tap()
    WaitFor.selected(element(app, "settings-effort-option-low"))
    element(app, "settings-picker-close").tap()
    WaitFor.absent(element(app, "settings-picker"))
    WaitFor.value(trigger, contains: "Grove Fast · Low")
    WaitFor.label(element(app, "settings-start-chip"), contains: "Unsaved")
    WaitFor.label(element(app, "settings-unsaved-summary"), contains: "Grove Fast · Low")
    WaitFor.label(element(app, "settings-console-override"), contains: "Set on save")
  }

  // MARK: Unsaved, save, reset

  func testUnsavedSaveAndResetLight() {
    let app = launch("agent-settings-unsaved", "light")
    let button = element(app, "agent-settings-button")
    WaitFor.hittable(button)
    WaitFor.value(button, contains: "Collapsed")
    button.tap()
    waitForSettings(app)
    if isPad { WaitFor.value(button, contains: "Expanded") }
    chooseSmallLow(app)
    WaitFor.label(element(app, "settings-start-chip"), contains: "Unsaved")
    WaitFor.label(element(app, "settings-unsaved-summary"), contains: "Sample Small · Low")
    if isPad {
      WaitFor.value(button, contains: "unsaved changes")
    }
    capture(app, "agent-settings-unsaved", "light")
    if !isPad {
      // The draft survives leaving settings; the header marks it.
      element(app, "agent-settings-back").tap()
      WaitFor.value(button, contains: "unsaved changes")
      button.tap()
      waitForSettings(app)
      WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Small · Low")
    }
    element(app, "settings-save").tap()
    WaitFor.label(element(app, "settings-start-chip"), contains: "Custom override")
    WaitFor.absent(element(app, "settings-savebar"))
    WaitFor.label(element(app, "settings-console-override"), contains: "Sample Small · Low")
    if isPad { WaitFor.value(button, lacks: "unsaved changes") }
    // "Use agent config" edits the draft; Save then removes the override.
    element(app, "settings-use-agent-config").tap()
    WaitFor.label(element(app, "settings-console-override"), contains: "Removed on save")
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Large · Medium")
    element(app, "settings-save").tap()
    WaitFor.label(element(app, "settings-start-chip"), contains: "Agent config")
    WaitFor.label(element(app, "settings-console-override"), contains: "None")
    WaitFor.absent(element(app, "settings-savebar"))
  }

  func testUnsavedDark() {
    let app = openSettings("agent-settings-unsaved", "dark")
    chooseSmallLow(app)
    WaitFor.label(element(app, "settings-unsaved-summary"), contains: "Sample Small · Low")
    capture(app, "agent-settings-unsaved", "dark")
  }

  func testSaveErrorLight() {
    let app = saveError("light")
    // Discard drops the draft without a write.
    element(app, "settings-discard").tap()
    WaitFor.absent(element(app, "settings-savebar"))
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Large · Medium")
    WaitFor.label(element(app, "settings-start-chip"), contains: "Agent config")
  }

  func testSaveErrorDark() { _ = saveError("dark") }

  private func saveError(_ appearance: String) -> XCUIApplication {
    let app = openSettings("agent-settings-save-error", appearance)
    chooseSmallLow(app)
    element(app, "settings-save").tap()
    WaitFor.label(
      element(app, "settings-save-error"),
      contains: "Couldn't save: Console request failed (HTTP 503).")
    WaitFor.label(element(app, "settings-save"), contains: "Retry")
    WaitFor.label(element(app, "settings-start-chip"), contains: "Unsaved")
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Sample Small · Low")
    capture(app, "agent-settings-save-error", appearance)
    return app
  }

  // MARK: Offline and degraded

  func testOfflineLight() { offline("light") }
  func testOfflineDark() { offline("dark") }

  private func offline(_ appearance: String) {
    let app = openSettings("agent-settings-offline", appearance)
    WaitFor.label(element(app, "agent-settings-status"), contains: "offline")
    WaitFor.label(element(app, "settings-offline-notice"), contains: "is offline")
    WaitFor.label(element(app, "settings-offline-note"), contains: "Reconnect Atlas Research")
    WaitFor.enabled(element(app, "settings-model-trigger"), false)
    // Pin needs only the console, not the agent.
    WaitFor.enabled(element(app, "agent-settings-pin"))
    capture(app, "agent-settings-offline", appearance)
  }

  func testDegradedLight() { degraded("light") }
  func testDegradedDark() { degraded("dark") }

  private func degraded(_ appearance: String) {
    let app = openSettings("agent-settings-degraded", appearance)
    WaitFor.label(element(app, "agent-settings-status"), contains: "degraded")
    WaitFor.label(element(app, "settings-start-chip"), contains: "Custom override")
    WaitFor.label(element(app, "settings-console-override"), contains: "Grove Fast · Low")
    WaitFor.value(element(app, "settings-model-trigger"), contains: "Grove Fast · Low")
    capture(app, "agent-settings-degraded", appearance)
    guard appearance == "light" else { return }
    element(app, "settings-use-agent-config").tap()
    WaitFor.label(element(app, "settings-console-override"), contains: "Removed on save")
    element(app, "settings-save").tap()
    WaitFor.label(element(app, "settings-start-chip"), contains: "Agent config")
  }

  // MARK: Accessibility review

  func testSettingsAX3Light() { review("light", variant: "ax3") }
  func testSettingsAX3Dark() { review("dark", variant: "ax3") }
  func testSettingsOpaqueLight() { review("light", variant: "opaque") }
  func testSettingsOpaqueDark() { review("dark", variant: "opaque") }

  private func review(_ appearance: String, variant: String) {
    let arguments =
      variant == "ax3"
      ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
      : ["--fixture-opaque"]
    let app = openSettings("agent-settings", appearance, arguments: arguments)
    WaitFor.hittable(element(app, "settings-model-trigger"))
    if variant == "opaque" {
      element(app, "settings-model-trigger").tap()
      XCTAssertTrue(
        element(app, "settings-model-option-grove:deep").waitForExistence(timeout: 10))
    }
    capture(app, "agent-settings", appearance, variant: variant)
  }

  // MARK: Header entry and route preservation

  /// Settings covers the current context without replacing it: closing returns to the same
  /// conversation (iPad) or dashboard (iPhone); on iPad the header button toggles it.
  func testHeaderEntryPreservesTheCurrentContext() {
    let app = launch("agent-settings", "light")
    let button = element(app, "agent-settings-button")
    if isPad {
      element(app, "running-row-t-atlas-launch").tap()
      XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 15))
      XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10))
      button.tap()
      waitForSettings(app)
      WaitFor.value(button, contains: "Expanded")
      WaitFor.hittable(element(app, "agent-settings-close"))
      // The covered conversation is retained but unreachable: transcript, composer, header.
      WaitFor.absent(element(app, "conversation-transcript"))
      WaitFor.absent(element(app, "composer-field"))
      WaitFor.absent(element(app, "conversation-run-state"))
      WaitFor.hittable(element(app, "agent-strip"))  // the sidebar stays usable
      button.tap()  // a second press closes on a wide layout
      WaitFor.absent(element(app, "agent-settings-screen"))
      WaitFor.value(button, contains: "Collapsed")
      XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10))
      // Selecting another conversation while settings is open closes it.
      button.tap()
      waitForSettings(app)
      element(app, "running-row-t-atlas-survey").tap()
      WaitFor.absent(element(app, "agent-settings-screen"))
    } else {
      WaitFor.hittable(button)
      button.tap()
      waitForSettings(app)
      WaitFor.absent(element(app, "agent-strip"))
      WaitFor.absent(element(app, "new-conversation"))
      element(app, "agent-settings-back").tap()
      WaitFor.absent(element(app, "agent-settings-screen"))
      WaitFor.hittable(element(app, "agent-strip"))
      WaitFor.value(button, contains: "Collapsed")
    }
  }

  // MARK: Notifications

  func testNotificationsLight() { notifications("notifications-explainer", "light") }
  func testNotificationsDark() { notifications("notifications-explainer", "dark") }
  func testNotificationsInsecureLight() { notifications("notifications-insecure", "light") }
  func testNotificationsInsecureDark() { notifications("notifications-insecure", "dark") }

  private func notifications(_ scenario: String, _ appearance: String) {
    let insecure = scenario == "notifications-insecure"
    let app = launch(scenario, appearance)
    let bell = element(app, "notifications-button")
    WaitFor.hittable(bell)
    WaitFor.value(bell, contains: insecure ? "Unavailable" : "web console")
    bell.tap()
    XCTAssertTrue(element(app, "notifications-explainer").waitForExistence(timeout: 10))
    WaitFor.label(
      element(app, insecure ? "notifications-http-copy" : "notifications-https-copy"),
      contains: insecure ? "unavailable on this HTTP console" : "come from the web console")
    capture(app, scenario, appearance)
    guard appearance == "light" else { return }
    element(app, "notifications-open-web").tap()
    WaitFor.label(
      element(app, "fixture-external-url"),
      contains: (insecure ? "http" : "https") + "://console.example.ts.net")
    element(app, "notifications-close").tap()
    WaitFor.absent(element(app, "notifications-explainer"))
  }

  // MARK: Helpers

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func launch(_ scenario: String, _ appearance: String, arguments: [String] = [])
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      ] + arguments
    app.launch()
    if !arguments.contains("--open-settings") {
      XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    }
    return app
  }

  /// DEBUG launch destination: settings opens once after fixture and Store readiness.
  private func openSettings(
    _ scenario: String, _ appearance: String, section: String = "index",
    arguments: [String] = []
  ) -> XCUIApplication {
    let app = launch(scenario, appearance, arguments: ["--open-settings", section] + arguments)
    waitForSettings(app)
    return app
  }

  private func waitForSettings(_ app: XCUIApplication) {
    XCTAssertTrue(element(app, "agent-settings-screen").waitForExistence(timeout: 20))
    XCTAssertTrue(element(app, "agent-settings-ready").waitForExistence(timeout: 20))
  }

  private func close(_ app: XCUIApplication) {
    element(app, isPad ? "agent-settings-close" : "agent-settings-back").tap()
    WaitFor.absent(element(app, "agent-settings-screen"))
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 10))
  }

  private func chooseSmallLow(_ app: XCUIApplication) {
    let trigger = element(app, "settings-model-trigger")
    WaitFor.hittable(trigger)
    trigger.tap()
    let small = element(app, "settings-model-option-sample:small")
    XCTAssertTrue(small.waitForExistence(timeout: 10))
    small.tap()
    WaitFor.selected(small)
    element(app, "settings-effort-option-low").tap()
    WaitFor.selected(element(app, "settings-effort-option-low"))
    element(app, "settings-picker-close").tap()
    WaitFor.absent(element(app, "settings-picker"))
    WaitFor.value(trigger, contains: "Sample Small · Low")
  }

  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String? = nil
  ) {
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in screenshotHasContent(XCUIScreen.main.screenshot()) },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
