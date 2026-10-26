// SPDX-License-Identifier: GPL-3.0-only

/// One generation per copy tap: resets cannot produce feedback or expire a newer tap.
struct CodeCopyFeedback: Sendable, Equatable {
  private(set) var generation = 0
  private(set) var copied = false
  mutating func copy(_ source: String) -> String {
    generation += 1
    copied = true
    return source
  }
  mutating func reset(generation: Int) {
    guard generation == self.generation else { return }
    copied = false
  }
}

/// Padding inside mixed prose is visual spacing, never a leading/trailing copied character.
enum RichInlinePresentation {
  static func text(_ run: RichDocument.Run, index: Int, count: Int) -> String {
    guard run.code else { return run.text }
    return (index > 0 ? "\u{2009}" : "") + run.text + (index < count - 1 ? "\u{2009}" : "")
  }
  static func isCodeOnly(_ runs: [RichDocument.Run]) -> Bool {
    runs.count == 1 && runs[0].code
  }
}
