// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Drawing-only metadata: the text remains selectable and keeps its native link semantics.
struct InlineChipAttribute: TextAttribute {}

struct InlineChipRenderer: TextRenderer {
  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      for run in line {
        if run[InlineChipAttribute.self] != nil {
          let rect = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
          let path = Path(roundedRect: rect, cornerRadius: 5)
          context.fill(path, with: .color(WebColor.surfaceSubtle.color))
          context.stroke(path, with: .color(WebColor.line.color), lineWidth: 1)
        }
        context.draw(run)
      }
    }
  }
}
