// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgentDesign

struct CodeCopyFeedbackTests {
  @Test func copyingPreservesSourceIncludingTerminalNewline() {
    let source = "print(42)\n"
    var feedback = CodeCopyFeedback()
    #expect(feedback.copy(source) == source)
    #expect(feedback.copied && feedback.generation == 1)
    #expect(feedback.copy(source) == source)
    #expect(feedback.copied && feedback.generation == 2)
    feedback.reset(generation: 1)
    #expect(feedback.copied)
    feedback.reset(generation: 2)
    #expect(!feedback.copied)
    #expect(feedback.generation == 2, "Reset must not trigger another haptic")
  }
  @Test func codeOnlyParagraphsAndHeadingsKeepExactSelectableText() {
    let document = RichDocument.parse("`npm test`\n\n# `npm test`")
    #expect(document.blocks.count == 2)
    for block in document.blocks {
      #expect(RichInlinePresentation.isCodeOnly(block.runs))
      #expect(RichInlinePresentation.text(block.runs[0], index: 0, count: 1) == "npm test")
    }
  }
  @Test func mixedTextNeverAddsEdgePaddingCharacters() {
    for source in ["`start` then", "before `end`", "`start` and `end`"] {
      let runs = RichDocument.parse(source).blocks.flatMap(\.runs)
      let text = runs.enumerated().map {
        RichInlinePresentation.text($0.element, index: $0.offset, count: runs.count)
      }.joined()
      #expect(text.first != "\u{2009}" && text.last != "\u{2009}")
      #expect(!RichInlinePresentation.isCodeOnly(runs))
    }
  }
}
