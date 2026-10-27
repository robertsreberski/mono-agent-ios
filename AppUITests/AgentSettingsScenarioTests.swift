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
    WaitFor.element(pin, "enabled pin switch with a non-empty frame") {
      $0.isEnabled && !$0.frame.isEmpty
    }
    // The Switch element spans the whole labelled row; a centre tap can land on the label,
    // which a SwiftUI Toggle ignores. Tap the switch itself (trailing padding 14 + half of 51).
    pin.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: -40, dy: 0)).tap()
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
    XCTAssertTrue(element(app, "settings-model-option-sample:max").waitForExistence(timeout: 10))
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
      // Non-vacuous witness: this same header is reachable before settings covers it.
      WaitFor.hittable(element(app, "rename-conversation"))
      button.tap()
      waitForSettings(app)
      WaitFor.value(button, contains: "Expanded")
      WaitFor.hittable(element(app, "agent-settings-close"))
      // The covered conversation is retained but unreachable: transcript, composer, header.
      WaitFor.absent(element(app, "conversation-transcript"))
      WaitFor.absent(element(app, "composer-field"))
      WaitFor.absent(element(app, "rename-conversation"))
      WaitFor.hittable(element(app, "agent-strip"))  // the sidebar stays usable
      button.tap()  // a second press closes on a wide layout
      WaitFor.absent(element(app, "agent-settings-screen"))
      WaitFor.value(button, contains: "Collapsed")
      XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10))
      WaitFor.hittable(element(app, "rename-conversation"))
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

  // MARK: iPad round trips: the covered destination is retained, not remounted

  /// Settings covers a retained conversation: its quote, draft and staged sample files survive
  /// an open/close round trip. Staged uploads surviving also proves the conversation was not
  /// re-selected (selecting discards staged uploads).
  func testRoundTripKeepsQuoteDraftAndAttachments() throws {
    try XCTSkipUnless(isPad, "iPhone settings is a full-screen cover over the dashboard")
    let app = launch("composer-draft-attachments", "light")
    let field = element(app, "composer-field")
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    WaitFor.value(field, contains: "Draft kept from an earlier visit")
    element(app, "composer-attach").tap()
    XCTAssertTrue(element(app, "attach-samples").waitForExistence(timeout: 5))
    element(app, "attach-samples").tap()
    XCTAssertTrue(element(app, "attachment-field-notes.txt").waitForExistence(timeout: 10))
    let message = element(app, "message-sample-assistant")
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    message.press(forDuration: 1.2)
    let quote = app.buttons["Quote"].firstMatch
    XCTAssertTrue(quote.waitForExistence(timeout: 5))
    quote.tap()
    XCTAssertTrue(element(app, "quote-preview").waitForExistence(timeout: 5))
    let button = element(app, "agent-settings-button")
    button.tap()
    waitForSettings(app)
    WaitFor.absent(element(app, "quote-preview"))
    WaitFor.absent(field)
    element(app, "agent-settings-close").tap()
    WaitFor.absent(element(app, "agent-settings-screen"))
    XCTAssertTrue(element(app, "quote-preview").waitForExistence(timeout: 10), "quote kept")
    XCTAssertTrue(element(app, "attachment-field-notes.txt").exists, "staged file kept")
    XCTAssertTrue(element(app, "attachment-sample-photo.png").exists, "staged file kept")
    WaitFor.value(field, contains: "Draft kept from an earlier visit")
  }

  /// A hardware keyboard cannot reach the covered composer: typing and ⌘Return while
  /// settings is open neither edit nor send the invisible draft.
  func testCoveredComposerIgnoresHardwareKeyboard() throws {
    try XCTSkipUnless(isPad, "iPhone settings is a full-screen cover over the dashboard")
    let app = launch("composer-draft-attachments", "light")
    let field = element(app, "composer-field")
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    WaitFor.value(field, contains: "Draft kept from an earlier visit")
    field.tap()
    field.typeText(" Before settings.")
    WaitFor.value(field, contains: "Before settings.")
    let before = field.value as? String ?? ""
    element(app, "agent-settings-button").tap()
    waitForSettings(app)
    WaitFor.absent(field)
    app.typeKey("z", modifierFlags: [])
    app.typeKey("\t", modifierFlags: [])
    app.typeKey("q", modifierFlags: [])
    app.typeKey(.return, modifierFlags: .command)
    // The settings screen stays open and nothing was submitted while it covered the composer.
    XCTAssertTrue(element(app, "agent-settings-screen").exists)
    let sent = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Synthetic reply")
    ).firstMatch
    XCTAssertFalse(sent.waitForExistence(timeout: 3), "nothing was sent while covered")
    element(app, "agent-settings-close").tap()
    WaitFor.absent(element(app, "agent-settings-screen"))
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    WaitFor.value(field, contains: "Before settings.")
    XCTAssertEqual(field.value as? String, before, "the draft is unchanged")
    XCTAssertFalse(sent.exists, "nothing was sent after closing either")
  }

  /// After the first send from a new-conversation route, closing settings returns to the
  /// created conversation, not a blank new one.
  func testRoundTripAfterFirstSendReturnsToTheCreatedThread() throws {
    try XCTSkipUnless(isPad, "iPhone settings is a full-screen cover over the dashboard")
    let app = launch("composer-empty", "light")
    element(app, "new-conversation").tap()
    XCTAssertTrue(element(app, "composer-placeholder").waitForExistence(timeout: 10))
    let field = element(app, "composer-field")
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("Plan the sample launch")
    element(app, "composer-send").tap()
    let reply = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Synthetic reply: received “Plan the sample launch”")
    ).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 15))
    element(app, "agent-settings-button").tap()
    waitForSettings(app)
    WaitFor.absent(reply)
    element(app, "agent-settings-close").tap()
    WaitFor.absent(element(app, "agent-settings-screen"))
    XCTAssertTrue(reply.waitForExistence(timeout: 10), "the created conversation is shown")
    XCTAssertFalse(element(app, "composer-placeholder").exists, "not a blank new conversation")
  }

  /// Reselecting the conversation already underneath is an explicit choice: settings closes.
  func testReselectingTheCoveredConversationClosesSettings() throws {
    try XCTSkipUnless(isPad, "the sidebar is covered on iPhone")
    let app = launch("agent-settings", "light")
    let row = element(app, "running-row-t-atlas-launch")
    row.tap()
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 15))
    element(app, "agent-settings-button").tap()
    waitForSettings(app)
    WaitFor.absent(element(app, "conversation-transcript"))
    row.tap()
    WaitFor.absent(element(app, "agent-settings-screen"))
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
    WaitFor.value(element(app, "agent-settings-button"), contains: "Collapsed")
  }

  /// Switching agent in the sidebar retargets open settings to that agent and keeps it open.
  func testSwitchingAgentRetargetsOpenSettings() throws {
    try XCTSkipUnless(isPad, "the sidebar is covered on iPhone")
    let app = launch("agent-settings", "light")
    element(app, "running-row-t-atlas-launch").tap()
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 15))
    element(app, "agent-settings-button").tap()
    waitForSettings(app)
    WaitFor.label(element(app, "agent-settings-title"), contains: "Atlas Research")
    element(app, "agent-tile-agent-quill").tap()
    WaitFor.label(element(app, "agent-settings-title"), contains: "Quill Writer")
    XCTAssertTrue(element(app, "agent-settings-screen").exists, "settings stays open")
    WaitFor.value(element(app, "agent-settings-button"), contains: "Expanded")
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
    // Resolved once, outside the poll: accessibility queries can exceed the poll's deadline.
    let checkSidebar = screenshotChecksSidebar(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: checkSidebar)
      },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(screenshot, checkSidebar: checkSidebar))
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
