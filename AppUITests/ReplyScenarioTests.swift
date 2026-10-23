// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import XCTest

@MainActor final class ReplyScenarioTests: XCTestCase {
  func testFilesLight() { files("light") }
  func testFilesDark() { files("dark") }
  func testImagesLight() { images("light") }
  func testImagesDark() { images("dark") }
  func testSingleImageLight() { imageVariant("single", "light") }
  func testSingleImageDark() { imageVariant("single", "dark") }
  func testEmptyGalleryLight() { imageVariant("empty", "light") }
  func testEmptyGalleryDark() { imageVariant("empty", "dark") }
  private func imageVariant(_ variant: String, _ appearance: String) {
    let app = launch("conversation-images-" + variant, appearance)
    if variant == "single" {
      XCTAssertTrue(app.buttons["View sample-landscape-1.png"].waitForExistence(timeout: 10))
    } else {
      XCTAssertTrue(app.staticTexts["No images attached."].waitForExistence(timeout: 5))
      XCTAssertFalse(element(app, "reply-image-row").exists)
    }
    capture(app, "conversation-images", appearance, variant: variant)
    app.terminate()
  }
  func testRestartLight() { restart("light") }
  func testRestartDark() { restart("dark") }

  private func restart(_ appearance: String) {
    let app = launch("conversation-restart-card", appearance)
    let request = app.buttons.matching(identifier: "restart-request").firstMatch
    XCTAssertTrue(request.waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.buttons.matching(identifier: "restart-request").element(boundBy: 1).isEnabled)
    capture(app, "conversation-restart-card", appearance)
    request.tap()
    let confirm = app.buttons["restart-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["Restarting may interrupt active conversations, jobs and monitors."].exists)
    capture(app, "conversation-restart-card", appearance, variant: "confirmation")
    app.buttons["restart-cancel"].tap()
    XCTAssertFalse(element(app, "restart-outcome").exists)
    request.tap()
    confirm.tap()
    XCTAssertTrue(
      app.staticTexts["Restarted — agent is back online."].waitForExistence(timeout: 10))
    app.terminate()
  }

  private func images(_ appearance: String) {
    let app = launch("conversation-images", appearance)
    let first = app.buttons["View sample-landscape-1.png"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    capture(app, "conversation-images", appearance)
    first.tap()
    XCTAssertTrue(element(app, "reply-lightbox").waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Share sample-landscape-1.png"].exists)
    capture(app, "conversation-images", appearance, variant: "lightbox")
    app.buttons["Next image"].tap()
    XCTAssertTrue(app.buttons["Share sample-landscape-2.png"].waitForExistence(timeout: 5))
    let zoom = app.descendants(matching: .any).matching(identifier: "reply-image-zoom")
      .allElementsBoundByIndex.first { $0.isHittable }
    XCTAssertNotNil(zoom)
    zoom?.pinch(withScale: 2, velocity: 1)
    let diagnostic = XCTAttachment(screenshot: app.screenshot())
    diagnostic.name = "zoom-diagnostic"
    diagnostic.lifetime = .keepAlways
    add(diagnostic)
    XCTAssertNotEqual(zoom?.value as? String, "Zoom 100 percent")
    XCTAssertTrue(
      (zoom?.value as? String)?.hasPrefix("Zoom ") == true,
      "Zoom AX value: \(String(describing: zoom?.value)); \(zoom?.debugDescription ?? "absent")")
    zoom?.tap(withNumberOfTaps: 2, numberOfTouches: 1)
    app.swipeLeft()
    XCTAssertTrue(app.buttons["Share sample-landscape-3.png"].waitForExistence(timeout: 5))
    app.buttons["Close image"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    app.terminate()
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func launch(_ scenario: String, _ appearance: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--scenario", scenario, "--appearance", appearance, "--reset-test-data",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    XCTAssertTrue(element(app, "scenario-ready").waitForExistence(timeout: 20))
    XCTAssertTrue(element(app, "conversation-transcript").waitForExistence(timeout: 5))
    return app
  }
  private func capture(
    _ app: XCUIApplication, _ scenario: String, _ appearance: String, variant: String? = nil
  ) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name =
      "synthetic-fixture__" + scenario + "__" + appearance + (variant.map { "__" + $0 } ?? "")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func files(_ appearance: String) {
    let app = launch("conversation-reply-files", appearance)
    let unavailable = app.buttons["Download archive.txt"]
    XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
    unavailable.tap()
    XCTAssertTrue(app.staticTexts["This file is no longer available."].waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "reply-failure").exists)
    capture(app, "conversation-reply-files", appearance)
    let report = app.buttons["Download release-notes.txt"]
    report.tap()
    XCTAssertTrue(app.buttons["Save to Files"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Share"].exists)
    XCTAssertTrue(app.buttons["Preview"].exists)
    app.terminate()
  }
}
