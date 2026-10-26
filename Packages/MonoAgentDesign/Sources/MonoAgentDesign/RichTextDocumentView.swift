// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// The application owns this boundary; no dependency-specific types reach feature views.
///
/// Styled as the web `.markdown` block: 13.5/1.62 prose (phones), .85em block rhythm, 1.45em
/// list indent, bold UA heading scale, framed tables and rail-coloured code blocks.
public struct RichTextDocumentView: View {
  private let source: String
  private let fill: Bool
  private let identity: String
  private let cacheKey: String
  private let streaming: Bool
  private let initial: RichDocument?
  @State private var rendering = RichDocumentRendering()
  @Environment(\.consoleTheme) private var theme
  @Environment(\.horizontalSizeClass) private var sizeClass
  @ScaledMetric(relativeTo: .body) private var proseSize: CGFloat = 13.5
  /// `fill: false` sizes the document to its text (the user bubble); content fills the column.
  public init(
    source: String, fill: Bool = true, identity: String = "document", streaming: Bool = false
  ) {
    self.source = source
    self.identity = identity
    self.fill = fill
    self.streaming = streaming
    cacheKey = RichRenderingCache.key(source: source, identity: identity)
    initial = RichRenderingCache.initial(source: source, key: cacheKey)
  }
  private var em: CGFloat { proseSize }
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let document = initial ?? rendering.document {
        ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
          blockView(block)
            .padding(.top, index == 0 ? 0 : gap(before: block, after: document.blocks[index - 1]))
        }
        if document.limited {
          Label("Large or complex document · bounded text preview", systemImage: "info.circle")
            .webFont(.messageAction).foregroundStyle(WebColor.textMuted.color)
            .padding(.top, 0.85 * em)
        }
      } else {
        Text(verbatim: String(decoding: source.utf8.prefix(1000), as: UTF8.self))
          .webFont(.prose).foregroundStyle(WebColor.text.color)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    .onChange(of: cacheKey) {
      rendering.submit(source: source, key: cacheKey, streaming: streaming)
    }
    .onChange(of: streaming) {
      rendering.submit(source: source, key: cacheKey, streaming: streaming)
    }
    .task(id: identity) {
      await rendering.run(source: source, key: cacheKey, streaming: streaming)
    }
  }
  /// `.markdown p, ul, pre { margin-bottom: .85em }`, `li + li { margin-top: .3em }`.
  private func gap(before block: RichDocument.Block, after previous: RichDocument.Block) -> CGFloat
  {
    if !block.prefix.isEmpty && !previous.prefix.isEmpty { return 0.3 * em }
    if !previous.prefix.isEmpty && block.prefix.isEmpty && block.depth > 0 { return 0.3 * em }
    if case .heading(let level) = block.kind { return level <= 2 ? 1.1 * em : 0.95 * em }
    if case .heading(let level) = previous.kind { return 0.67 * headingSize(level) }
    return 0.85 * em
  }
  private func headingSize(_ level: Int) -> CGFloat {
    switch level {
    case 1: 2 * em
    case 2: 1.5 * em
    case 3: 1.17 * em
    case 4: em
    case 5: 0.83 * em
    default: 0.67 * em
    }
  }
  @ViewBuilder private func blockView(_ block: RichDocument.Block) -> some View {
    switch block.kind {
    case .code(let language):
      CodeDocumentView(
        source: block.runs.map(\.text).joined(), language: language, style: .block)
    case .rule:
      Rectangle().fill(WebColor.line.color).frame(height: 1)
    case .table:
      MarkdownTableView(rows: block.rows, inlineText: inlineContent, compact: sizeClass != .regular)
    case .heading(let level):
      inlineContent(block.runs)
        .font(.system(size: headingSize(level), weight: .bold))
        .tracking(level <= 2 ? -0.01 * headingSize(level) : 0)
        .foregroundStyle(WebColor.text.color)
        .accessibilityAddTraits(.isHeader).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph, .quote:
      let indent = CGFloat(max(0, min(block.depth, 6) - 1)) * 1.45 * em
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        if !block.prefix.isEmpty {
          if block.prefix == "☑" || block.prefix == "☐" {
            Image(systemName: block.prefix == "☑" ? "checkmark.square.fill" : "square")
              .font(.system(size: em))
              .foregroundStyle(
                block.prefix == "☑" ? theme.palette.accent.color : WebColor.textMuted.color
              )
              .frame(width: 1.45 * em, alignment: .leading)
              .accessibilityLabel(block.prefix == "☑" ? "Completed" : "Not completed")
          } else {
            Text(block.prefix)
              .webFont(.prose)
              .foregroundStyle(WebColor.text.color)
              .frame(width: 1.45 * em, alignment: block.prefix.count > 1 ? .leading : .center)
          }
        } else if block.depth > 0 && block.kind != .quote {
          Color.clear.frame(width: 1.45 * em, height: 1)
        }
        inlineContent(block.runs)
          .webFont(.prose)
          // CSS line boxes retain half-leading above/below even a single line; SwiftUI's
          // lineSpacing only inserts the leading BETWEEN lines.
          .padding(.vertical, (1.62 - WebType.naturalLineHeight) * em / 2)
          .foregroundStyle(block.kind == .quote ? WebColor.textSoft.color : WebColor.text.color)
          .textSelection(.enabled)
          .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
          .padding(.leading, block.kind == .quote ? 13 : 0)
          .overlay(alignment: .leading) {
            if block.kind == .quote {
              Rectangle().fill(WebColor.lineStrong.color).frame(width: 2)
            }
          }
      }
      .padding(.leading, block.kind == .quote ? 0 : indent)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
  /// Keep ordinary/code-only paragraphs on SwiftUI's native cached attributed-text path.
  /// A renderer on every prose run exceeded the long-markdown scrolling budget.
  @ViewBuilder private func inlineContent(_ runs: [RichDocument.Run]) -> some View {
    if runs.contains(where: \.image) {
      inlineText(runs).textRenderer(InlineChipRenderer())
    } else {
      Text(attributed(runs))
    }
  }
  /// Interpolation preserves native selection and links while attaching drawing-only attributes.
  private func inlineText(_ runs: [RichDocument.Run]) -> Text {
    runs.reduce(Text("")) { text, run in
      let part = Text(attributed([run]))
      if run.image {
        let chip = Text("\(Image(systemName: "photo")) \(part)")
          .foregroundColor(WebColor.textMuted.color)
          .customAttribute(InlineChipAttribute())
        return Text("\(text)\(chip)")
      }
      return Text("\(text)\(part)")
    }
  }
  private func attributed(_ runs: [RichDocument.Run]) -> AttributedString {
    RichRenderingCache.attributed(.init(runs, em: Double(em), theme: theme.rawValue)) {
      runs.reduce(into: AttributedString()) { value, run in
        var part = AttributedString(
          run.code || run.image ? "\u{2009}" + run.text + "\u{2009}" : run.text)
        var intent: InlinePresentationIntent = []
        if run.bold { intent.insert(.stronglyEmphasized) }
        if run.italic { intent.insert(.emphasized) }
        if run.code {
          intent.insert(.code)
          part.font = .system(size: 0.88 * em, design: .monospaced)
          part.backgroundColor = WebColor.surfaceSubtle.color

        }
        if run.strike {
          intent.insert(.strikethrough)
          part.foregroundColor = WebColor.textMuted.color
        }
        part.inlinePresentationIntent = intent
        if let destination = run.link {
          part.link = URL(string: destination)
          part.foregroundColor = theme.palette.accent.color
          part.underlineStyle = .single
        }
        value += part
      }
    }
  }
}

