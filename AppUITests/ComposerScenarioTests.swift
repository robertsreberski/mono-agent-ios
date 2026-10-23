// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

/// Composer and answer-surface scenarios (C8). Every test types and sends through the synthetic
/// Store (`ComposerScript`), asserts the scripted round trip, and captures one screenshot.
@MainActor final class ComposerScenarioTests: XCTestCase {
  func testComposerEmptyLight() { run("composer-empty", "light") }
  func testComposerEmptyDark() { run("composer-empty", "dark") }
  func testComposerKeyboardUp() { run("composer-empty", "light", variant: "keyboard") }
  func testDraftAttachmentsLight() { run("composer-draft-attachments", "light") }
  func testDraftAttachmentsDark() { run("composer-draft-attachments", "dark") }
  func testDraftAttachmentsPlumDark() { run("composer-draft-attachments", "dark", variant: "plum") }
  func testSkillPickerLight() { run("composer-skill-picker", "light") }
  func testSkillPickerDark() { run("composer-skill-picker", "dark") }
  func testModelSelectorLight() { run("composer-model-selector", "light") }
  func testModelSelectorDark() { run("composer-model-selector", "dark") }
  func testRunningLight() { run("composer-running", "light") }
  func testRunningDark() { run("composer-running", "dark") }
  func testRunningAccessibility() { run("composer-running", "light", variant: "ax3") }
  func testSendFailedLight() { run("composer-send-failed", "light") }
  func testSendFailedDark() { run("composer-send-failed", "dark") }
  func testQuoteLight() { run("composer-quote", "light") }
  func testQuoteDark() { run("composer-quote", "dark") }
  func testAskFormLight() { run("conversation-ask-form", "light") }
  func testAskFormDark() { run("conversation-ask-form", "dark") }
  func testQuickRepliesLight() { run("conversation-quick-replies", "light") }
  func testQuickRepliesDark() { run("conversation-quick-replies", "dark") }
  func testPeerQuestionLight() { run("peer-question-sheet", "light") }
  func testPeerQuestionDark() { run("peer-question-sheet", "dark") }

  // MARK: Flows

  private func run(_ scenario: String, _ appearance: String, variant: String? = nil) {
    let app = launch(scenario, appearance, variant: variant)
    defer { app.terminate() }
    let capture = { self.capture(app, scenario, appearance, variant: variant) }
    switch scenario {
    case "composer-empty": newConversation(app, variant: variant, capture: capture)
    case "composer-draft-attachments": draftAttachments(app, capture: capture)
    case "composer-skill-picker": skillPicker(app, capture: capture)
    case "composer-model-selector": modelSelector(app, capture: capture)
    case "composer-running": running(app, capture: capture)
    case "composer-send-failed": sendFailed(app, capture: capture)
    case "composer-quote": quote(app, capture: capture)
    case "conversation-ask-form": askForm(app, capture: capture)
    case "conversation-quick-replies": quickReplies(app, capture: capture)
    case "peer-question-sheet": peerQuestion(app, capture: capture)
    default: XCTFail("Unknown composer scenario \(scenario)")
    }
  }

