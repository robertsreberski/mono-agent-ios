// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class ProviderScenarioTests: XCTestCase {
  func testDenseLight() { dense("light") }
  func testDenseDark() { dense("dark") }
  func testDeviceCodeLight() { deviceCode("light") }
  func testDeviceCodeDark() { deviceCode("dark") }
  func testSecretLight() { secret("light") }
  func testSecretDark() { secret("dark") }
  func testManualCodeLight() { manualCode("light") }
  func testManualCodeDark() { manualCode("dark") }
  func testSelectLight() { select("light") }
  func testSelectDark() { select("dark") }
  func testChecksLight() { checks("light") }
  func testChecksDark() { checks("dark") }
  func testStaleUsageLight() { stale("light") }
  func testStaleUsageDark() { stale("dark") }

  private func dense(_ appearance: String) {
    let app = launch("provider-auth-dense", appearance)
    WaitFor.label(element(app, "provider-auth-state-openai-codex"), contains: "Credential OK")
    WaitFor.label(element(app, "provider-auth-state-anthropic"), contains: "Needs action")
    reveal(app, "provider-auth-state-openai")
    WaitFor.label(element(app, "provider-auth-state-openai"), contains: "Not verified")
    reveal(app, "provider-refresh-usage", down: true)
    WaitFor.enabled(element(app, "provider-refresh-usage"))
    capture(app, "provider-auth-dense", appearance)
  }
  private func deviceCode(_ appearance: String) {
    let app = launch("provider-auth-device-code", appearance)
    tap(app, "provider-authenticate-openai-codex")
    reveal(app, "provider-device-code")
    WaitFor.label(element(app, "provider-device-code"), contains: "FLOCK-2048")
    WaitFor.enabled(element(app, "provider-refresh-usage"), false)
    WaitFor.enabled(element(app, "provider-check-access"), false)
    capture(app, "provider-auth-device-code", appearance)
    if appearance == "light" {
      tap(app, "provider-cancel-auth")
      WaitFor.label(element(app, "provider-auth-progress"), contains: "Waiting")
      tap(app, "provider-cancel-auth")
      WaitFor.absent(element(app, "provider-auth-flow"))
    }
  }
  private func secret(_ appearance: String) {
    let app = launch("provider-auth-secret", appearance)
    tap(app, "provider-authenticate-anthropic")
    reveal(app, "provider-prompt-secret")
    let field = app.secureTextFields["provider-prompt-secret"]
    WaitFor.element(field, "secure input with a non-empty frame") {
      !$0.frame.isEmpty && $0.isHittable
    }
    WaitFor.enabled(element(app, "provider-submit-once"), false)
    capture(app, "provider-auth-secret", appearance)
    if appearance == "light" {
      field.tap()
      field.typeText("fictional-input")
      tap(app, "provider-keyboard-done")
      tap(app, "provider-submit-once")
      WaitFor.absent(field)
      reveal(app, "provider-auth-progress")
      WaitFor.label(element(app, "provider-auth-progress"), contains: "succeeded")
      WaitFor.absent(app.alerts["Save Password"])
      tap(app, "provider-cancel-auth")
      WaitFor.absent(element(app, "provider-auth-flow"))
    }
  }
  private func manualCode(_ appearance: String) {
    let app = launch("provider-auth-manual-code", appearance)
    tap(app, "provider-authenticate-openai-codex")
    reveal(app, "provider-session-error")
    WaitFor.label(
      element(app, "provider-session-error"),
      contains: "Device sign-in is unavailable. Use browser paste-back.")
    tap(app, "provider-paste-back")
    reveal(app, "provider-prompt-text")
    WaitFor.label(element(app, "provider-prompt-text"), contains: "authorization code")
    capture(app, "provider-auth-manual-code", appearance)
    if appearance == "light" {
      let field = element(app, "provider-prompt-text")
      tap(app, "provider-prompt-text")
      field.typeText("fictional-code")
      tap(app, "provider-keyboard-done")
      tap(app, "provider-submit-once")
      WaitFor.absent(field)
      reveal(app, "provider-auth-progress")
      WaitFor.label(element(app, "provider-auth-progress"), contains: "succeeded")
    }
  }
  private func select(_ appearance: String) {
    let app = launch("provider-auth-select", appearance)
    tap(app, "provider-authenticate-anthropic")
    reveal(app, "provider-prompt-select")
    WaitFor.enabled(element(app, "provider-submit-once"), false)
    capture(app, "provider-auth-select", appearance)
    if appearance == "light" {
      tap(app, "provider-prompt-select")
      let option = app.buttons["North region"].firstMatch
      WaitFor.hittable(option)
      option.tap()
      WaitFor.enabled(element(app, "provider-submit-once"))
      tap(app, "provider-submit-once")
      reveal(app, "provider-prompt-text")
      WaitFor.label(element(app, "provider-prompt-text"), contains: "account label")
      tap(app, "provider-prompt-text")
      element(app, "provider-prompt-text").typeText("Fictional account")
      tap(app, "provider-keyboard-done")
      tap(app, "provider-submit-once")
      WaitFor.label(element(app, "provider-auth-progress"), contains: "succeeded")
    }
  }
  private func checks(_ appearance: String) {
    let app = launch("provider-checks", appearance)
    tap(app, "provider-check-access")
    // A completed check re-reads local auth evidence, without another vendor request.
    WaitFor.label(
      element(app, "provider-check-summary"), contains: "Checks complete: 1 of 3 passed")
    WaitFor.label(element(app, "provider-check-result-openai-codex"), contains: "Check passed")
    reveal(app, "provider-check-result-openai")
    WaitFor.label(element(app, "provider-check-result-openai"), contains: "Network error")
    reveal(app, "provider-refresh-usage", down: true)
    capture(app, "provider-checks", appearance)
  }
  private func stale(_ appearance: String) {
    let app = launch("provider-usage-stale", appearance)
    WaitFor.label(element(app, "provider-usage-last-known-openai-codex"), contains: "Last known")
    WaitFor.label(
      element(app, "provider-meter-openai-codex-weekly"), contains: "projected to run out")
    capture(app, "provider-usage-stale", appearance)
    if appearance == "light" {
      tap(app, "provider-refresh-usage")
      WaitFor.label(element(app, "provider-usage-feedback"), contains: "last known shown")
      WaitFor.enabled(element(app, "provider-refresh-usage"))
    }
  }

  func testBackgroundClearsSecretAndResumesByIDWithoutAutoFillSavePrompt() {
    let app = launch("provider-auth-secret", "light")
    tap(app, "provider-authenticate-anthropic")
    reveal(app, "provider-prompt-secret")
    let field = app.secureTextFields["provider-prompt-secret"]
    WaitFor.element(field, "hittable secure input with frame") {
      !$0.frame.isEmpty && $0.isHittable
    }
    field.tap()
    field.typeText("fictional-transient-input")
    XCUIDevice.shared.press(.home)
    app.activate()
    reveal(app, "provider-prompt-secret")
    WaitFor.element(field, "cleared secret after foreground GET resume") {
      ($0.value as? String) == "API key"
    }
    WaitFor.enabled(element(app, "provider-submit-once"), false)
    WaitFor.absent(app.alerts["Save Password"])
  }

  func testStoredOpenAITypeReplacementRequiresConfirmation() {
    let app = launch("provider-auth-dense", "light")
    reveal(app, "provider-authenticate-openai")
    tap(app, "provider-authenticate-openai")
    reveal(app, "provider-method-api_key_prompt")
    tap(app, "provider-method-api_key_prompt")
    let replace = app.buttons["Replace with API key"].firstMatch
    WaitFor.element(replace, "replacement confirmation with frame") {
      !$0.frame.isEmpty && $0.isHittable
    }
    replace.tap()
    reveal(app, "provider-prompt-text")
    WaitFor.hittable(element(app, "provider-prompt-text"))
  }

  // MARK: Frame-guarded waits and readiness (slow hosted VMs)
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func launch(_ scenario: String, _ appearance: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data", "--open-settings",
      "providers", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    WaitFor.element(element(app, "agent-settings-ready"), "settings ready") { !$0.frame.isEmpty }
    WaitFor.label(element(app, "provider-auth-state-openai-codex"), contains: "Credential OK")
    WaitFor.enabled(element(app, "provider-refresh-usage"))
    return app
  }
  private func reveal(_ app: XCUIApplication, _ id: String, down: Bool = false) {
    let target = element(app, id)
    let scroll = element(app, "agent-settings-ready")
    WaitFor.element(scroll, "settings scroll view with frame") { !$0.frame.isEmpty }
    for _ in 0..<7 {
      if target.exists && !target.frame.isEmpty && target.isHittable { break }
      let moveDown: Bool
      if target.exists && !target.frame.isEmpty {
        moveDown = target.frame.midY < scroll.frame.midY
      } else {
        moveDown = down
      }
      let start = scroll.coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.35 : 0.65))
      let end = scroll.coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.65 : 0.35))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    WaitFor.element(target, "hittable element with a non-empty frame") {
      !$0.frame.isEmpty && $0.isHittable
    }
  }
  private func tap(_ app: XCUIApplication, _ id: String) {
    reveal(app, id)
    let target = element(app, id)
    WaitFor.element(target, "enabled hittable control with frame") {
      $0.isEnabled && !$0.frame.isEmpty && $0.isHittable
    }
    target.tap()
  }
  private func capture(_ app: XCUIApplication, _ scenario: String, _ appearance: String) {
    let content = element(app, "providers-section")
    WaitFor.element(content, "rendered providers with a non-empty frame") { !$0.frame.isEmpty }
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