/// Web `.markdown-table`: framed radius 8 on `--surface`, subtle header row in soft 650 text with
/// a line-strong rule, 1 px row lines, alternate rows washed with surface-hover at 55%.
struct MarkdownTableView<InlineContent: View>: View {
  let rows: [[[RichDocument.Run]]]
  let inlineText: ([RichDocument.Run]) -> InlineContent
  let compact: Bool
  @ScaledMetric(relativeTo: .footnote) private var tableLeading: CGFloat = 2.5
  private var columns: Int { rows.map(\.count).max() ?? 0 }
  private var grid: some View {
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        // Opaque row fills (alternate rows pre-mixed) overlap by half a point so adjacent
        // cells never show a seam.
        let fill: Color? =
          index == 0
          ? WebColor.surfaceSubtle.color
          : index % 2 == 0 ? WebColor.surfaceHover.mixed(55, with: WebColor.surface).color : nil
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            inlineText(column < row.count ? row[column] : [])
              .webFont(.table)
              .fontWeight(index == 0 ? .semibold : .regular)
              .foregroundStyle(index == 0 ? WebColor.textSoft.color : WebColor.text.color)
              .lineLimit(index == 0 ? 1 : nil)
              .padding(.vertical, (compact ? 6 : 7) + tableLeading)
              .padding(.horizontal, compact ? 8 : 10)
              .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
              .background { fill.map { $0.padding(.horizontal, -0.5) } }
              .overlay(alignment: .bottom) {
                if index < rows.count - 1 {
                  Rectangle()
                    .fill(index == 0 ? WebColor.lineStrong.color : WebColor.line.color)
                    .frame(height: 1)
                    .padding(.horizontal, -0.5)
                }
              }
              .textSelection(.enabled)
          }
        }
      }
    }
  }
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    // Fill the column when the columns fit; otherwise scroll sideways at natural widths
    // (web: width 100%, min-width max-content, overflow contained).
    ViewThatFits(in: .horizontal) {
      grid
      ScrollView(.horizontal) { grid }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
    .background(WebColor.surface.color, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
    .accessibilityLabel("Table").accessibilityIdentifier("markdown-table")
  }
}

