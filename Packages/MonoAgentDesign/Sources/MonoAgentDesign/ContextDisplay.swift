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
/// It has no fill of its own: in the app it sits on the sheet/popover material (glass rules),
/// so its sections are hairline-separated and its meter track is translucent ink.
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
      WebSheetSection("Context window", divider: false) {
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
              Text("/ " + figure[1]).webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if content.percent != nil {
            Text(content.badge).webFont(.optionID).fontWeight(.bold)
              .foregroundStyle(WebGlass.accentText(theme.palette).color).fixedSize()
          }
        }.textSelection(.enabled)
        Text(content.status).webFont(.contextTrigger).foregroundStyle(WebGlass.textMuted.color)
        if let percent = content.percent, percent.isFinite {
          GeometryReader { proxy in
            Capsule().fill(WebGlass.track.color)
              .overlay(alignment: .leading) {
                Capsule().fill(percent >= 85 ? WebColor.danger.color : theme.palette.accent.color)
                  .frame(width: proxy.size.width * min(1, max(0, percent / 100)))
              }
          }.frame(height: sizeClass == .regular ? 6 : 8)
            .accessibilityLabel("Context window used")
            .accessibilityValue(content.figure + ", " + content.badge)
        }
        if let note = content.note {
          Text(note).webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color)
        }
      }
      if !content.tokens.isEmpty {
        WebSheetSection("Tokens processed") {
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
            VStack(spacing: 4) {
              ContextTokenColumns {
                Text("")
                Text("Input").frame(maxWidth: .infinity, alignment: .trailing).accessibilityLabel(
                  "Input including cache writes")
                Text("Cached").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Output").frame(maxWidth: .infinity, alignment: .trailing)
              }.webFont(.sheetSubtitle).foregroundStyle(WebGlass.textMuted.color)
              ForEach(content.tokens) { row in
                ContextTokenColumns {
                  Text(row.label).webFont(.contextNote).foregroundStyle(WebGlass.textSoft.color)
                  Text(row.input).webFont(.optionID).frame(
                    maxWidth: .infinity, alignment: .trailing)
                  Text(row.cached).webFont(.optionID).frame(
                    maxWidth: .infinity, alignment: .trailing)
                  Text(row.output).webFont(.optionID).frame(
                    maxWidth: .infinity, alignment: .trailing)
                }.accessibilityElement(children: .combine)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        WebSheetSection("Estimated cost") {
          ForEach(content.costs) { row in contextRow(row) }
        }
      } else if !content.rows.isEmpty {
        WebSheetSection("Usage and cost") {
          ForEach(content.rows) { row in contextRow(row) }
        }
      }
    }
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
    Text(row.label).webFont(.contextNote).foregroundStyle(WebGlass.textSoft.color)
    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
    Text(row.value).webFont(.optionID).foregroundStyle(WebColor.text.color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
/// Web fixed-layout token table: label 38%, the three numeric columns share the rest.
private struct ContextTokenColumns: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 320
    let height =
      subviews.enumerated().map { index, view in
        view.sizeThatFits(.init(width: width * (index == 0 ? 0.38 : 0.62 / 3), height: nil)).height
      }.max() ?? 0
    return CGSize(width: width, height: height)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    for (index, view) in subviews.enumerated() {
      let width = bounds.width * (index == 0 ? 0.38 : 0.62 / 3)
      view.place(
        at: CGPoint(x: x, y: bounds.minY), proposal: .init(width: width, height: bounds.height))
      x += width
    }
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
