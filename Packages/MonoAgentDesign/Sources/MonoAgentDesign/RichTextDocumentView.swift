// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// The application owns this boundary; no dependency-specific types reach feature views.
public struct RichTextDocumentView: View {
  private let source: String
  @State private var document: RichDocument?
  public init(source: String) { self.source = source }
  public var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      if let document {
        ForEach(document.blocks) { block in
          blockView(block).padding(.leading, CGFloat(min(block.depth, 6)) * DesignSpacing.sm)
        }
        if document.limited {
          Label("Large or complex document · bounded text preview", systemImage: "info.circle")
            .designFont(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text(verbatim: String(decoding: source.utf8.prefix(1000), as: UTF8.self)).designFont(.body)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: source) {
      let input = source
      let parsed = await Task.detached(priority: .userInitiated) { RichDocument.parse(input) }.value
      guard !Task.isCancelled else { return }
      document = parsed
    }
  }
  @ViewBuilder private func blockView(_ block: RichDocument.Block) -> some View {
    switch block.kind {
    case .code(let language):
      CodeDocumentView(source: block.runs.map(\.text).joined(), language: language)
    case .rule: Divider()
    case .table:
      ScrollView(.horizontal) {
        Grid(
          alignment: .topLeading, horizontalSpacing: DesignSpacing.lg,
          verticalSpacing: DesignSpacing.sm
        ) {
          ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(attributed(cell)).designFont(.body).fontWeight(
                  index == 0 ? .semibold : .regular
                )
                .frame(minWidth: 90, maxWidth: 260, alignment: .leading).textSelection(.enabled)
              }
            }
            if index == 0 { Divider() }
          }
        }.padding(DesignSpacing.sm)
      }
      .accessibilityLabel("Table").accessibilityIdentifier("markdown-table")
    case .heading(let level):
      Text(attributed(block.runs)).designFont(level < 3 ? .sectionTitle : .headline)
        .accessibilityAddTraits(.isHeader).textSelection(.enabled)
    case .paragraph, .quote:
      HStack(alignment: .top, spacing: DesignSpacing.sm) {
        if !block.prefix.isEmpty {
          Text(block.prefix).accessibilityLabel(
            block.prefix == "☑" ? "Completed" : block.prefix == "☐" ? "Not completed" : block.prefix
          )
        }
        if block.kind == .quote {
          Image(systemName: "quote.opening").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        Text(attributed(block.runs)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.designFont(.body).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func attributed(_ runs: [RichDocument.Run]) -> AttributedString {
    runs.reduce(into: AttributedString()) { value, run in
      var part = AttributedString(run.text)
      var intent: InlinePresentationIntent = []
      if run.bold { intent.insert(.stronglyEmphasized) }
      if run.italic { intent.insert(.emphasized) }
      if run.code {
        intent.insert(.code)
        part.font = .system(.body, design: .monospaced)
      }
      if run.strike { intent.insert(.strikethrough) }
      part.inlinePresentationIntent = intent
      if let destination = run.link { part.link = URL(string: destination) }
      value += part
    }
  }
}

/// Horizontal, selectable code. Copy preserves the complete supplied value, not the preview.
public struct CodeDocumentView: View {
  private let source: String
  private let language: String
  @State private var copied = false
  public init(source: String, language: String = "Code") {
    self.source = source
    self.language = language
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      HStack {
        Text(language.isEmpty ? "Code" : language).designFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
          UIPasteboard.general.string = source
          copied = true
        }.buttonStyle(.bordered).accessibilityLabel("Copy code").accessibilityIdentifier(
          "code-copy")
      }
      ScrollView(.horizontal) {
        Text(verbatim: String(decoding: source.utf8.prefix(16_384), as: UTF8.self)).designFont(
          .code
        )
        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
      }.accessibilityLabel("\(language) code").accessibilityIdentifier("code-content")
      if source.utf8.count > 16_384 {
        Text("Display limited to 16,384 UTF-8 bytes. Copy includes all supplied text.").designFont(
          .caption)
      }
    }.padding(DesignSpacing.md).background(
      DesignColor.contentSurface, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
  }
}
#if DEBUG
  #Preview("Rich document") {
    DesignPreviewMatrix {
      RichTextDocumentView(
        source:
          "## Summary\n- [x] Ready\n- **Strong** and `code`\n\n| Item | State |\n| --- | --- |\n| Demo | Ready |\n\n```swift\nprint(42)\n```"
      )
    }
  }
  #Preview("Code — accessibility") {
    CodeDocumentView(source: "let sample = 42").dynamicTypeSize(.accessibility3)
  }
#endif
