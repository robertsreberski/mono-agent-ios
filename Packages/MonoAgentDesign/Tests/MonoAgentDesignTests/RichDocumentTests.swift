// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentDesign

struct RichDocumentTests {
  @Test func gfmAndInlineStyles() {
    let value = RichDocument.parse(
      "# Heading\n\n**Bold** _italic_ ~~gone~~ `code` [link](https://example.com)\n\n- [x] Done\n- [ ] Later\n\n| A | B |\n| --- | --- |\n| one | two |\n\n> Quote\n\n---\n\n```swift\nprint(42)\n```"
    )
    #expect(!value.limited)
    #expect(value.blocks.contains { $0.kind == .heading(1) })
    #expect(value.blocks.contains { $0.kind == .table && $0.rows.count == 2 })
    #expect(value.blocks.contains { $0.kind == .code("swift") })
    #expect(value.blocks.contains { $0.prefix == "☑" })
    let runs = value.blocks.flatMap(\.runs)
    #expect(runs.contains { $0.bold })
    #expect(runs.contains { $0.italic })
    #expect(runs.contains { $0.strike })
    #expect(runs.contains { $0.code })
    #expect(runs.contains { $0.link == "https://example.com" })
  }
  @Test func imagesKeepAltTextAndOnlyAnEnclosingValidatedLink() {
    let value = RichDocument.parse(
      "Before ![A fictional garden](https://example.com/photo.png) after.\n\n[![](https://example.com/empty.png)](https://example.com)"
    )
    let images = value.blocks.flatMap(\.runs).filter(\.image)
    #expect(images.map(\.text) == ["A fictional garden", "Image"])
    #expect(images.map(\.link) == [nil, "https://example.com"])
    #expect(!value.blocks.flatMap(\.runs).contains { $0.text.contains("photo.png") })
  }
  @Test func imageAltIsBoundedAndUnsafeOuterLinksStayInert() {
    let value = RichDocument.parse(
      "[![" + String(repeating: "a", count: 201)
        + "](https://example.com/image.png)](javascript:alert)")
    let image = value.blocks.flatMap(\.runs).first { $0.image }
    #expect(image?.text.count == 200)
    #expect(image?.text.hasSuffix("…") == true)
    #expect(image?.link == nil)
  }
  @Test func nestedTaskListsKeepTheirDepthAndCompletionState() {
    let value = RichDocument.parse("- [x] Ready\n  - [ ] Nested\n- Ordinary")
    #expect(value.blocks.map(\.prefix) == ["☑", "☐", "•"])
    #expect(value.blocks.map(\.depth) == [1, 2, 1])
  }
  @Test func htmlIsLiteralAndUnsafeLinksAreNeverActions() {
    let value = RichDocument.parse(
      "<script>alert('sample')</script>\n\n[bad](javascript:alert) <b>literal</b>")
    #expect(value.blocks.contains { $0.kind == .code("HTML · shown as text") })
    #expect(value.blocks.flatMap(\.runs).contains { $0.text == "<b>" })
    #expect(value.blocks.flatMap(\.runs).allSatisfy { $0.link == nil })
  }
  @Test func adversarialFixturesHaveBoundedWorkAndExplicitNotice() {
    let fixtures = [
      String(repeating: "long", count: 100_000),
      String(repeating: ">", count: 5000) + " deep",
      String(repeating: " ", count: 10000) + "- nested",
      String(repeating: "| x ", count: 5000),
      String(repeating: "[", count: 40_000),
      "a" + String(repeating: "\u{301}", count: 200_000),
      String(repeating: "[nested ", count: 200) + String(repeating: "]", count: 200),
      String(repeating: "| a | b |\n", count: 4000),
    ]
    let started = Date()
    for source in fixtures {
      let document = RichDocument.parse(source)
      #expect(document.limited)
      #expect(document.blocks.count <= 300)
      #expect(
        document.blocks.flatMap(\.runs).reduce(0) { $0 + $1.text.count }
          <= RichDocument.maximumBytes)
    }
    #expect(Date().timeIntervalSince(started) < 5)
  }
}
