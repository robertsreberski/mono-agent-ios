// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor
final class ScenarioTests: XCTestCase {
  func testConversationActionsLight() { captureConversationActions("light") }
  func testConversationActionsDark() { captureConversationActions("dark") }
  private func captureConversationActions(_ appearance: String) {
    capture(
      "conversation-actions", appearance,
      expect: ["conversation-actions"]
    ) { app in
      app.buttons["conversation-actions"].tap()
      for id in ["action-archive"] {
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
      }
    }
  }

  func testConversationActionsRenameCompactArchiveAndDeleteConfirmation() {
    let app = launch("conversation-actions")
    func open() {
      let button = app.buttons["conversation-actions"]
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      button.tap()
    }
    element(app, "rename-conversation").tap()
    let title = app.alerts.textFields["Title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    let previous = title.value as? String ?? ""
    title.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "Research")
    app.alerts.buttons["Save"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Research")).firstMatch
        .waitForExistence(timeout: 5))
    app.buttons["context-display"].tap()
    XCTAssertTrue(app.buttons["compact-context"].waitForExistence(timeout: 5))
    app.buttons["compact-context"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Compacted")).firstMatch
        .waitForExistence(timeout: 5))
    app.buttons["sheet-close"].tap()
    open()
    app.buttons["action-archive"].tap()
    XCTAssertTrue(app.alerts["Archive conversation"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
    open()
    app.buttons["action-archive"].tap()
    app.alerts.buttons["Archive conversation"].tap()
    XCTAssertTrue(app.buttons["archive-toggle"].waitForExistence(timeout: 5))
    app.buttons["archive-toggle"].tap()
    XCTAssertTrue(app.buttons["recent-row-t-atlas-launch"].waitForExistence(timeout: 5))
    app.buttons["recent-row-t-atlas-launch"].tap()
    open()
    let delete = app.buttons["action-delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    delete.tap()
    XCTAssertTrue(
      app.alerts.staticTexts[
        "Permanently delete this conversation and its attachments? This cannot be undone."
      ].exists)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["conversation-actions"].exists)
    open()
    app.buttons["action-delete"].tap()
    app.alerts.buttons["Permanently delete"].tap()
    XCTAssertTrue(app.buttons["archive-toggle"].waitForExistence(timeout: 5))
  }

  func testProjectPageLight() { captureProject("light") }
  func testProjectPageDark() { captureProject("dark") }
  func testProjectSettingsLight() { captureProject("light", settings: true) }
  func testProjectSettingsDark() { captureProject("dark", settings: true) }
  func testProjectCreateLight() { captureProject("light", create: true) }
  func testProjectCreateDark() { captureProject("dark", create: true) }
  private func captureProject(_ appearance: String, settings: Bool = false, create: Bool = false) {
    capture(
      create || settings ? "project-settings" : "project-page", appearance,
      expect: ["new-project"], variant: create ? "create" : settings ? "edit" : nil
    ) { app in
      if create {
        app.buttons["new-project"].tap()
      } else {
        XCTAssertTrue(self.scrollTo(app, "project-row-garden"))
        app.buttons["project-row-garden"].tap()
        XCTAssertTrue(self.element(app, "project-page").waitForExistence(timeout: 5))
        if settings { app.buttons["project-settings-button"].tap() }
      }
      if settings || create {
        XCTAssertTrue(app.textFields["project-name"].waitForExistence(timeout: 5))
      }
    }
  }

  func testProjectCreateEditAndDeleteCancelConfirm() {
    let app = launch("project-settings")
    app.buttons["new-project"].tap()
    let name = app.textFields["project-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Research notes")
    app.buttons["Blue project color"].tap()
    let context = app.textFields["project-context"]
    if context.exists {
      context.tap()
      context.typeText("Fictional shared briefing")
    }
    app.buttons["organize-save"].tap()
    XCTAssertTrue(element(app, "project-page").waitForExistence(timeout: 5))
    app.buttons["project-settings-button"].tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText(" updated")
    app.buttons["organize-save"].tap()
    XCTAssertTrue(app.staticTexts["Research notes updated"].waitForExistence(timeout: 5))
    app.buttons["project-settings-button"].tap()
    XCTAssertTrue(app.buttons["delete-project"].waitForExistence(timeout: 5))
    app.buttons["delete-project"].tap()
    XCTAssertTrue(
      app.alerts.staticTexts[
        "Delete this project? Its conversations move back to the agent. This cannot be undone."
      ].exists)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(name.exists)
    app.buttons["delete-project"].tap()
    app.alerts.buttons["Delete project"].tap()
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 5))
  }

