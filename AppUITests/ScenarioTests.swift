// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor
final class ScenarioTests: XCTestCase {
  private func assertEventually(
    _ element: XCUIElement, _ predicate: NSPredicate,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let expected = XCTNSPredicateExpectation(predicate: predicate, object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expected], timeout: 5), .completed,
      "Expected \(predicate)", file: file, line: line)
  }

  private func swipePicker(_ app: XCUIApplication, _ id: String) {
    let menu = element(app, id)
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(menu.frame.width, 0)
    XCTAssertGreaterThan(menu.frame.height, 0)
    // Popover UIScrollViews report an empty AX visible-frame on this runtime.
    // A real finger drag inside the measured viewport still exercises native scrolling.
    menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(
      forDuration: 0.05,
      thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
  }

  func testArchivedSearchResultOpensColdWithoutNavigatingAway() {
    let app = launch("organize-archived-search")
    let search = app.textFields["search-field"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Archived cold note")
    let hit = app.buttons["search-row-cold-archived"]
    XCTAssertTrue(hit.waitForExistence(timeout: 5))
    hit.tap()
    let title = app.buttons["rename-conversation"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    assertEventually(title, NSPredicate(format: "label == %@", "Archived cold note"))
    app.buttons["conversation-actions"].tap()
    XCTAssertTrue(app.buttons["action-archive"].waitForExistence(timeout: 5))
    assertEventually(
      app.buttons["action-archive"], NSPredicate(format: "label == %@", "Restore conversation"))
  }
  func testLongTagAndProjectPickersAtAccessibilitySize() {
    let app = launch("organize-long", accessibilityText: true)
    func reach(_ id: String, in menu: String) -> XCUIElement {
      let target = app.buttons[id]
      for _ in 0..<18 where !target.isHittable { self.swipePicker(app, menu) }
      XCTAssertTrue(target.isHittable)
      return target
    }
    app.buttons["conversation-tags"].tap()
    reach("tag-menu-label-30", in: "tag-picker-scroll").tap()
    assertEventually(
      app.buttons["conversation-tags"], NSPredicate(format: "value == %@", "Label 30"))
    app.buttons["conversation-tags"].tap()
    reach("edit-tags", in: "tag-picker-scroll").tap()
    reach("tag-menu-label-30", in: "tag-picker-scroll").tap()
    XCTAssertTrue(app.textFields["tag-name"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    app.buttons["conversation-tags"].tap()
    reach("new-tag", in: "tag-picker-scroll").tap()
    XCTAssertTrue(app.textFields["tag-name"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    app.buttons["conversation-actions"].tap()
    app.buttons["action-project"].tap()
    reach("assign-project-collection-12", in: "project-picker-scroll").tap()
    XCTAssertTrue(app.staticTexts["Collection 12"].waitForExistence(timeout: 5))
  }

  func testTagLongMenuLight() { captureLongRegistry("light", projects: false) }
  func testTagLongMenuDark() { captureLongRegistry("dark", projects: false) }
  func testProjectLongPickerLight() { captureLongRegistry("light", projects: true) }
  func testProjectLongPickerDark() { captureLongRegistry("dark", projects: true) }
  private func captureLongRegistry(_ appearance: String, projects: Bool) {
    capture(
      "organize-long", appearance, accessibilityText: true, expect: ["conversation-actions"],
      variant: projects ? "projectsax3" : "tagsax3"
    ) { app in
      if projects {
        app.buttons["conversation-actions"].tap()
        app.buttons["action-project"].tap()
      } else {
        app.buttons["conversation-tags"].tap()
      }
      let target = app.buttons[projects ? "assign-project-collection-12" : "new-tag"]
      let menu = projects ? "project-picker-scroll" : "tag-picker-scroll"
      for _ in 0..<18 where !target.isHittable { self.swipePicker(app, menu) }
      XCTAssertTrue(target.isHittable)
    }
  }

  func testWakeNewLight() { captureWake("wake-new", "light") }
  func testWakeNewDark() { captureWake("wake-new", "dark") }
  func testWakeOnceLight() { captureWake("wake-once", "light") }
  func testWakeOnceDark() { captureWake("wake-once", "dark") }
  func testWakeWeeklyLight() { captureWake("wake-weekly", "light") }
  func testWakeWeeklyDark() { captureWake("wake-weekly", "dark") }
  func testWakeConflictLight() { captureWake("wake-conflict", "light", conflict: true) }
  func testWakeConflictDark() { captureWake("wake-conflict", "dark", conflict: true) }
  func testWakeStatusLight() {
    capture("wake-once", "light", expect: ["conversation-header"], variant: "status")
  }
  func testWakeStatusDark() {
    capture("wake-once", "dark", expect: ["conversation-header"], variant: "status")
  }
  private func openWake(_ app: XCUIApplication) {
    app.buttons["conversation-actions"].tap()
    XCTAssertTrue(app.buttons["action-wake"].waitForExistence(timeout: 5))
    app.buttons["action-wake"].tap()
    XCTAssertTrue(app.segmentedControls["wake-kind"].waitForExistence(timeout: 5))
  }
  private func scrollWake(_ app: XCUIApplication, to target: XCUIElement, down: Bool = false) {
    for _ in 0..<5 where !target.isHittable {
      if down {
        element(app, "wake-scroll").swipeDown()
      } else {
        element(app, "wake-scroll").swipeUp()
      }
    }
    XCTAssertTrue(target.isHittable)
  }
  private func saveWake(_ app: XCUIApplication) {
    let save = app.buttons["organize-save"]
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: save)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    save.tap()
  }
  private func captureWake(_ scenario: String, _ appearance: String, conflict: Bool = false) {
    capture(scenario, appearance, expect: ["conversation-actions"]) { app in
      self.openWake(app)
      if conflict {
        let compact = app.switches["wake-compact-first"]
        self.scrollWake(app, to: compact)
        compact.tap()
        self.saveWake(app)
        let reload = app.buttons["wake-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5))
        self.scrollWake(app, to: reload, down: true)
      }
    }
  }
  func testWakeCreateWeeklyPauseResumeAndDeleteConfirmation() {
    let app = launch("wake-new")
    openWake(app)
    app.segmentedControls["wake-kind"].buttons["Weekly"].tap()
    app.buttons["wake-day-1"].tap()
    app.buttons["wake-add-time"].tap()
    XCTAssertTrue(app.buttons["wake-remove-time-1"].waitForExistence(timeout: 5))
    app.buttons["wake-remove-time-1"].tap()
    let compact = app.switches["wake-compact-first"]
    scrollWake(app, to: compact)
    compact.tap()
    saveWake(app)
    XCTAssertTrue(element(app, "wake-editor").waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["conversation-actions"].waitForExistence(timeout: 5))
    openWake(app)
    let toggle = app.buttons["wake-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    toggle.tap()
    XCTAssertTrue(app.buttons["Resume schedule"].waitForExistence(timeout: 5))
    toggle.tap()
    XCTAssertTrue(app.buttons["Pause schedule"].waitForExistence(timeout: 5))
    let delete = app.buttons["delete-wake"]
    scrollWake(app, to: delete)
    delete.tap()
    XCTAssertTrue(app.alerts["Delete this schedule?"].waitForExistence(timeout: 5))
    app.alerts.buttons["Keep schedule"].tap()
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    delete.tap()
    app.alerts.buttons["Delete"].tap()
    XCTAssertTrue(app.buttons["conversation-actions"].waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "wake-editor").waitForNonExistence(timeout: 5))
    openWake(app)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH %@", "New schedule")
      ).firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["delete-wake"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["wake-toggle"].waitForNonExistence(timeout: 5))
  }
  func testWakeChangedElsewhereLoadsLatestAndKeepsEditorOpen() {
    let app = launch("wake-conflict")
    openWake(app)
    let compact = app.switches["wake-compact-first"]
    scrollWake(app, to: compact)
    compact.tap()
    saveWake(app)
    let reload = app.buttons["wake-reload"]
    guard reload.waitForExistence(timeout: 5) else {
      XCTFail(app.debugDescription)
      return
    }
    scrollWake(app, to: reload, down: true)
    reload.tap()
    XCTAssertTrue(app.staticTexts["Scheduled wake-up"].waitForExistence(timeout: 5))
    let save = app.buttons["organize-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    assertEventually(save, NSPredicate(format: "exists == true AND enabled == false"))
  }

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
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count)
        + "Orchard outline updated")
    app.alerts.buttons["Save"].tap()
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(
          format: "identifier == %@ AND label == %@", "rename-conversation",
          "Orchard outline updated")
      ).firstMatch.waitForExistence(timeout: 5))
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
      ].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["conversation-actions"].waitForExistence(timeout: 5))
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
        if settings {
          app.buttons["project-settings-button"].tap()
        } else if UIDevice.current.userInterfaceIdiom == .pad {
          let row = app.buttons["project-member-t-atlas-launch"]
          XCTAssertTrue(row.waitForExistence(timeout: 5))
          row.tap()
          XCTAssertEqual(
            XCTWaiter.wait(
              for: [
                XCTNSPredicateExpectation(
                  predicate: NSPredicate(format: "selected == true"), object: row)
              ], timeout: 5), .completed)
        }
      }
      if settings || create {
        XCTAssertTrue(app.textFields["project-name"].waitForExistence(timeout: 5))
      }
    }
  }

  func testProjectMemberKeepsProjectNavigation() {
    let app = launch("project-page")
    app.buttons["project-row-garden"].tap()
    let row = app.buttons["project-member-t-atlas-launch"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    XCTAssertTrue(element(app, "conversation-header").waitForExistence(timeout: 5))
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCTAssertTrue(app.buttons["project-settings-button"].waitForExistence(timeout: 5))
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "selected == true"), object: row)
          ], timeout: 5), .completed)
    } else {
      app.buttons["conversation-back"].tap()
      XCTAssertTrue(app.buttons["project-settings-button"].waitForExistence(timeout: 5))
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
    if context.waitForExistence(timeout: 5) {
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
      ].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    app.buttons["delete-project"].tap()
    app.alerts.buttons["Delete project"].tap()
    XCTAssertTrue(self.element(app, "project-settings").waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["project-row-project-created-1"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["project-row-garden"].waitForExistence(timeout: 5))
  }

  func testTagMenuLight() { captureTags("light") }
  func testTagMenuDark() { captureTags("dark") }
  func testTagSettingsLight() { captureTags("light", settings: true) }
  func testTagSettingsDark() { captureTags("dark", settings: true) }
  func testTagCreateLight() { captureTags("light", create: true) }
  func testTagCreateDark() { captureTags("dark", create: true) }
  private func captureTags(_ appearance: String, settings: Bool = false, create: Bool = false) {
    capture(
      create || settings ? "tag-settings" : "tag-menu", appearance,
      expect: ["conversation-tags"], variant: create ? "create" : settings ? "edit" : nil
    ) { app in
      app.buttons["conversation-tags"].tap()
      XCTAssertTrue(app.buttons["tag-menu-research"].waitForExistence(timeout: 5))
      if create { app.buttons["new-tag"].tap() }
      if settings {
        app.buttons["edit-tags"].tap()
        app.buttons["tag-menu-research"].tap()
      }
      if settings || create {
        XCTAssertTrue(app.textFields["tag-name"].waitForExistence(timeout: 5))
      }
    }
  }

  func testDashboardTagMenuEntry() {
    let app = launch("tag-menu")
    returnToDashboard(app)
    let row = app.buttons["recent-row-t-atlas-launch"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.press(forDuration: 1)
    let tags = app.buttons.matching(
      NSPredicate(
        format: "label == %@ AND identifier != %@", "Conversation tags", "conversation-tags")
    ).firstMatch
    XCTAssertTrue(waitUntilHittable(tags))
    tags.tap()
    let newTag = app.buttons["New tag…"]
    XCTAssertTrue(waitUntilHittable(newTag))
    newTag.tap()
    XCTAssertTrue(app.textFields["tag-name"].waitForExistence(timeout: 5))
  }

  func testTagToggleCreateEditAndDeleteCancelConfirm() {
    let app = launch("tag-menu")
    let trigger = app.buttons["conversation-tags"]
    trigger.tap()
    app.buttons["tag-menu-research"].tap()
    let noTags = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "No tags"), object: trigger)
    XCTAssertEqual(XCTWaiter.wait(for: [noTags], timeout: 5), .completed)
    trigger.tap()
    app.buttons["tag-menu-research"].tap()
    let research = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Research"), object: trigger)
    XCTAssertEqual(XCTWaiter.wait(for: [research], timeout: 5), .completed)
    trigger.tap()
    app.buttons["new-tag"].tap()
    let name = app.textFields["tag-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Planning")
    app.buttons["Blue tag color"].tap()
    app.buttons["organize-save"].tap()
    XCTAssertTrue(trigger.waitForExistence(timeout: 5))
    trigger.tap()
    app.buttons["edit-tags"].tap()
    XCTAssertTrue(app.buttons["tag-menu-tag-created-1"].waitForExistence(timeout: 5))
    app.buttons["tag-menu-tag-created-1"].tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText(" notes")
    app.buttons["organize-save"].tap()
    trigger.tap()
    app.buttons["edit-tags"].tap()
    app.buttons["tag-menu-tag-created-1"].tap()
    XCTAssertTrue(app.buttons["delete-tag"].waitForExistence(timeout: 5))
    app.buttons["delete-tag"].tap()
    XCTAssertTrue(
      app.alerts.staticTexts[
        "Delete this tag from all conversations? Conversations are kept. This cannot be undone."
      ].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    app.buttons["delete-tag"].tap()
    app.alerts.buttons["Delete tag"].tap()
    XCTAssertTrue(self.element(app, "tag-settings").waitForNonExistence(timeout: 5))
    XCTAssertTrue(trigger.waitForExistence(timeout: 5))
    assertEventually(trigger, NSPredicate(format: "value == %@", "Research"))
    trigger.tap()
    XCTAssertTrue(app.buttons["new-tag"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["tag-menu-tag-created-1"].waitForNonExistence(timeout: 5))
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

  func testDashboardLastRowClearsFooterLight() { captureDashboardLastRow("light") }
  func testDashboardLastRowClearsFooterDark() { captureDashboardLastRow("dark") }

  private func captureDashboardLastRow(_ appearance: String) {
    capture("dashboard-populated", appearance, expect: ["agent-strip"], variant: "footerlast") {
      app in
      XCTAssertTrue(self.scrollTo(app, "load-older"))
      self.element(app, "load-older").tap()
      XCTAssertTrue(self.scrollTo(app, "recent-row-t-atlas-older"))
      let list = app.scrollViews.matching(identifier: "dashboard-list").firstMatch
      let last = self.element(app, "recent-row-t-atlas-older")
      let footer = self.element(app, "archive-toggle")
      // Scroll to the actual end, not merely an AX-instantiated row behind floating pills.
      for _ in 0..<4 {
        if last.isHittable && last.frame.maxY < footer.frame.minY { break }
        list.swipeUp()
      }
      let clearance = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          last.isHittable && last.frame.minY >= list.frame.minY
            && last.frame.maxY < footer.frame.minY
        }, object: nil)
      XCTAssertEqual(
        XCTWaiter.wait(for: [clearance], timeout: 10), .completed,
        "Last row must settle fully above footer pills")
    }
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

  func testConsoleManagerSheetLight() { captureConsoles("light") }
  func testConsoleManagerSheetDark() { captureConsoles("dark") }
  /// The console list as a sheet over the dashboard (a floating, text-carrying surface).
  private func captureConsoles(_ appearance: String) {
    capture("dashboard-populated", appearance, expect: ["agent-strip"], variant: "consoles") {
      app in
      app.descendants(matching: .any)["consoles-button"].firstMatch.tap()
      XCTAssertTrue(
        app.descendants(matching: .any)["add-console"].firstMatch.waitForExistence(timeout: 10))
    }
  }

  func testConsolesLargerTextLight() { captureConsoleVariants("light", larger: true) }
  func testConsolesLargerTextDark() { captureConsoleVariants("dark", larger: true) }
  func testConsolesLargerTextBottomLight() {
    captureConsoleVariants("light", larger: true, bottom: true)
  }
  func testConsolesLargerTextBottomDark() {
    captureConsoleVariants("dark", larger: true, bottom: true)
  }
  func testConsolesMixedStatesLight() { captureConsoleVariants("light") }
  func testConsolesMixedStatesDark() { captureConsoleVariants("dark") }

  private func captureConsoleVariants(
    _ appearance: String, larger: Bool = false, bottom: Bool = false
  ) {
    capture(
      "dashboard-populated", appearance, accessibilityText: larger,
      expect: ["agent-strip"],
      variant: bottom ? "consolesax3bottom" : larger ? "consolesax3" : "consolestates",
      arguments: ["--fixture-console-states"]
    ) { app in
      self.element(app, "consoles-button").tap()
      for label in ["Online", "Not connected", "Connection failed", "HTTP", "Checking…"] {
        XCTAssertTrue(
          app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)
          ).firstMatch.waitForExistence(timeout: 10))
      }
      if bottom {
        let row = app.buttons.matching(
          NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "console-row-",
            "Checking console")
        )
        .firstMatch
        let list = app.scrollViews.matching(identifier: "scenario-ready").firstMatch
        for _ in 0..<8 where !row.isHittable { list.swipeUp() }
        XCTAssertTrue(self.waitUntilHittable(row))
      }
    }
  }

  func testConnectionEmptyLargerTextLight() {
    capture("connection-empty", "light", accessibilityText: true)
  }
  func testConnectionEmptyLargerTextDark() {
    capture("connection-empty", "dark", accessibilityText: true)
  }
  func testConnectionCheckingLight() { captureChecking("light") }
  func testConnectionCheckingDark() { captureChecking("dark") }
  private func captureChecking(_ appearance: String) {
    capture(
      "connection-failed", appearance, expect: ["connection-failed"], variant: "checking",
      arguments: ["--fixture-console-states"]
    ) { app in
      // Return to the root list on compact width; split view already exposes it on iPad.
      let row = app.buttons.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "console-row-",
          "Checking console")
      )
      .firstMatch
      if UIDevice.current.userInterfaceIdiom == .phone {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(self.waitUntilHittable(back))
        back.tap()
      }
      XCTAssertTrue(self.waitUntilHittable(row))
      row.tap()
      XCTAssertTrue(self.element(app, "connection-checking").waitForExistence(timeout: 10))
      XCTAssertTrue(app.staticTexts["Checking console…"].waitForExistence(timeout: 10))
    }
  }

  func testConsoleMenuLight() { captureConsoleMenu("light") }
  func testConsoleMenuDark() { captureConsoleMenu("dark") }
  private func captureConsoleMenu(_ appearance: String) {
    capture("dashboard-populated", appearance, expect: ["agent-strip"], variant: "consolesmenu") {
      app in
      self.element(app, "consoles-button").tap()
      let actions = app.buttons.matching(NSPredicate(format: "label == %@", "Actions for Flockbox"))
        .firstMatch
      XCTAssertTrue(self.waitUntilHittable(actions))
      actions.tap()
      XCTAssertTrue(self.waitUntilHittable(app.buttons["Edit"]))
      XCTAssertTrue(self.waitUntilHittable(app.buttons["Remove"]))
    }
  }

  func testConsoleMenuEditsAndCancelsRemoval() {
    let app = launch("dashboard-populated")
    defer { app.terminate() }
    self.element(app, "consoles-button").tap()
    let actions = app.buttons.matching(NSPredicate(format: "label == %@", "Actions for Flockbox"))
      .firstMatch
    XCTAssertTrue(self.waitUntilHittable(actions))
    actions.tap()
    let edit = app.buttons["Edit"]
    XCTAssertTrue(self.waitUntilHittable(edit))
    edit.tap()
    let name = app.textFields["console-name"]
    assertEventually(name, NSPredicate(format: "value == %@", "Flockbox"))
    assertEventually(
      app.textFields["console-url"],
      NSPredicate(
        format: "value == %@", "https://console.example.ts.net"))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(self.waitUntilHittable(actions))
    actions.tap()
    let remove = app.buttons["Remove"]
    XCTAssertTrue(self.waitUntilHittable(remove))
    remove.tap()
    XCTAssertTrue(app.buttons["Remove console"].waitForExistence(timeout: 5))
    // A native confirmation popover may omit its Cancel row. Tapping outside dismisses
    // it on both families without invoking the destructive action.
    app.navigationBars["Consoles"].tap()
    XCTAssertTrue(app.buttons["Remove console"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(self.waitUntilHittable(actions))
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

  private func launch(_ scenario: String, accessibilityText: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--reset-test-data", "-AppleLanguages", "(en)", "-AppleLocale",
      "en_US",
    ]
    if accessibilityText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
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
  let app = XCUIApplication()
  let window = app.windows.firstMatch.frame
  if window.width > 900 {
    let sidebarAction = app.buttons["new-conversation"].firstMatch
    if sidebarAction.exists && sidebarAction.frame.midX < window.width * 0.4 {
      guard let image = screenshot.image.cgImage,
        let sidebar = image.cropping(
          to: CGRect(
            x: 0, y: Double(image.height) * 0.15,
            width: Double(image.width) * 0.3, height: Double(image.height) * 0.7)),
        screenshotRegionHasContent(sidebar)
      else { return false }
    }
  }
  guard let image = screenshot.image.cgImage,
    let content = image.cropping(
      to: CGRect(
        x: 0, y: Double(image.height) * 0.15,
        width: Double(image.width), height: Double(image.height) * 0.7
      ))
  else { return false }
  return screenshotRegionHasContent(content)
}

/// A split-view transition can leave only the sidebar flat while detail already has content.
private func screenshotRegionHasContent(_ content: CGImage) -> Bool {
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
