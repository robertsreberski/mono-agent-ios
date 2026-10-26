// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Testing

@testable import MonoAgentDesign

struct InlineChipLayoutTests {
  @Test func attachmentAndAltTextShareOneOutline() {
    let glyph = CGRect(x: 0, y: 1, width: 12, height: 12)
    let text = CGRect(x: 12, y: 0, width: 80, height: 14)
    #expect(InlineChipLayout.bounds([(glyph, true), (text, true)]) == [glyph.union(text)])
  }
  @Test func unmarkedRunsSeparateChips() {
    let first = CGRect(x: 0, y: 0, width: 20, height: 14)
    let second = CGRect(x: 30, y: 0, width: 20, height: 14)
    #expect(
      InlineChipLayout.bounds([(first, true), (.zero, false), (second, true)]) == [first, second])
    #expect(InlineChipLayout.bounds([(.zero, false)]).isEmpty)
    #expect(InlineChipLayout.bounds([]).isEmpty)
  }
}