/// Horizontal, selectable code. Copy preserves the complete supplied value, not the preview.
///
/// `.block` is the web markdown `pre`: rail fill, 1 px line, radius 10, padding 13×15 and a
/// Copy action inside the top-right corner. `.payload` is the quieter tool/job payload panel.
public struct CodeDocumentView: View {
  @Environment(\.webMaterial) private var material
  @State private var copied = false
  public enum Style: Sendable { case block, payload }
  private let source: String
  private let language: String
  private let style: Style
  @Environment(\.consoleTheme) private var theme
  public init(source: String, language: String = "Code", style: Style = .payload) {
    self.source = source
    self.language = language
    self.style = style
  }
  private var display: String { String(decoding: source.utf8.prefix(16_384), as: UTF8.self) }
  public var body: some View {
    switch style {
    case .block: block
    case .payload: payload
    }
  }
  private var block: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      ScrollView(.horizontal) {
        // The parser supplies a terminal newline; unlike HTML pre, Text lays it out
        // as another empty row. Remove it only for display; Copy keeps the full source.
        Text(verbatim: display.hasSuffix("\n") ? String(display.dropLast()) : display)
          .webFont(.code)
          .foregroundStyle(WebColor.codeText.color)
          .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
          .padding(.vertical, 13).padding(.horizontal, 15)
      }
      .padding(.trailing, 44)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.palette.rail.color, in: shape)
      .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
      .accessibilityLabel("\(language) code").accessibilityIdentifier("code-content")
      .overlay(alignment: .topTrailing) {
        Button {
          UIPasteboard.general.string = source
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 12))
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(WebColor.codeText.color)
        .accessibilityLabel("Copy code").accessibilityValue(copied ? "Copied" : "")
        .accessibilityIdentifier("code-copy")
        .sensoryFeedback(.success, trigger: copied)
        .task(id: copied) {
          guard copied else { return }
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          copied = false
        }
      }
      if source.utf8.count > 16_384 {
        Text("Display limited to 16,384 UTF-8 bytes. Copy includes all supplied text.")
          .webFont(.messageAction).foregroundStyle(material.textMuted.color)
      }
    }
  }
  private var payload: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(language.isEmpty ? "Code" : language)
          .webFont(.activityLabel).foregroundStyle(material.textMuted.color)
        Spacer()
        MessageActionButton("Copy", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = source
        }
        .accessibilityLabel("Copy code").accessibilityIdentifier("code-copy")
      }
      ScrollView(.horizontal) {
        Text(verbatim: display).font(.system(size: 10, design: .monospaced))
          .lineSpacing(3)
          .foregroundStyle(WebColor.text.color)
          .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
      }.accessibilityLabel("\(language) code").accessibilityIdentifier("code-content")
      if source.utf8.count > 16_384 {
        Text("Display limited to 16,384 UTF-8 bytes. Copy includes all supplied text.")
          .webFont(.messageAction).foregroundStyle(material.textMuted.color)
      }
    }
    .padding(.vertical, 6).padding(.horizontal, 10)
    .webLayeredSurface(
      shape, fill: theme.palette.canvas.mixed(55, with: WebColor.surface).color,
      stroke: WebColor.line.color)
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
