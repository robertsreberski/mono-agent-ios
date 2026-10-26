// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Drawing-only metadata: the text remains selectable and keeps its native link semantics.
struct InlineChipAttribute: TextAttribute {}

enum InlineChipLayout {
  /// An SF Symbol attachment and its alt text can be separate layout runs. One image
  /// still needs one outline; an unmarked run separates it from the next image.
  static func bounds(_ runs: [(CGRect, Bool)]) -> [CGRect] {
    var result: [CGRect] = []
    var current: CGRect?
    for (rect, marked) in runs {
      if marked {
        current = current.map { $0.union(rect) } ?? rect
      } else if let bounds = current {
        result.append(bounds)
        current = nil
      }
    }
    if let current { result.append(current) }
    return result
  }
}

/// Used only for image placeholders, never ordinary/code-only prose.
struct InlineChipRenderer: TextRenderer {
  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      let bounds = InlineChipLayout.bounds(
        line.map {
          ($0.typographicBounds.rect, $0[InlineChipAttribute.self] != nil)
        })
      for rect in bounds {
        let path = Path(roundedRect: rect.insetBy(dx: 0, dy: -1), cornerRadius: 5)
        context.fill(path, with: .color(WebColor.surfaceSubtle.color))
        context.stroke(path, with: .color(WebColor.line.color), lineWidth: 1)
      }
      for run in line { context.draw(run) }
    }
  }
}