  func testFidelityChatLight() {
    capture("fidelity-chat", "light", expect: ["message-garden-plan", "composer-field"])
  }
  func testFidelityChatDark() {
    capture("fidelity-chat", "dark", expect: ["message-garden-plan", "composer-field"])
  }
  func testFidelityDashboardLight() {
    capture(
      "fidelity-dashboard", "light",
      expect: ["agent-strip", "recent-row-t-atlas-launch", "recent-row-seedling-notes"])
  }
  func testFidelityDashboardDark() {
    capture(
      "fidelity-dashboard", "dark",
      expect: ["agent-strip", "recent-row-t-atlas-launch", "recent-row-seedling-notes"])
  }
  func testConnectionEmptyLight() { capture("connection-empty", "light") }
  func testConnectionEditorLight() { captureEditor("light") }
  func testConnectionEditorDark() { captureEditor("dark") }
  private func captureEditor(_ appearance: String) {
    capture("connection-empty", appearance, variant: "editor") { app in
      app.buttons["add-console"].tap()
      XCTAssertTrue(app.textFields["console-url"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons["connect-console"].exists)
    }
  }
  func testConnectionEmptyDark() { capture("connection-empty", "dark") }
  func testConnectionFailedLight() { capture("connection-failed", "light") }
  func testConnectionFailedDark() { capture("connection-failed", "dark") }
  // A connected console now opens on its dashboard (the golden fixture's single agent).
  func testConsoleOnlineLight() { capture("console-online", "light", expect: ["agent-strip"]) }
  func testConsoleOnlineDark() { capture("console-online", "dark", expect: ["agent-strip"]) }
  func testStoreScenariosLoad() {
    for scenario in ["store-offline", "store-streaming", "store-unread", "store-uncertain"] {
      let app = XCUIApplication()
      app.launchArguments = ["--scenario", scenario, "--reset-test-data"]
      app.launch()
      XCTAssertTrue(
        app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 15))
      app.terminate()
    }
  }
  func testConnectionFailedAccessibilityText() {
    capture("connection-failed", "light", accessibilityText: true)
  }

  // Dashboard scenarios (synthetic DashboardFixture data, fixed reference time).
  private static let populated = ["agent-strip", "agent-tile-agent-atlas", "running-section"]
  func testDashboardPopulatedLight() {
    capture("dashboard-populated", "light", expect: Self.populated)
  }
  func testDashboardPopulatedDark() {
    capture("dashboard-populated", "dark", expect: Self.populated)
  }
  func testDashboardPopulatedPlumDark() {
    capture(
      "dashboard-populated", "dark", expect: Self.populated, variant: "plum",
      arguments: ["--fixture-theme", "plum"])
  }
  func testDashboardPopulatedAccessibilityText() {
    capture("dashboard-populated", "light", accessibilityText: true, expect: ["agent-strip"])
  }
  func testDashboardEmptyLight() {
    capture("dashboard-empty", "light", expect: ["agent-strip", "recent-empty"])
  }
  func testDashboardEmptyDark() {
    capture("dashboard-empty", "dark", expect: ["agent-strip", "recent-empty"])
  }
  func testDashboardOfflineLight() {
    capture("dashboard-offline", "light", expect: ["banner-offline", "agent-strip"])
  }
  func testDashboardOfflineDark() {
    capture("dashboard-offline", "dark", expect: ["banner-offline", "agent-strip"])
  }
  func testDashboardSearchLight() {
    capture("dashboard-search", "light", expect: ["search-results", "search-row-t-atlas-notes"])
  }
  func testDashboardSearchDark() {
    capture("dashboard-search", "dark", expect: ["search-results", "search-row-t-atlas-notes"])
  }
  func testConversationPlaceholderLight() {
    capture(
      "conversation-placeholder", "light",
      expect: ["conversation-header", "conversation-run-state", "conversation-transcript"])
  }
  func testConversationPlaceholderDark() {
    capture(
      "conversation-placeholder", "dark",
      expect: ["conversation-header", "conversation-run-state", "conversation-transcript"])
  }

