// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// Shared geometry proof: the full 44 pt jump target, not just its visible circle, must
/// clear the dock's first interactive row. A straddling circle may overlap only its padding.
@MainActor func assertJumpClearsDockRow(_ app: XCUIApplication, row: XCUIElement) {
  let jump = app.descendants(matching: .any)["jump-to-latest"].firstMatch
  let dock = app.descendants(matching: .any)["composer"].firstMatch
  WaitFor.hittable(jump)
  WaitFor.hittable(row)
  WaitFor.element(jump, "44 pt jump target clears the first dock action") { control in
    guard dock.exists, row.exists, !dock.frame.isEmpty, !row.frame.isEmpty,
      !control.frame.isEmpty
    else { return false }
    return control.frame.height >= 44 && control.frame.minY < dock.frame.minY
      && control.frame.maxY > dock.frame.minY && control.frame.maxY <= row.frame.minY
  }
}

@MainActor func captureJumpDock(_ app: XCUIApplication, scenario: String, appearance: String) {
  let sidebar = screenshotChecksSidebar(app)
  let rendered = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in
      screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: sidebar)
    }, object: nil)
  XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
  let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
  attachment.name = "synthetic-fixture__\(scenario)__\(appearance)__jump"
  attachment.lifetime = .keepAlways
  XCTContext.runActivity(named: "Jump control clears the first dock action") { $0.add(attachment) }
}
