// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// Waited UI assertions shared by the XCUI suites. An accessibility snapshot can lag the
/// interaction that changed it, so a value, label, enabled, selected or focus state is polled
/// until it matches (or the timeout expires) instead of being read once.
@MainActor
enum WaitFor {
  /// Waits until `condition` holds for `element`. Records a failure at the caller otherwise.
  @discardableResult
  static func element(
    _ element: XCUIElement, timeout: TimeInterval = 10, _ description: String,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor (XCUIElement) -> Bool
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in element.exists && condition(element) }, object: nil)
    let met = XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    if !met {
      let value = element.exists ? "\(element.label) / \(element.value ?? "nil")" : "missing"
      XCTFail("Timed out waiting for \(description) (last: \(value))", file: file, line: line)
    }
    return met
  }

  /// The accessibility value contains `text`.
  @discardableResult
  static func value(
    _ element: XCUIElement, contains text: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(element, timeout: timeout, "value containing “\(text)”", file: file, line: line) {
      ($0.value as? String ?? "").contains(text)
    }
  }

  /// The accessibility value does not contain `text`.
  @discardableResult
  static func value(
    _ element: XCUIElement, lacks text: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(element, timeout: timeout, "value without “\(text)”", file: file, line: line) {
      !($0.value as? String ?? "").contains(text)
    }
  }

  /// The accessibility label contains `text`.
  @discardableResult
  static func label(
    _ element: XCUIElement, contains text: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(element, timeout: timeout, "label containing “\(text)”", file: file, line: line) {
      $0.label.contains(text)
    }
  }

  @discardableResult
  static func enabled(
    _ element: XCUIElement, _ enabled: Bool = true, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(
      element, timeout: timeout, enabled ? "enabled" : "disabled", file: file, line: line
    ) { $0.isEnabled == enabled }
  }

  @discardableResult
  static func selected(
    _ element: XCUIElement, _ selected: Bool = true, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(
      element, timeout: timeout, selected ? "selected" : "not selected", file: file, line: line
    ) { $0.isSelected == selected }
  }

  @discardableResult
  static func hittable(
    _ element: XCUIElement, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    Self.element(element, timeout: timeout, "hittable", file: file, line: line) { $0.isHittable }
  }

  /// The element is gone or covered by another surface (not hittable).
  @discardableResult
  static func covered(
    _ element: XCUIElement, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !element.exists || !element.isHittable }, object: nil)
    let met = XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    if !met { XCTFail("Timed out waiting for the element to be covered", file: file, line: line) }
    return met
  }

  /// The element disappears (or never appears) within the timeout.
  @discardableResult
  static func absent(
    _ element: XCUIElement, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !element.exists }, object: nil)
    let met = XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    if !met { XCTFail("Timed out waiting for the element to disappear", file: file, line: line) }
    return met
  }
}
