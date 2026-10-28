// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgent

struct CronReplyJSONDisplayTests {
  @Test func newlineDenseJSONHasBoundedViewCount() {
    let display = CronReplyJSONDisplay(String(repeating: "\n", count: 16_000))
    #expect(display.lines.count == 1_000)
    #expect(display.limited)
  }
  @Test func boundedMultilineJSONRetainsLastLine() {
    let source = (0..<40).map { "key-\($0)" }.joined(separator: "\n") + "\nlastRetainedKey"
    let display = CronReplyJSONDisplay(source)
    #expect(display.lines.last == "lastRetainedKey")
    #expect(!display.limited)
  }
  @Test func byteBoundStillDisclosesTruncation() {
    let display = CronReplyJSONDisplay(String(repeating: "a", count: 20_000))
    #expect(display.lines.first?.utf8.count == 16_384)
    #expect(display.limited)
  }
}
