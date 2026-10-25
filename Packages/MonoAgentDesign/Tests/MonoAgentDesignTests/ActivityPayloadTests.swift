// SPDX-License-Identifier: GPL-3.0-only
import Testing
import UIKit

@testable import MonoAgentDesign

@MainActor @Suite(.serialized) struct ActivityPayloadTests {
  @Test(arguments: ["Input", "Output"])
  func copyIncludesTextBeyondTheDisplayCap(label: String) {
    let previous = UIPasteboard.general.items
    defer { UIPasteboard.general.items = previous }
    let text = String(repeating: "Fictional payload 🦉\n", count: 2000) + "End of complete payload"
    #expect(text.utf8.count > 16_384)
    ActivityPayloadBlock(label, text: text).copy()
    #expect(UIPasteboard.general.string == text)
  }
}
