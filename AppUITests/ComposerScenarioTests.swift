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
  func testDraftLifecycleLight() {
    run("composer-draft-attachments", "light", variant: "lifecycle")
  }
  func testDraftLifecycleDark() { run("composer-draft-attachments", "dark", variant: "lifecycle") }
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
    case "composer-draft-attachments":
      if variant == "lifecycle" {
        draftLifecycle(app, capture: capture)
      } else {
        draftAttachments(app, capture: capture)
      }
    case "composer-skill-picker":
      skillPicker(app, appearance: appearance, variant: variant, capture: capture)
    case "composer-model-selector": modelSelector(app, capture: capture)
    case "composer-running": running(app, capture: capture)
    case "composer-send-failed": sendFailed(app, capture: capture)
    case "composer-quote": quote(app, appearance: appearance, capture: capture)
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
    enabledElement(app, "composer-send").tap()
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
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Plan a second sample”"))
    XCTAssertFalse(
      waitForText(app, "Synthetic reply: received “Plan the sample launch”", timeout: 1),
      "The second send belongs to a new transcript")
  }

  private func draftAttachments(_ app: XCUIApplication, capture: () -> Void) {
    let field = composerField(app)
    XCTAssertTrue(fieldText(app).contains("Draft kept from an earlier visit"), "Draft restored")
    enabledElement(app, "composer-attach").tap()
    XCTAssertTrue(element(app, "attach-samples").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "attach-files").exists && element(app, "attach-photos").exists)
    element(app, "attach-samples").tap()
    XCTAssertTrue(element(app, "attachment-field-notes.txt").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "attachment-sample-photo.png").waitForExistence(timeout: 10))
    capture()
    field.tap()
    field.typeText(" Thanks.")
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "with 2 attachments"))
    XCTAssertFalse(element(app, "attachment-field-notes.txt").exists, "Admission clears chips")
  }

  private func draftLifecycle(_ app: XCUIApplication, capture: () -> Void) {
    let message = element(app, "message-sample-assistant")
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    // Long-press the action area, not selectable prose (which can open the native
    // text-selection menu instead of the message menu on iPad).
    let action = message.buttons.matching(identifier: "message-copy").firstMatch
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        action.exists && !action.frame.isEmpty && action.isHittable
          && app.windows.firstMatch.frame.contains(action.frame)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    action.press(forDuration: 1.2)
    let quote = app.buttons["Quote"].firstMatch
    XCTAssertTrue(quote.waitForExistence(timeout: 5))
    quote.tap()
    XCTAssertTrue(element(app, "quote-preview").waitForExistence(timeout: 5))
    let field = composerField(app)
    field.tap()
    field.typeText(" Keep this draft.")
    XCTAssertTrue(waitFor(app, "composer-field", containing: "Keep this draft."))
    dismissKeyboard(app)
    enabledElement(app, "composer-attach").tap()
    XCTAssertTrue(element(app, "attach-samples").waitForExistence(timeout: 5))
    element(app, "attach-samples").tap()

    func retained() {
      XCTAssertTrue(element(app, "attachment-sample-photo.png").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "attachment-field-notes.txt").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "quote-preview").waitForExistence(timeout: 5))
      XCTAssertTrue(waitFor(app, "composer-field", containing: "Keep this draft."))
    }
    func transition(_ action: String, revision: Int, primary: String) {
      let menu = element(app, "fixture-lifecycle")
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      menu.tap()
      let button = element(app, action)
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      button.tap()
      let completed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", String(revision)), object: menu)
      XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
      XCTAssertTrue(element(app, primary).waitForExistence(timeout: 10))
      retained()
    }
    retained()
    transition("fixture-toggle-run", revision: 1, primary: "composer-queue")
    transition("fixture-toggle-run", revision: 2, primary: "composer-send")
    transition("fixture-toggle-run", revision: 3, primary: "composer-queue")
    transition("fixture-refresh", revision: 4, primary: "composer-queue")
    transition("fixture-reselect", revision: 5, primary: "composer-queue")
    XCUIDevice.shared.press(.home)
    let backgrounded = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.state == .runningBackground }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
    app.activate()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    retained()
    capture()
    transition("fixture-toggle-run", revision: 6, primary: "composer-send")
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "with 2 attachments"))
    let clearedField = element(app, "composer-field")
    let cleared = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let value = clearedField.value as? String ?? ""
        return !self.element(app, "attachment-sample-photo.png").exists
          && !self.element(app, "quote-preview").exists && clearedField.exists
          && (value.isEmpty || value == "Message" || value.hasPrefix("Message "))
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 20), .completed)
  }

  private func skillPicker(
    _ app: XCUIApplication, appearance: String, variant: String?, capture: () -> Void
  ) {
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
    self.capture(app, "skill-browser", appearance, variant: variant)
    element(app, "skill-browse-weekly-digest").tap()
    XCTAssertTrue(fieldText(app).contains("$weekly-digest"))
    field.typeText("for this week")
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Please use $release-notes"))
  }

  private func modelSelector(_ app: XCUIApplication, capture: () -> Void) {
    let menu = element(app, "composer-model")
    WaitFor.value(menu, contains: "Sample Large")  // the agent default is shown
    guard WaitFor.hittable(menu) else { return }
    menu.tap()
    let small = menuButton(app, "Sample Small")
    guard WaitFor.hittable(small) else { return }
    let catalog = menuButton(app, "Harbor catalog")
    WaitFor.enabled(catalog, false)
    capture()
    // Capturing can outlive the presentation transition. Recheck the current frame before
    // tapping, then wait for the sheet to dismiss rather than reopening during its animation.
    guard WaitFor.hittable(small) else { return }
    small.tap()
    WaitFor.value(menu, contains: "Sample Small")
    WaitFor.absent(small)
    guard WaitFor.hittable(menu) else { return }
    menu.tap()
    let low = menuButton(app, "Low")
    guard WaitFor.hittable(low) else { return }
    low.tap()
    WaitFor.value(element(app, "rename-conversation"), contains: "sample:small")
    WaitFor.value(menu, contains: "Low")
    let field = composerField(app)
    field.tap()
    field.typeText("Try the small model")
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Try the small model”"))
  }

  func testRunSettingsResetRestoresTheAgentDefault() {
    let app = launch("composer-model-selector", "light", variant: nil)
    let trigger = element(app, "composer-model")
    WaitFor.hittable(trigger)
    trigger.tap()
    WaitFor.hittable(menuButton(app, "Sample Small"))
    menuButton(app, "Sample Small").tap()
    WaitFor.value(trigger, contains: "Sample Small")
    trigger.tap()
    let reset = element(app, "model-reset")
    WaitFor.hittable(reset)
    WaitFor.label(reset, contains: "Reset to agent default")
    reset.tap()
    WaitFor.absent(reset)
    WaitFor.hittable(element(app, "sheet-close"))
    element(app, "sheet-close").tap()
    WaitFor.value(trigger, contains: "Sample Large")
    WaitFor.value(trigger, contains: "High")
    app.terminate()
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
    let retainedText = NSPredicate(format: "value == %@", "Also check the images")
    func assertDraftRetained() {
      let retained = XCTNSPredicateExpectation(predicate: retainedText, object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 15), .completed)
      let enabled = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND enabled == true"),
        object: element(app, "composer-queue"))
      XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
    }
    assertDraftRetained()
    dismissKeyboard(app)
    assertDraftRetained()
    capture()
    assertDraftRetained()
    enabledElement(app, "composer-queue").tap()
    // Admission's status is ephemeral (4 seconds); a slow AX snapshot can miss it.
    // The durable applied live-input message proves admission without that timing race.
    XCTAssertTrue(waitForText(app, "Consumed by current run"))
    element(app, "composer-stop").tap()
    let stopped = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element(app, "composer-stop"))
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed, "Stop ends the run")
    XCTAssertTrue(
      element(app, "composer-send").waitForExistence(timeout: 10),
      "Idle again: Send replaces Queue")
  }

  private func sendFailed(_ app: XCUIApplication, capture: () -> Void) {
    let field = composerField(app)
    field.tap()
    field.typeText("Publish the sample")
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Not confirmed"))
    XCTAssertEqual(fieldText(app), "Publish the sample", "Uncertain text is retained")
    dismissKeyboard(app)
    capture()
    element(app, "composer-retry").tap()
    // The script rejects any retry with a new submission ID, so this reply proves UUID reuse.
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Publish the sample”"))
    XCTAssertFalse(waitForText(app, "rejected", timeout: 1))
  }

  private func quote(_ app: XCUIApplication, appearance: String, capture: () -> Void) {
    let message = element(app, "message-sample-assistant")
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    message.press(forDuration: 1.2)
    let selection = app.buttons["Quote Selection…"].firstMatch
    XCTAssertTrue(selection.waitForExistence(timeout: 5))
    selection.tap()
    XCTAssertTrue(app.navigationBars["Select text to quote"].waitForExistence(timeout: 5))
    self.capture(app, "composer-quote-selection", appearance, variant: nil)
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(message.waitForExistence(timeout: 5))
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
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply about “The sample is ready."))
    XCTAssertFalse(element(app, "quote-preview").exists, "Admission clears the quote")
  }

  private func askForm(_ app: XCUIApplication, capture: () -> Void) {
    XCTAssertTrue(element(app, "ask-card").waitForExistence(timeout: 10))
    let today = element(app, "ask-option-window-today")
    XCTAssertTrue(scrollTo(app, today))
    XCTAssertTrue(
      composerWait { !self.element(app, "ask-submit").isEnabled }, "Every question is required")
    today.tap()
    XCTAssertTrue(composerWait { today.isSelected })
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
    XCTAssertTrue(composerWait { submit.isEnabled })
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
    enabledElement(app, "composer-send").tap()
    XCTAssertTrue(waitForText(app, "Synthetic reply: received “Answer for the seed-bank peer"))
  }

  private func dockReveal(_ app: XCUIApplication, _ target: XCUIElement) -> XCUIElement {
    let dock = app.scrollViews.matching(identifier: "composer-dock-scroll").firstMatch
    for _ in 0..<10 {
      if target.exists && !target.frame.isEmpty && target.isHittable { return target }
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
    if variant == "lifecycle" { app.launchArguments += ["--draft-lifecycle-controls"] }
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
  private func enabledElement(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    let target = element(app, id)
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND enabled == true"), object: target)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
    return target
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
  private func composerWait(_ predicate: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in predicate() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
  private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
    let transcript = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
    let composer = element(app, "composer")
    let header = element(app, "conversation-top-bar")
    // Chrome stays fixed during transcript scrolling. Resolve its geometry once per reveal,
    // not on every predicate evaluation: each XCUI property is a fresh accessibility query.
    // Re-reading all three frames could itself exhaust the wait on a dense iPad transcript.
    let transcriptFrame = transcript.frame
    let top = max(
      transcriptFrame.minY,
      header.exists ? header.frame.maxY : app.navigationBars.firstMatch.frame.maxY)
    let bottom = composer.exists ? composer.frame.minY - 20 : transcriptFrame.maxY
    func reachable() -> Bool {
      guard target.exists else { return false }
      let frame = target.frame
      guard !frame.isEmpty else { return false }
      return transcriptFrame.contains(frame.center) && frame.midY >= top + 8
        && frame.midY < bottom && target.isHittable
    }
    for _ in 0..<8 {
      if reachable() { return composerWait { reachable() } }
      // The scroll view extends behind both pieces of floating chrome. A target above the
      // reading edge needs a downward swipe, not another upward swipe past its control.
      if target.exists && target.frame.midY < top + 8 {
        transcript.swipeDown()
      } else {
        transcript.swipeUp()
      }
    }
    return composerWait { reachable() }
  }
  /// The keyboard lowers by dragging the transcript (`scrollDismissesKeyboard`), as there is
  /// no separate dismiss button any more.
  private func dismissKeyboard(_ app: XCUIApplication) {
    guard app.keyboards.firstMatch.exists else { return }
    let transcript = app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
    let target = transcript.exists ? transcript : app.scrollViews.firstMatch
    // A downward drag always scrolls a transcript resting at its end, which lowers the keyboard.
    let from = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
    from.press(
      forDuration: 0.05,
      thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
  }
  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String?
  ) {
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

  /// A short, slow drag inside the dock's bounded scroll view (flicks overshoot it).
  private func dragDock(_ dock: XCUIElement, down: Bool) {
    let from = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
    let to = dock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
    from.press(forDuration: 0.05, thenDragTo: to)
  }

}

extension CGRect {
  fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