  private func newConversation(_ app: XCUIApplication, variant: String?, capture: () -> Void) {
    XCTAssertTrue(element(app, "new-conversation").waitForExistence(timeout: 10))
    element(app, "new-conversation").tap()
    XCTAssertTrue(element(app, "composer-placeholder").waitForExistence(timeout: 10))
    let field = composerField(app)
    XCTAssertFalse(element(app, "composer-send").isEnabled, "An empty composer cannot send")
    if variant == "keyboard" {
      field.tap()
      field.typeText("Plan the sample launch")
      capture()
    } else {
      capture()
      field.tap()
      field.typeText("Plan the sample launch")
    }
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Plan the sample launch”"))
    XCTAssertTrue(element(app, "conversation-transcript").exists, "The created thread is shown")
    XCTAssertEqual(fieldText(app), "", "Admission clears the sent draft")
    // Re-enter the same agent's new-conversation route after the first creation.
    field.tap()
    field.typeText("/new")
    let newCommand = element(app, "command-suggestion-new")
    XCTAssertTrue(newCommand.waitForExistence(timeout: 5))
    newCommand.tap()
    XCTAssertTrue(element(app, "composer-placeholder").waitForExistence(timeout: 10))
    XCTAssertFalse(element(app, "message-sample-assistant").exists)
    let nextField = composerField(app)
    nextField.tap()
    nextField.typeText("Plan a second sample")
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Plan a second sample”"))
    XCTAssertFalse(
      waitForText(app, "Synthetic reply: received “Plan the sample launch”", timeout: 1),
      "The second send belongs to a new transcript")
  }

