// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor
final class ScenarioTests: XCTestCase {
  func testConnectionEmptyLight() { capture("connection-empty", "light") }
  func testConnectionEmptyDark() { capture("connection-empty", "dark") }
  func testConnectionFailedLight() { capture("connection-failed", "light") }
  func testConnectionFailedDark() { capture("connection-failed", "dark") }
  func testConsoleOnlineLight() { capture("console-online", "light") }
  func testConsoleOnlineDark() { capture("console-online", "dark") }

  private func capture(_ scenario: String, _ appearance: String) {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--reset-test-data", "--appearance", appearance,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any)[scenario].firstMatch.waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.descendants(matching: .any)["scenario-ready"].firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Ready"].exists, "Test readiness must not add visible text")
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
    attachment.name = "synthetic-fixture__\(scenario)__\(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }
}

/// A structural guard, not a pixel snapshot: ignore system bars and reject a flat blank frame.
private func screenshotHasContent(_ screenshot: XCUIScreenshot) -> Bool {
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
