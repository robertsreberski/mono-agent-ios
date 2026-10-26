// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class TranscriptScenarioTests: XCTestCase {
  func testTranscriptLight() { capture("conversation-transcript", "light") }
  func testShortTranscriptOpensAtFirstRow() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-transcript", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let first = element(app, "message-sample-user")
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil { first.exists && !first.frame.isEmpty && first.isHittable })
    XCTAssertTrue(waitUntil { first.frame.minY >= self.transcriptScroll(app).frame.minY })
    XCTAssertTrue(element(app, "jump-to-latest").waitForNonExistence(timeout: 5))
    app.terminate()
  }
  func testPullToRefreshBelowPhoneHeaderKeepsContentReachable() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-transcript", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let scroll = transcriptScroll(app)
    let first = element(app, "message-sample-user")
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
    start.press(
      forDuration: 0.1,
      thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
    let header = element(app, "conversation-header")
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        first.exists && !first.frame.isEmpty && header.exists && !header.frame.isEmpty
          && first.frame.minY >= scroll.frame.minY && first.isHittable && header.isHittable
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
    // A user drag can enter reading mode on phones; its Jump control must still resume following.
    let jump = element(app, "jump-to-latest")
    if jump.exists {
      jump.tap()
      let following = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in !jump.exists }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [following], timeout: 10), .completed)
    }
    XCTAssertTrue(waitUntil { self.element(app, "composer").isHittable })
    app.terminate()
  }

  func testCompactionMarkersLight() {
    capture("conversation-transcript", "light", variant: "markers")
  }
  func testCompactionMarkersDark() {
    capture("conversation-transcript", "dark", variant: "markers")
  }
  func testMessageStatusesLight() {
    capture("conversation-transcript", "light", variant: "statuses")
  }
  func testMessageStatusesDark() { capture("conversation-transcript", "dark", variant: "statuses") }
  func testToolsLargerText() { capture("conversation-tools", "light", variant: "ax3") }
  func testTranscriptDark() { capture("conversation-transcript", "dark") }
  func testStreamingLight() { capture("conversation-streaming", "light") }
  func testStreamingDark() { capture("conversation-streaming", "dark") }
  func testToolsLight() { capture("conversation-tools", "light") }
  func testToolsDark() { capture("conversation-tools", "dark") }
  func testLongLight() { capture("conversation-long", "light") }
  func testLongDark() { capture("conversation-long", "dark") }
  func testMarkdownLight() { capture("conversation-markdown", "light") }
  func testMarkdownDark() { capture("conversation-markdown", "dark") }
  func testMarkdownPlumDark() { capture("conversation-markdown", "dark", variant: "plum") }
  func testCodeCopyShowsSuccess() {
    let app = launchScenario("conversation-markdown")
    let copy = app.buttons.matching(identifier: "code-copy").firstMatch
    XCTAssertTrue(position(copy, in: app))
    copy.tap()
    XCTAssertTrue(wait(copy, value: "Copied"))
    XCTAssertTrue(waitUntil(timeout: 10) { (copy.value as? String) != "Copied" })
    app.terminate()
  }
  func testCodeOnlyChipsLight() { capture("conversation-markdown", "light", variant: "chips") }
  func testCodeOnlyChipsDark() { capture("conversation-markdown", "dark", variant: "chips") }
  func testMarkdownAccessibility() { capture("conversation-markdown", "light", variant: "ax3") }

  /// A band the user opened stays open after its row scrolls far enough to be recycled.
  func testOpenedBandSurvivesScrollingAwayAndBack() {
    let app = launchScenario("conversation-long")
    XCTAssertTrue(element(app, "message-long-539").waitForExistence(timeout: 10))
    // Bands occur at indices 1 modulo 100. Scope to this row: the list can retain another
    // band's accessibility node outside the viewport during a scroll.
    // Thirty-eight rows separate this band from the bottom: well beyond the lazy viewport,
    // but reachable without relying on a device-dependent count of hundreds of swipes.
    let row = element(app, "message-long-501")
    let band = row.descendants(matching: .button)["activity-band"].firstMatch
    XCTAssertTrue(
      position(band, in: app, centered: true), "The older band must be clear of the header")
    XCTAssertTrue(wait(band, value: "Collapsed"), "A settled band starts collapsed")
    band.tap()
    XCTAssertTrue(wait(band, value: "Expanded"))
    // Jump to the newest row, far past the lazy list's retained window, then come back.
    let jump = element(app, "jump-to-latest")
    XCTAssertTrue(waitUntil { jump.exists && !jump.frame.isEmpty && jump.isHittable })
    jump.tap()
    let latest = element(app, "message-long-539")
    // Jump switches to following immediately, but lazy bottom-edge layout and AX publication
    // can settle later. Keep the newest-row proof: disappearance of Jump alone is not enough.
    XCTAssertTrue(jump.waitForNonExistence(timeout: 30), "Jump resumes following")
    XCTAssertTrue(latest.waitForExistence(timeout: 30), "The newest row must materialize")
    XCTAssertTrue(position(latest, in: app), "The newest row must be clear of overlays")
    XCTAssertTrue(
      position(band, in: app, centered: true), "The returned band must be clear of the header")
    XCTAssertTrue(wait(band, value: "Expanded"), "The user's choice survives row recycling")
    app.terminate()
  }

  /// Web `collapseOnSettle`: the streaming band collapses when its turn ends; a manual reopen
  /// then holds across a refresh that re-reads and re-renders the conversation.
  func testRunningBandCollapsesOnSettleAndManualReopenPersists() {
    let app = launchScenario("conversation-streaming")
    let complete = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "Stream complete")
    ).firstMatch
    XCTAssertTrue(complete.waitForExistence(timeout: 20))
    let band = element(app, "activity-band")
    XCTAssertTrue(wait(band, value: "Collapsed"), "Settling collapses the band")
    XCTAssertTrue(position(band, in: app), "The settled band must be clear of the header")
    band.tap()
    XCTAssertTrue(wait(band, value: "Expanded"))
    transcriptScroll(app).swipeDown()
    XCTAssertTrue(complete.waitForExistence(timeout: 10))
    XCTAssertTrue(position(band, in: app), "The refreshed band must be clear of the header")
    XCTAssertTrue(wait(band, value: "Expanded"), "A manual reopen persists")
    app.terminate()
  }

  private func launchScenario(_ scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    return app
  }
  private func wait(_ element: XCUIElement, value: String, timeout: TimeInterval = 10) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in element.exists && (element.value as? String) == value },
      object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  private func waitUntil(timeout: TimeInterval = 30, _ predicate: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in predicate() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  /// AX can report a band as hittable while its tap lands on the floating header instead.
  /// Keep the entire control visible. Long transcripts can also center it in the middle 40%;
  /// short transcripts may not have enough scrollable content to reach that central region.
  private func position(
    _ target: XCUIElement, in app: XCUIApplication, centered: Bool = false
  ) -> Bool {
    let scroll = transcriptScroll(app)
    let header = element(app, "conversation-header")
    let composer = element(app, "composer")
    let safelyVisible = {
      guard target.exists, !target.frame.isEmpty, scroll.exists, header.exists, composer.exists
      else {
        return false
      }
      let frame = target.frame
      let viewport = scroll.frame
      return !frame.isEmpty && viewport.contains(frame)
        && frame.minY >= header.frame.maxY + 8 && frame.maxY <= composer.frame.minY
        && (!centered
          || (frame.midY >= viewport.minY + viewport.height * 0.3
            && frame.midY <= viewport.minY + viewport.height * 0.7))
        && target.isHittable
    }
    var recordedFrame = false
    for _ in 0..<40 {
      if safelyVisible() { return waitUntil(safelyVisible) }
      let exists = target.exists
      if exists && !recordedFrame {
        XCTContext.runActivity(named: "Position transcript control clear of overlays") { activity in
          let geometry =
            "target=\(target.frame); transcript=\(scroll.frame); "
            + "header=\(header.frame); composer=\(composer.frame)"
          print(geometry)
          let frames = XCTAttachment(string: geometry)
          frames.lifetime = .keepAlways
          activity.add(frames)
        }
        recordedFrame = true
      }
      // Search toward older rows until materialized, then nudge in either direction. Slow,
      // short coordinate drags avoid the inertial overshoot of swipeDown near the header.
      let down = !exists || target.frame.midY < scroll.frame.midY
      let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.65))
      let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.35))
      from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    return waitUntil(safelyVisible)
  }

  func testLongPagingPreservesMessageAnchorAndHeaderAccessibility() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", "conversation-long", "--appearance", "light", "--reset-test-data",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    let scroll = transcriptScroll(app)
    // Establish user reading intent before using the native scroll-to-top gesture. Hundreds
    // of inertial swipes are slow and can expose an AX-hittable button behind the status bar.
    scroll.swipeDown(velocity: .fast)
    XCTAssertTrue(element(app, "jump-to-latest").waitForExistence(timeout: 5))
    let header = element(app, "conversation-header")
    let window = app.windows.firstMatch
    // iOS does not expose the status bar in this app's AX tree. Tap the top system region,
    // outside the Dynamic Island and over the detail column on a split-view tablet.
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: scroll.frame.maxX - window.frame.minX - 24,
        dy: (header.frame.minY - window.frame.minY) / 4)
    ).tap()
    let older = element(app, "transcript-load-older")
    let reachable = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard older.exists, !older.frame.isEmpty, older.isHittable, older.isEnabled, header.exists
        else {
          return false
        }
        let frame = older.frame
        return frame.minY >= max(scroll.frame.minY, header.frame.maxY)
          && app.windows.firstMatch.frame.contains(frame)
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 20), .completed)
    XCTAssertTrue(
      header.waitForExistence(timeout: 5),
      "The eager header must return to the accessibility hierarchy")
    let anchor = element(app, "message-long-40")
    XCTAssertTrue(waitUntil { anchor.exists && !anchor.frame.isEmpty && anchor.isHittable })
    older.tap()
    let paged = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        !self.element(app, "transcript-load-older").exists
          && self.element(app, "message-long-40").exists
      }, object: nil)
    // Paging is a network read plus layout; allow a loaded simulator to settle.
    XCTAssertEqual(XCTWaiter.wait(for: [paged], timeout: 20), .completed)
    XCTAssertTrue(
      waitUntil { anchor.exists && !anchor.frame.isEmpty && anchor.isHittable },
      "Paging must retain the previously visible message, not jump to the new first row")
    XCTAssertTrue(element(app, "jump-to-latest").waitForExistence(timeout: 5))
    element(app, "jump-to-latest").tap()
    XCTAssertTrue(element(app, "message-long-539").waitForExistence(timeout: 10))
    app.terminate()
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }
  private func capture(_ scenario: String, _ appearance: String, variant: String? = nil) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if variant == "chips" { app.launchArguments += ["--fixture-code-chips"] }
    if variant == "markers" { app.launchArguments += ["--fixture-markers"] }
    if variant == "statuses" { app.launchArguments += ["--fixture-message-statuses"] }
    if variant == "plum" { app.launchArguments += ["--fixture-theme", "plum"] }
    if variant == "ax3" {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
      ]
    }
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 10))
    if variant == "chips" {
      XCTAssertTrue(
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "swift test"))
          .firstMatch.waitForExistence(timeout: 10))
    } else if variant == "markers" {
      let marker = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Context compacted")
      ).firstMatch
      XCTAssertTrue(marker.waitForExistence(timeout: 10))
    } else if variant == "statuses" {
      let applied = app.staticTexts.matching(identifier: "live-input-status").matching(
        NSPredicate(format: "label == %@", "Consumed by current run")
      ).firstMatch
      XCTAssertTrue(applied.waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "scheduled-wake-part").waitForExistence(timeout: 10))
    } else if scenario == "conversation-streaming" {
      let complete = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Stream complete")
      ).firstMatch
      XCTAssertTrue(
        complete.waitForExistence(timeout: 20), "Scripted deltas must reach a terminal write")
    } else if scenario == "conversation-tools" {
      // A settled turn's Activity band is collapsed (web `collapseOnSettle`); open it first.
      let band = element(app, "activity-band")
      XCTAssertTrue(position(band, in: app), "The tools band must be clear of the header")
      band.tap()
      XCTAssertTrue(element(app, "tool-cluster").waitForExistence(timeout: 10))
      element(app, "tool-cluster").tap()
      XCTAssertTrue(
        element(app, "jump-to-latest").waitForNonExistence(timeout: 3),
        "Expanding activity is not scrolling away")
      let call = element(app, "tool-call-sample-tool-1")
      XCTAssertTrue(call.waitForExistence(timeout: 5))
      call.tap()
      let load = element(app, "tool-load-full")
      XCTAssertTrue(load.waitForExistence(timeout: 5))
      if !load.isHittable { transcriptScroll(app).swipeUp() }
      load.tap()
      XCTAssertTrue(
        app.staticTexts.containing(
          NSPredicate(format: "label CONTAINS %@", "Full synthetic output loaded")
        ).firstMatch.waitForExistence(timeout: 10))
    } else if scenario == "conversation-long" {
      XCTAssertTrue(element(app, "message-long-539").waitForExistence(timeout: 10))
      // User scrolls away: incoming geometry must not drag them back to the bottom.
      transcriptScroll(app).swipeDown()
      let jump = element(app, "jump-to-latest")
      let dock = element(app, "composer")
      WaitFor.hittable(jump)
      WaitFor.hittable(dock)
      WaitFor.element(jump, "jump straddling dock, clear of transcript and input text") {
        control in
        guard dock.exists, !dock.frame.isEmpty, !control.frame.isEmpty else { return false }
        return control.frame.minY >= dock.frame.minY - control.frame.height
          && control.frame.minY < dock.frame.minY
          && control.frame.maxY > dock.frame.minY
          && control.frame.maxY <= self.element(app, "composer-field").frame.minY + 4
      }
    } else if scenario == "conversation-markdown" {
      XCTAssertTrue(element(app, "code-copy").waitForExistence(timeout: 10))
      XCTAssertTrue(element(app, "markdown-table").waitForExistence(timeout: 10))
    } else {
      XCTAssertTrue(element(app, "activity-band").waitForExistence(timeout: 10))
    }
    if scenario == "conversation-tools" {
      XCTAssertTrue(
        element(app, "jump-to-latest").waitForNonExistence(timeout: 5),
        "Tools at the bottom must not offer Jump to latest")
    }
    if (scenario == "conversation-transcript" && variant == nil)
      || scenario == "conversation-streaming"
    {
      WaitFor.value(element(app, "rename-conversation"), contains: "Idle")
      WaitFor.value(element(app, "rename-conversation"), contains: "sample:large")
    }
    XCTAssertTrue(
      element(app, "running-row-t-atlas-launch").waitForNonExistence(timeout: 5),
      "Settled detail must not remain in Running")
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
    app.terminate()
  }
  private func transcriptScroll(_ app: XCUIApplication) -> XCUIElement {
    app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
  }
}
