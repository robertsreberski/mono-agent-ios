// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

public struct ContextDisplayContent: Sendable, Equatable {
  public struct Row: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) {
      self.label = label
      self.value = value
    }
  }
  public struct TokenRow: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var input: String
    public var cached: String
    public var output: String
    public init(_ label: String, input: String, cached: String, output: String) {
      self.label = label
      self.input = input
      self.cached = cached
      self.output = output
    }
  }
  public var tokens: [TokenRow] = []
  public var costs: [Row] = []
  public var badge: String
  public var figure: String
  public var status: String
  public var percent: Double?
  public var note: String?
  public var rows: [Row]
  public init(
    badge: String, figure: String, status: String, percent: Double? = nil, note: String? = nil,
    rows: [Row] = []
  ) {
    self.badge = badge
    self.figure = figure
    self.status = status
    self.percent = percent
    self.note = note
    self.rows = rows
  }
}

/// Value-only context/cost disclosure. May be placed in a header, toolbar popover or composer.
/// Unknown values arrive as words, never as an invented zero-width progress measurement.
public struct ContextDisplay: View {
  private let content: ContextDisplayContent
  @Binding private var expanded: Bool
  private let detailOnly: Bool
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.consoleTheme) private var theme
  public init(_ content: ContextDisplayContent, expanded: Binding<Bool>, detailOnly: Bool = false) {
    self.content = content
    _expanded = expanded
    self.detailOnly = detailOnly
  }
  public var body: some View {
    if detailOnly {
      details
    } else {
      ContentDisclosure("context-display", expanded: $expanded) {
        details
      } label: {
        Label("Context · " + content.badge, systemImage: "chart.pie")
          .webFont(.contextNote)
          .accessibilityLabel("Context usage: " + content.figure + ". " + content.status)
      }
    }
  }
  private var details: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Context window").webFont(.contextEyebrow).foregroundStyle(WebColor.textMuted.color)
        let figure = content.figure.components(separatedBy: " / ")
        let figureLayout =
          typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        figureLayout {
          WebFlowLayout(spacing: typeSize.isAccessibilitySize ? 8 : 4, lineSpacing: 4) {
            Text(figure.first ?? content.figure)
              .webFont(sizeClass == .regular ? .contextFigureRegular : .contextFigure)
              .foregroundStyle(WebColor.text.color)
            if figure.count == 2 {
              Text("/ " + figure[1]).webFont(.contextNote).foregroundStyle(WebColor.textMuted.color)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if content.percent != nil {
            Text(content.badge).webFont(.optionID).fontWeight(.bold)
              .foregroundStyle(theme.palette.accent.color).fixedSize()
          }
        }.textSelection(.enabled)
        Text(content.status).webFont(.contextTrigger).foregroundStyle(WebColor.textMuted.color)
        if let percent = content.percent, percent.isFinite {
          GeometryReader { proxy in
            Capsule().fill(WebColor.surfaceSubtle.color)
              .overlay(alignment: .leading) {
                Capsule().fill(percent >= 85 ? WebColor.danger.color : theme.palette.accent.color)
                  .frame(width: proxy.size.width * min(1, max(0, percent / 100)))
              }
          }.frame(height: sizeClass == .regular ? 6 : 8)
            .accessibilityLabel("Context window used")
            .accessibilityValue(content.figure + ", " + content.badge)
        }
        if let note = content.note {
          Text(note).webFont(.contextNote).foregroundStyle(WebColor.textMuted.color)
        }
      }
      .padding(.top, 10).padding(.horizontal, 16).padding(.bottom, 12)
      if !content.tokens.isEmpty {
        section("Tokens processed") {
          if typeSize.isAccessibilitySize {
            ForEach(content.tokens) { row in
              VStack(alignment: .leading, spacing: 3) {
                Text(row.label).webFont(.effortOption)
                Text("Input (incl. cache writes) · " + row.input)
                Text("Cached · " + row.cached)
                Text("Output · " + row.output)
              }.webFont(.optionID).padding(.bottom, 6)
            }
          } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
              GridRow {
                Text("")
                Text("Input").accessibilityLabel("Input including cache writes")
                Text("Cached")
                Text("Output")
              }.webFont(.sheetSubtitle).foregroundStyle(WebColor.textMuted.color)
              ForEach(content.tokens) { row in
                GridRow {
                  Text(row.label).webFont(.contextNote).foregroundStyle(WebColor.textSoft.color)
                  Text(row.input).webFont(.optionID)
                  Text(row.cached).webFont(.optionID)
                  Text(row.output).webFont(.optionID)
                }.accessibilityElement(children: .combine)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        section("Estimated cost") {
          ForEach(content.costs) { row in contextRow(row) }
        }
      } else if !content.rows.isEmpty {
        section("Usage and cost") {
          ForEach(content.rows) { row in contextRow(row) }
        }
      }

    }.background(WebColor.surfaceRaised.color)
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).webFont(.contextEyebrow).foregroundStyle(WebColor.textMuted.color)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 10).padding(.horizontal, 16).padding(.bottom, 12)
    .overlay(alignment: .top) { Rectangle().fill(WebColor.line.color).frame(height: 1) }
  }
  @ViewBuilder private func contextRow(_ row: ContextDisplayContent.Row) -> some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 2) { rowValues(row) }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 12) { rowValues(row) }
      }
    }.accessibilityElement(children: .combine)
  }
  @ViewBuilder private func rowValues(_ row: ContextDisplayContent.Row) -> some View {
    Text(row.label).webFont(.contextNote).foregroundStyle(WebColor.textSoft.color)
    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
    Text(row.value).webFont(.optionID).foregroundStyle(WebColor.text.color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
#if DEBUG
  #Preview("Context and cost") {
    DesignPreviewMatrix {
      ContextDisplay(
        .init(
          badge: "42%", figure: "84k / 200k tokens", status: "Current", percent: 42,
          rows: [
            .init("Input", "24k"), .init("Cached", "60k"), .init("Output", "1.2k"),
            .init("Estimated cost", "Unknown · Known cost $0.12"),
          ]), expanded: .constant(true)
      )
      .contentSurface()
    }
  }
#endif
