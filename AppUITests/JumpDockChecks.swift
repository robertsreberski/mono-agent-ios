// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// Shared Jump-to-latest dock proof. Jump overlays the dock's top edge without reserving
/// space: every dock surface keeps the same frame whether or not Jump is shown. Its 44 × 44
/// frame is the visible 36 pt circle (bottom-centred, straddling the dock edge) plus an 8 pt
/// reach above it; below the edge, only the circle itself is interactive.
@MainActor struct JumpDock {
  let app: XCUIApplication
  /// Dock surfaces whose geometry must not depend on Jump, besides the dock and input.
  let surfaces: [String]
  /// The transcript's newest message; Jump must land on it.
  let newest: String

  var jump: XCUIElement { element("jump-to-latest") }
  var dock: XCUIElement { element("composer") }
  var transcript: XCUIElement {
    app.scrollViews.matching(identifier: "conversation-transcript").firstMatch
  }
  private var ids: [String] { ["composer", "composer-field"] + surfaces }

  func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

  /// Settled frames of every dock surface: all laid out, no keyboard (the transcript drag
  /// dismisses it) and two consecutive reads equal, so no animation is mid-flight.
  func frames(file: StaticString = #filePath, line: UInt = #line) -> [String: CGRect] {
    WaitFor.absent(app.keyboards.firstMatch, file: file, line: line)
    var last: [String: CGRect] = [:]
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let current = Dictionary(
          uniqueKeysWithValues: ids.map { id in
            let target = element(id)
            return (id, target.exists ? target.frame : .null)
          })
        defer { last = current }
        return current.values.allSatisfy { !$0.isNull && !$0.isEmpty } && current == last
      }, object: nil)
    if XCTWaiter.wait(for: [settled], timeout: 20) != .completed {
      XCTFail("Dock surfaces did not settle: \(describe(last))", file: file, line: line)
    }
    return last
  }

  /// Where a jump tap lands in Jump's 44 × 44 frame.
  enum Tap {
    /// The visible circle (the accessibility activation point).
    case circle
    /// The reach directly above the circle, completing the 44 pt height.
    case above
    /// The reach beside the circle, above the dock edge, completing the 44 pt width.
    case beside
  }

  /// The visible circle's centre and radius: bottom-centred in Jump's frame.
  private func circle(_ frame: CGRect) -> (centre: CGPoint, radius: CGFloat) {
    (CGPoint(x: frame.midX, y: frame.maxY - 18), 18)
  }

  /// Scrolls away from the bottom and waits for Jump at its straddling mount.
  func reveal(file: StaticString = #filePath, line: UInt = #line) {
    WaitFor.hittable(transcript, file: file, line: line)
    transcript.swipeDown()
    WaitFor.hittable(jump, file: file, line: line)
    WaitFor.element(jump, "44 pt jump straddling the dock edge", file: file, line: line) {
      control in
      guard dock.exists, !dock.frame.isEmpty else { return false }
      let frame = control.frame
      let edge = dock.frame.minY
      let circleTop = frame.maxY - 36
      return frame.width == 44 && frame.height == 44
        && abs(frame.midX - dock.frame.midX) <= 0.5 && circleTop < edge && frame.maxY > edge
    }
  }

  /// Taps Jump and proves it lands on the newest message, clear of the dock.
  func jumpToLatest(
    at tap: Tap = .circle, file: StaticString = #filePath, line: UInt = #line
  ) {
    WaitFor.hittable(jump, file: file, line: line)
    let frame = jump.frame
    let offset: CGVector? =
      switch tap {
      case .circle: nil
      // 2 pt below the frame's top, 20 pt above the circle's centre: outside the circle.
      case .above: CGVector(dx: 22, dy: 2)
      // 2 pt in from the leading edge, 12 pt down. (The platform rounds the frame's very
      // corners out of the touch region; this point is clear of that rounding.)
      case .beside: CGVector(dx: 2, dy: 12)
      }
    if let offset {
      let point = CGPoint(x: frame.minX + offset.dx, y: frame.minY + offset.dy)
      let (centre, radius) = circle(frame)
      XCTAssertLessThan(
        point.y, dock.frame.minY, "Reach is above the dock edge", file: file, line: line)
      XCTAssertGreaterThan(
        hypot(point.x - centre.x, point.y - centre.y), radius + 1, "Reach is outside the circle",
        file: file, line: line)
      jump.coordinate(withNormalizedOffset: .zero).withOffset(offset).tap()
    } else {
      jump.tap()
    }
    WaitFor.absent(jump, file: file, line: line)
    let latest = element(newest)
    WaitFor.element(latest, "newest message \(newest) above the dock", file: file, line: line) {
      message in
      // Its bottom edge is on screen above the dock: the transcript reached the latest row.
      // (A tall message's centre may sit under the header, so hittability is not asked.)
      let header = element("conversation-header")
      guard dock.exists, header.exists, !message.frame.isEmpty, !header.frame.isEmpty else {
        return false
      }
      return message.frame.maxY <= dock.frame.minY && message.frame.maxY > header.frame.maxY
    }
  }

  /// Taps `row` beside the visible circle, below the dock edge but inside Jump's frame.
  func tapBesideCircle(
    _ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    WaitFor.hittable(jump, file: file, line: line)
    WaitFor.hittable(row, file: file, line: line)
    let frame = jump.frame
    let (centre, radius) = circle(frame)
    // 3 pt in from the bottom corner on whichever side the row covers.
    let candidates = [
      CGPoint(x: frame.minX + 3, y: frame.maxY - 3), CGPoint(x: frame.maxX - 3, y: frame.maxY - 3),
    ]
    guard let point = candidates.first(where: { row.frame.contains($0) }) else {
      XCTFail(
        "No point beside Jump inside the row: jump=\(frame) row=\(row.frame)", file: file,
        line: line)
      return
    }
    XCTAssertGreaterThan(point.y, dock.frame.minY, "Below the dock edge", file: file, line: line)
    XCTAssertGreaterThan(
      hypot(point.x - centre.x, point.y - centre.y), radius + 1, "Outside the visible circle",
      file: file,
      line: line)
    XCTAssertTrue(frame.contains(point), "Inside Jump's own frame", file: file, line: line)
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
  }

  /// The full proof: frames identical with and without Jump, Jump lands on the newest message,
  /// and Jump is shown again afterwards (left visible for capture and row taps).
  func assertGeometryIndependentOfJump(
    tap: Tap = .circle, file: StaticString = #filePath, line: UInt = #line
  ) {
    reveal(file: file, line: line)
    let shown = frames(file: file, line: line)
    jumpToLatest(at: tap, file: file, line: line)
    let hidden = frames(file: file, line: line)
    record("hidden=\(describe(hidden)) shown=\(describe(shown))")
    for id in ids {
      XCTAssertEqual(
        shown[id], hidden[id], "\(id) must not change when Jump appears", file: file, line: line)
    }
    reveal(file: file, line: line)
    let again = frames(file: file, line: line)
    for id in ids {
      XCTAssertEqual(again[id], hidden[id], "\(id) after Jump returns", file: file, line: line)
    }
  }

  private func describe(_ frames: [String: CGRect]) -> String {
    ids.map { "\($0):\(frames[$0].map { NSCoder.string(for: $0) } ?? "missing")" }
      .joined(separator: " ")
  }
  private func record(_ text: String) {
    print("JumpDock frames " + text)
    XCTContext.runActivity(named: "Dock frames with and without Jump") { activity in
      let attachment = XCTAttachment(string: text)
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }
}

@MainActor func captureJumpDock(
  _ app: XCUIApplication, scenario: String, appearance: String, variant: String = "jump"
) {
  let sidebar = screenshotChecksSidebar(app)
  let rendered = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in
      screenshotHasContent(XCUIScreen.main.screenshot(), checkSidebar: sidebar)
    }, object: nil)
  XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
  let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
  attachment.name = "synthetic-fixture__\(scenario)__\(appearance)__\(variant)"
  attachment.lifetime = .keepAlways
  XCTContext.runActivity(named: "Jump overlays the dock without moving it") { $0.add(attachment) }
}