  private func draftAttachments(_ app: XCUIApplication, capture: () -> Void) {
    let field = composerField(app)
    XCTAssertTrue(fieldText(app).contains("Draft kept from an earlier visit"), "Draft restored")
    element(app, "composer-attach").tap()
    XCTAssertTrue(element(app, "attach-samples").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "attach-files").exists && element(app, "attach-photos").exists)
    element(app, "attach-samples").tap()
    XCTAssertTrue(element(app, "attachment-field-notes.txt").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "attachment-sample-photo.png").waitForExistence(timeout: 10))
    capture()
    field.tap()
    field.typeText(" Thanks.")
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "with 2 attachments"))
    XCTAssertFalse(element(app, "attachment-field-notes.txt").exists, "Admission clears chips")
  }

  private func skillPicker(_ app: XCUIApplication, capture: () -> Void) {
    let field = composerField(app)
    field.tap()
    field.typeText("Please use $rel")
    let suggestion = element(app, "skill-suggestion-release-notes")
    XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
    capture()
    suggestion.tap()
    XCTAssertEqual(fieldText(app), "Please use $release-notes ")
    element(app, "composer-skills").tap()
    XCTAssertTrue(element(app, "skill-browse-weekly-digest").waitForExistence(timeout: 10))
    XCTAssertFalse(
      element(app, "skill-browse-legacy-export").isEnabled, "Unavailable skills are explained")
    element(app, "skill-browse-weekly-digest").tap()
    XCTAssertTrue(fieldText(app).contains("$weekly-digest"))
    field.typeText("for this week")
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Please use $release-notes"))
  }

  private func modelSelector(_ app: XCUIApplication, capture: () -> Void) {
    let menu = element(app, "composer-model")
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertTrue((menu.value as? String ?? "").contains("Sample Large"), "agent default shown")
    menu.tap()
    let small = menuButton(app, "Sample Small")
    XCTAssertTrue(small.waitForExistence(timeout: 5))
    let catalog = menuButton(app, "Harbor catalog")
    XCTAssertTrue(catalog.exists)
    XCTAssertFalse(catalog.isEnabled, "Catalog-only providers are explained, not selectable")
    capture()
    small.tap()
    let routed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (menu.value as? String ?? "").contains("Sample Small")
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [routed], timeout: 10), .completed)
    menu.tap()
    let low = menuButton(app, "Low")
    XCTAssertTrue(low.waitForExistence(timeout: 5))
    low.tap()
    XCTAssertTrue(waitFor(app, "route-badge", containing: "sample:small"))
    XCTAssertTrue((menu.value as? String ?? "").contains("Low"))
    let field = composerField(app)
    field.tap()
    field.typeText("Try the small model")
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Try the small model”"))
  }

  /// SwiftUI menu items surface as buttons labelled "title, subtitle"; identifiers do not.
  private func menuButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")
    ).firstMatch
  }

  private func running(_ app: XCUIApplication, capture: () -> Void) {
    XCTAssertTrue(element(app, "composer-stop").waitForExistence(timeout: 10))
    let field = composerField(app)
    field.tap()
    field.typeText("Also check the images")
    XCTAssertTrue(element(app, "composer-queue").waitForExistence(timeout: 5))
    dismissKeyboard(app)
    capture()
    element(app, "composer-queue").tap()
    XCTAssertTrue(waitFor(app, "composer-status", containing: "live input"))
    XCTAssertTrue(waitForText(app, "Follow-up · applied"))
    element(app, "composer-stop").tap()
    let stopped = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element(app, "composer-stop"))
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed, "Stop ends the run")
    XCTAssertTrue(element(app, "composer-send").exists, "Idle again: Send replaces Queue")
  }

  private func sendFailed(_ app: XCUIApplication, capture: () -> Void) {
    let field = composerField(app)
    field.tap()
    field.typeText("Publish the sample")
    element(app, "composer-send").tap()
    XCTAssertTrue(waitFor(app, "composer-status", containing: "Not confirmed"))
    XCTAssertEqual(fieldText(app), "Publish the sample", "Uncertain text is retained")
    dismissKeyboard(app)
    capture()
    element(app, "composer-retry").tap()
    // The script rejects any retry with a new submission ID, so this reply proves UUID reuse.
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Publish the sample”"))
    XCTAssertFalse(waitForText(app, "rejected", timeout: 1))
  }

  private func quote(_ app: XCUIApplication, capture: () -> Void) {
    let message = element(app, "message-sample-assistant")
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    message.press(forDuration: 1.2)
    let quote = app.buttons["Quote"].firstMatch
    XCTAssertTrue(quote.waitForExistence(timeout: 5))
    quote.tap()
    XCTAssertTrue(element(app, "quote-preview").waitForExistence(timeout: 5))
    let field = composerField(app)
    field.tap()
    field.typeText("Which file needs attention?")
    dismissKeyboard(app)
    capture()
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply about “The sample is ready."))
    XCTAssertFalse(element(app, "quote-preview").exists, "Admission clears the quote")
  }

  private func askForm(_ app: XCUIApplication, capture: () -> Void) {
    XCTAssertTrue(element(app, "ask-card").waitForExistence(timeout: 10))
    let today = element(app, "ask-option-window-today")
    XCTAssertTrue(scrollTo(app, today))
    XCTAssertFalse(element(app, "ask-submit").isEnabled, "Every question is required")
    today.tap()
    let links = element(app, "ask-option-checks-links")
    XCTAssertTrue(scrollTo(app, links))
    links.tap()
    element(app, "ask-option-checks-copy").tap()
    let custom = element(app, "ask-custom-checks")
    XCTAssertTrue(scrollTo(app, custom))
    custom.tap()
    custom.typeText("Also the captions")
    dismissKeyboard(app)
    let submit = element(app, "ask-submit")
    XCTAssertTrue(scrollTo(app, submit))
    XCTAssertTrue(submit.isEnabled)
    capture()
    submit.tap()
    XCTAssertTrue(element(app, "ask-complete").waitForExistence(timeout: 10))
    XCTAssertTrue(waitForText(app, "Release window: Today"))
    XCTAssertTrue(waitForText(app, "Thanks — scheduling the sample release."))
  }

  private func quickReplies(_ app: XCUIApplication, capture: () -> Void) {
    let ship = element(app, "quick-reply-Ship it")
    XCTAssertTrue(ship.waitForExistence(timeout: 10))
    XCTAssertTrue(ship.isEnabled)
    capture()
    ship.tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Ship it”"))
    XCTAssertFalse(element(app, "quick-reply-Hold for review").isEnabled, "One reply per answer")
  }

  private func peerQuestion(_ app: XCUIApplication, capture: () -> Void) {
    // The peer job rides in the composer dock's job shelf (web ProcessJobStack placement).
    let shelf = element(app, "job-stack")
    XCTAssertTrue(shelf.waitForExistence(timeout: 10))
    shelf.tap()
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    let group = dock.descendants(matching: .any)["job-group-peer:seed-bank"].firstMatch
    if group.waitForExistence(timeout: 3) { dockReveal(app, group).tap() }
    let card = dock.descendants(matching: .any)["job-card-job-peer-sample"].firstMatch
    if card.waitForExistence(timeout: 3) { dockReveal(app, card).tap() }
    let answer = dockReveal(
      app, dock.descendants(matching: .any)["peer-question-answer"].firstMatch)
    XCTAssertTrue(answer.isEnabled)
    answer.tap()
    XCTAssertTrue(element(app, "peer-sheet").waitForExistence(timeout: 10))
    XCTAssertFalse(element(app, "peer-submit").isEnabled, "The required field is unanswered")
    element(app, "peer-option-question_1-Reserve now").tap()
    let note = element(app, "peer-text-question_2")
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    note.tap()
    note.typeText("Leave them at the gate")
    capture()
    element(app, "peer-submit").tap()
    XCTAssertTrue(
      waitFor(app, "composer-field", containing: "Answer for the seed-bank peer question"))
    element(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Answer for the seed-bank peer"))
  }

  private func dockReveal(_ app: XCUIApplication, _ target: XCUIElement) -> XCUIElement {
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    for _ in 0..<10 {
      if target.exists && target.isHittable { return target }
      guard dock.exists else { break }
      dragDock(dock, down: target.exists && target.frame.midY < dock.frame.minY)
    }
    return target
  }

  // MARK: Helpers

  private func launch(_ scenario: String, _ appearance: String, variant: String?)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if variant == "plum" { app.launchArguments += ["--fixture-theme", "plum"] }
    if variant == "ax3" {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }
  private func composerField(_ app: XCUIApplication) -> XCUIElement {
    let field =
      app.textViews["composer-field"].exists
      ? app.textViews["composer-field"] : element(app, "composer-field")
    XCTAssertTrue(field.waitForExistence(timeout: 15), "composer field")
    return field
  }
  private func fieldText(_ app: XCUIApplication) -> String {
    let value = composerField(app).value as? String ?? ""
    return value == "Message" || value.hasPrefix("Message ") ? "" : value
  }
  private func waitForText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 15)
    -> Bool
  {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch.waitForExistence(timeout: timeout)
  }
  private func waitFor(_ app: XCUIApplication, _ id: String, containing text: String) -> Bool {
    let target = element(app, id)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        target.exists
          && (target.label.contains(text) || (target.value as? String ?? "").contains(text)
            || target.descendants(matching: .any).matching(
              NSPredicate(format: "label CONTAINS %@", text)
            ).count > 0)
      }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
  }
  private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
    for _ in 0..<6 {
      if target.waitForExistence(timeout: 1) && target.isHittable { return true }
      app.scrollViews.matching(identifier: "conversation-transcript").firstMatch.swipeUp()
    }
    return target.exists
  }
  /// The keyboard lowers by dragging the transcript (`scrollDismissesKeyboard`), as there is
  /// no separate dismiss button any more.
  private func dismissKeyboard(_ app: XCUIApplication) {
    guard app.keyboards.firstMatch.exists else { return }
    let transcript = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
    let target = transcript.exists ? transcript : app.scrollViews.firstMatch
    let from = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
    from.press(
      forDuration: 0.05,
      thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
  }
  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String?
  ) {
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in screenshotHasContent(XCUIScreen.main.screenshot()) },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertTrue(screenshotHasContent(screenshot))
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name =
      "synthetic-fixture__\(scenario)__\(appearance)" + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// A short, slow drag inside the dock's bounded scroll view (flicks overshoot it).
  private func dragDock(_ dock: XCUIElement, down: Bool) {
    let from = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
    let to = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
    from.press(forDuration: 0.05, thenDragTo: to)
  }

}
