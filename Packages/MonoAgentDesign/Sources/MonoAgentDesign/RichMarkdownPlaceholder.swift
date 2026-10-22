// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// PLACEHOLDER slot for the future rich Markdown renderer (`RichTextDocumentView`).
/// It shows the raw source verbatim and is labelled as a placeholder, so nobody mistakes
/// it for rendered output. It does not parse Markdown, load links or render attachments.
public struct RichMarkdownPlaceholder: View {
  nonisolated public static let label = "Rich Markdown placeholder"

  private let source: String

  public init(source: String) { self.source = source }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Label(Self.label, systemImage: "doc.richtext")
        .designFont(.caption)
        .foregroundStyle(.secondary)
      Text(verbatim: source)
        .designFont(.code)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(DesignSpacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignColor.contentSurface, in: shape)
    .overlay {
      shape.strokeBorder(
        DesignColor.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Placeholder. Rich rendering arrives in a later update.")
  }
}

#if DEBUG
  #Preview("Markdown placeholder") {
    DesignPreviewMatrix {
      RichMarkdownPlaceholder(source: "## Summary\n- First item\n- `code`")
    }
  }

  #Preview("Markdown placeholder — dark") {
    DesignPreviewMatrix {
      RichMarkdownPlaceholder(source: "**Bold** and _italic_ stay raw here.")
    }
    .preferredColorScheme(.dark)
  }
#endif