  // Dashboard behaviour (no screenshots): sections, navigation, archive, consoles sheet.
  func testDashboardSectionsAndControls() {
    let app = launch("dashboard-populated")
    for id in [
      "agent-strip", "agent-tile-agent-atlas", "agent-tile-agent-harbor", "agent-tile-agent-quill",
      "agent-offline-toggle", "running-section", "running-row-t-atlas-launch",
      "running-more-agent-atlas", "data-mode", "archive-toggle", "new-conversation",
      "consoles-button",
    ] {
      XCTAssertTrue(element(app, id).waitForExistence(timeout: 10), "missing \(id)")
    }
    XCTAssertFalse(element(app, "agent-tile-agent-dormant").exists, "offline agent folds away")
    XCTAssertTrue(
      element(app, "agent-tile-agent-atlas").label.contains("pinned, 3 running"),
      element(app, "agent-tile-agent-atlas").label)
    for id in ["projects-section", "recent-section", "recent-row-t-atlas-notes", "load-older"] {
      XCTAssertTrue(scrollTo(app, id), "missing \(id)")
    }
    XCTAssertTrue(element(app, "recent-row-t-atlas-notes").label.contains("unread"))
    XCTAssertFalse(element(app, "recent-row-t-atlas-digest").exists, "cron channels stay out")
    app.terminate()
  }

  func testDashboardOpensConversationNewConversationAndArchive() {
    let app = launch("dashboard-populated")
    XCTAssertTrue(element(app, "running-row-t-atlas-launch").waitForExistence(timeout: 10))
    element(app, "running-row-t-atlas-launch").tap()
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "conversation-run-state").label.contains("Running"))
    returnToDashboard(app)
    element(app, "new-conversation").tap()
    XCTAssertTrue(element(app, "composer-placeholder").waitForExistence(timeout: 10))
    returnToDashboard(app)
    element(app, "archive-toggle").tap()
    XCTAssertTrue(scrollTo(app, "recent-row-t-atlas-archived"))
    app.terminate()
  }

  /// iPhone: the web header's bare back chevron and the left-edge swipe both pop the
  /// conversation (the system bar, and with it the system back button, is hidden).
  func testConversationBackTapAndEdgeSwipeReturnToTheDashboard() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad keeps the split view")
    let app = launch("dashboard-populated")
    XCTAssertTrue(element(app, "running-row-t-atlas-launch").waitForExistence(timeout: 10))
    element(app, "running-row-t-atlas-launch").tap()
    let back = element(app, "conversation-back")
    XCTAssertTrue(back.waitForExistence(timeout: 10))
    XCTAssertEqual(back.label, "Back")
    XCTAssertTrue(back.isHittable)
    XCTAssertFalse(app.navigationBars.buttons["Back"].exists, "No system back button")
    back.tap()
    XCTAssertTrue(waitUntilHittable(element(app, "new-conversation")), "tap back pops")
    XCTAssertFalse(element(app, "conversation-transcript").exists)

    element(app, "running-row-t-atlas-launch").tap()
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
    // An edge-anchored drag from the screen's leading edge: the interactive pop gesture.
    let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
    edge.press(
      forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    XCTAssertTrue(waitUntilHittable(element(app, "new-conversation")), "edge swipe pops")
    XCTAssertFalse(element(app, "conversation-transcript").exists)
    app.terminate()
  }

  private func waitUntilHittable(_ target: XCUIElement) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in target.exists && target.isHittable }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  func testConsolesRemainReachableFromTheDashboard() {
    let app = launch("dashboard-populated")
    XCTAssertTrue(element(app, "consoles-button").waitForExistence(timeout: 10))
    element(app, "consoles-button").tap()
    XCTAssertTrue(element(app, "add-console").waitForExistence(timeout: 10))
    element(app, "consoles-done").tap()
    XCTAssertTrue(element(app, "agent-strip").waitForExistence(timeout: 10))
    app.terminate()
  }

  func testOfflineEmptyAndSearchScenarios() {
    var app = launch("dashboard-offline")
    XCTAssertTrue(element(app, "banner-offline").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "running-section").label.contains("last known"))
    app.terminate()
    app = launch("dashboard-empty")
    XCTAssertTrue(element(app, "recent-empty").waitForExistence(timeout: 10))
    XCTAssertFalse(element(app, "running-section").exists)
    app.terminate()
    app = launch("dashboard-search")
    XCTAssertTrue(element(app, "search-row-t-atlas-notes").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "search-row-t-atlas-notes").label.contains("3 matches"))
    XCTAssertFalse(element(app, "running-section").exists, "search replaces the sections")
    app.terminate()
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  private func launch(_ scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--reset-test-data", "-AppleLanguages", "(en)", "-AppleLocale",
      "en_US",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 15))
    return app
  }

  /// Lists are lazy: scroll until the row exists (bounded, never sleeps).
  private func scrollTo(_ app: XCUIApplication, _ id: String) -> Bool {
    for _ in 0..<8 {
      if element(app, id).waitForExistence(timeout: 1) { return true }
      // The dashboard list (the iPad sidebar, not the detail column under the screen centre).
      let list = app.scrollViews.matching(identifier: "dashboard-list").firstMatch
      if list.exists { list.swipeUp() } else { app.swipeUp() }
    }
    return element(app, id).exists
  }

  /// iPhone pops the pushed destination; iPad keeps the dashboard in the sidebar.
  private func returnToDashboard(_ app: XCUIApplication) {
    if !element(app, "new-conversation").isHittable {
      // Phones draw the web chat header with its own bare back chevron.
      let back = element(app, "conversation-back")
      if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }
    XCTAssertTrue(element(app, "new-conversation").waitForExistence(timeout: 10))
  }

  // DEBUG design catalog: every theme in both appearances, plus accessibility fallbacks.
  func testDesignCatalogEvergreenLight() { capture("design-catalog-evergreen", "light") }
  func testDesignCatalogEvergreenDark() { capture("design-catalog-evergreen", "dark") }
  func testDesignCatalogOceanLight() { capture("design-catalog-ocean", "light") }
  func testDesignCatalogOceanDark() { capture("design-catalog-ocean", "dark") }
  func testDesignCatalogPlumLight() { capture("design-catalog-plum", "light") }
  func testDesignCatalogPlumDark() { capture("design-catalog-plum", "dark") }
  func testDesignCatalogTerracottaLight() { capture("design-catalog-terracotta", "light") }
  func testDesignCatalogTerracottaDark() { capture("design-catalog-terracotta", "dark") }
  func testDesignCatalogAccessibilityLight() {
    capture("design-catalog-accessibility", "light", accessibilityText: true)
  }
  func testDesignCatalogAccessibilityDark() {
    capture("design-catalog-accessibility", "dark", accessibilityText: true)
  }
  func testDesignCatalogReduceTransparencyLight() {
    capture("design-catalog-reduce-transparency", "light")
  }
  func testDesignCatalogReduceTransparencyDark() {
    capture("design-catalog-reduce-transparency", "dark")
  }

  /// `accessibilityText` launches at Accessibility XL (AX3) so system chrome scales too.
  /// `expect` lists identifiers that must exist (default: the scenario name itself).
  private func capture(
    _ scenario: String, _ appearance: String, accessibilityText: Bool = false,
    expect: [String]? = nil, variant: String? = nil, arguments: [String] = [],
    prepare: ((XCUIApplication) -> Void)? = nil
  ) {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "--scenario", scenario, "--reset-test-data", "--appearance", appearance,
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      ] + arguments
    if accessibilityText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    app.launch()
    for identifier in expect ?? [scenario] {
      XCTAssertTrue(
        app.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 15),
        "missing \(identifier)")
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Ready"].exists, "Test readiness must not add visible text")
    prepare?(app)
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in screenshotHasContent(XCUIScreen.main.screenshot()) },
      object: nil
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [rendered], timeout: 10), .completed,
      "Accessibility is ready, but the screen has not rendered content")
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(screenshot), "Do not publish a blank startup frame")
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)"
      + (variant.map { "__" + $0 } ?? (accessibilityText ? "__ax3" : ""))
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }
}

/// A structural guard, not a pixel snapshot: ignore system bars and reject a flat blank frame.
func screenshotHasContent(_ screenshot: XCUIScreenshot) -> Bool {
  guard let image = screenshot.image.cgImage,
    let content = image.cropping(
      to: CGRect(
        x: 0, y: Double(image.height) * 0.15,
        width: Double(image.width), height: Double(image.height) * 0.7
      ))
  else { return false }
  var pixels = [UInt8](repeating: 0, count: 64 * 64)
  let drawn = pixels.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return false }
    context.draw(content, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    return true
  }
  return drawn && Int(pixels.max() ?? 0) - Int(pixels.min() ?? 0) > 25
}
