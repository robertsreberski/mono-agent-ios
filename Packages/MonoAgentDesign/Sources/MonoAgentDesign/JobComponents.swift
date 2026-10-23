// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

// The web console's background-job vocabulary (`ProcessJob*.tsx`, styles.css 1440–1760):
// one circular status glyph family, fixed status hues, dense job rows with a wrapping meta line,
// and the output/error boxes of an open row. Value-driven: callers map their own job model.

/// A job status colour role. Fixed across console themes (never the accent).
public enum WebJobTone: String, CaseIterable, Sendable {
  case waiting, running, stopping, question, success, danger, neutral

  /// The glyph (mark) colour: the hue itself.
  public var mark: Color {
    switch self {
    case .running: WebColor.jobProgress.color
    case .question: WebColor.warning.color
    case .success: WebColor.success.color
    case .danger: WebColor.danger.color
    case .stopping: WebColor.textSoft.color
    case .waiting, .neutral: WebColor.textMuted.color
    }
  }
  /// Small text in this tone (the hue mixed toward text for contrast).
  public var text: Color {
    switch self {
    case .running: WebColor.jobProgressText.color
    case .question: WebColor.jobWarningText.color
    case .success: WebColor.jobSuccessText.color
    case .danger: WebColor.danger.color
    case .waiting, .stopping, .neutral: WebColor.textSoft.color
    }
  }
  /// The count chip's tint.
  public var chipFill: Color {
    switch self {
    case .running: WebColor.jobProgress.color.opacity(0.14)
    case .question: WebColor.warning.color.opacity(0.14)
    case .success: WebColor.success.color.opacity(0.12)
    case .danger: WebColor.danger.color.opacity(0.12)
    case .waiting, .stopping, .neutral: WebColor.text.color.opacity(0.07)
    }
  }
}

/// The shape inside a job glyph. Outlined rings are current work; solid discs settled outcomes.
public enum JobGlyphMark: String, CaseIterable, Sendable {
  case empty, half, stop, question, check, cross, clock, stopped

  public var settled: Bool { ![.empty, .half, .stop, .question].contains(self) }
}

/// `ProcessJobGlyph`: an 18-unit circle on a 20-unit grid with a 1.5-unit ring; settled marks are
/// cut out of a solid disc (truly transparent, so they read on glass and opaque shelves alike).
/// Decorative: the row's words carry the meaning.
public struct JobGlyph: View {
  private let mark: JobGlyphMark
  private let color: Color
  private let size: CGFloat
  @ScaledMetric(relativeTo: .footnote) private var scale: CGFloat = 1

  public init(_ mark: JobGlyphMark, tone: WebJobTone, size: CGFloat = 20) {
    self.init(mark, color: tone.mark, size: size)
  }
  /// A glyph in an explicit colour (a count chip uses its text colour).
  public init(_ mark: JobGlyphMark, color: Color, size: CGFloat = 20) {
    self.mark = mark
    self.color = color
    self.size = size
  }

  public var body: some View {
    let side = size * scale
    let small = size < 18
    Canvas { context, canvas in
      let unit = canvas.width / 20
      context.scaleBy(x: unit, y: unit)
      let shading = GraphicsContext.Shading.color(color)
      let ring = Path(ellipseIn: CGRect(x: 1.75, y: 1.75, width: 16.5, height: 16.5))
      let disc = Path(ellipseIn: CGRect(x: 1, y: 1, width: 18, height: 18))
      let line = StrokeStyle(lineWidth: small ? 1.9 : 1.6, lineCap: .round, lineJoin: .round)
      let cut = StrokeStyle(lineWidth: small ? 2.1 : 1.8, lineCap: .round, lineJoin: .round)
      func stroke(_ path: Path) {
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: small ? 1.75 : 1.5))
      }
      func clear(_ path: Path, filled: Bool = false) {
        var layer = context
        layer.blendMode = .clear
        if filled {
          layer.fill(path, with: .color(.black))
        } else {
          layer.stroke(path, with: .color(.black), style: cut)
        }
      }
      switch mark {
      case .empty:
        stroke(ring)
      case .half:
        stroke(ring)
        var half = Path()
        half.move(to: CGPoint(x: 10, y: 5.4))
        half.addArc(
          center: CGPoint(x: 10, y: 10), radius: 4.6, startAngle: .degrees(-90),
          endAngle: .degrees(90), clockwise: false)
        half.closeSubpath()
        context.fill(half, with: shading)
      case .stop:
        stroke(ring)
        context.fill(
          Path(roundedRect: CGRect(x: 7.1, y: 7.1, width: 5.8, height: 5.8), cornerRadius: 1.3),
          with: shading)
      case .question:
        stroke(ring)
        var hook = Path()
        hook.move(to: CGPoint(x: 8.15, y: 7.9))
        hook.addArc(
          center: CGPoint(x: 10.05, y: 7.9), radius: 1.9, startAngle: .degrees(180),
          endAngle: .degrees(60), clockwise: false)
        hook.addQuadCurve(to: CGPoint(x: 10, y: 10.9), control: CGPoint(x: 10, y: 10))
        hook.addLine(to: CGPoint(x: 10, y: 11.25))
        context.stroke(hook, with: shading, style: line)
        context.fill(Path(ellipseIn: CGRect(x: 9, y: 12.55, width: 2, height: 2)), with: shading)
      case .check:
        context.fill(disc, with: shading)
        var check = Path()
        check.move(to: CGPoint(x: 6.6, y: 10.3))
        check.addLine(to: CGPoint(x: 8.9, y: 12.6))
        check.addLine(to: CGPoint(x: 13.4, y: 7.8))
        clear(check)
      case .cross:
        context.fill(disc, with: shading)
        var cross = Path()
        cross.move(to: CGPoint(x: 7.6, y: 7.6))
        cross.addLine(to: CGPoint(x: 12.4, y: 12.4))
        cross.move(to: CGPoint(x: 12.4, y: 7.6))
        cross.addLine(to: CGPoint(x: 7.6, y: 12.4))
        clear(cross)
      case .clock:
        context.fill(disc, with: shading)
        var hands = Path()
        hands.move(to: CGPoint(x: 10, y: 5.9))
        hands.addLine(to: CGPoint(x: 10, y: 10))
        hands.addLine(to: CGPoint(x: 12.8, y: 11.8))
        clear(hands)
      case .stopped:
        context.fill(disc, with: shading)
        clear(
          Path(roundedRect: CGRect(x: 7.25, y: 7.25, width: 5.5, height: 5.5), cornerRadius: 1.2),
          filled: true)
      }
    }
    .frame(width: side, height: side)
    .accessibilityHidden(true)
  }
}

/// A line of inline tokens that wraps like CSS `flex-wrap`, with an optional last item that
/// takes the rest of the line (`flex: 1 1 7em`) or moves to its own line when too little is left.
public struct WebFlowLayout: Layout {
  private let spacing: CGFloat
  private let lineSpacing: CGFloat
  private let fillMinimum: CGFloat
  private let alignTrailing: Bool

  public init(
    spacing: CGFloat = 5, lineSpacing: CGFloat = 0, fillMinimum: CGFloat = 80,
    alignTrailing: Bool = false
  ) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing
    self.fillMinimum = fillMinimum
    self.alignTrailing = alignTrailing
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
    -> CGSize
  {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
    // Keep the measured wrapping width for placement. Shrinking to the widest row can
    // introduce another wrap during placeSubviews and draw the next row over its sibling.
    return CGSize(width: proposal.width ?? width, height: height)
  }

  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX + (alignTrailing ? max(0, bounds.width - row.width) : 0)
      for item in row.items {
        // Baseline-ish alignment: centre each item on the row.
        subviews[item.index].place(
          at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), anchor: .topLeading,
          proposal: ProposedViewSize(item.size))
        x += item.size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Item {
    let index: Int
    var size: CGSize
  }
  private struct Row {
    var items: [Item] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for (index, subview) in subviews.enumerated() {
      let fills = subview[WebFlowFill.self]
      var size = subview.sizeThatFits(.unspecified)
      let used = rows[rows.count - 1].width
      let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
      if fills {
        let left = width - used - gap
        if left >= min(fillMinimum, size.width) || rows[rows.count - 1].items.isEmpty {
          size = subview.sizeThatFits(
            ProposedViewSize(width: max(0, min(left, size.width)), height: nil))
        } else {
          rows.append(Row())
          size = subview.sizeThatFits(ProposedViewSize(width: min(width, size.width), height: nil))
        }
      } else if size.width > width {
        size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      }
      if !rows[rows.count - 1].items.isEmpty
        && rows[rows.count - 1].width + spacing + size.width > width + 0.5
      {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width += (row.items.isEmpty ? 0 : spacing) + size.width
      row.height = max(row.height, size.height)
      row.items.append(Item(index: index, size: size))
      rows[rows.count - 1] = row
    }
    return rows.filter { !$0.items.isEmpty }
  }
}

/// Marks a `WebFlowLayout` item that takes the rest of its line.
public struct WebFlowFill: LayoutValueKey {
  public static let defaultValue = false
}

extension View {
  /// In a `WebFlowLayout`, this item fills the remaining width of its line (one line, ellipsis).
  public func webFlowFill() -> some View { layoutValue(key: WebFlowFill.self, value: true) }
}

/// One `·`-separated meta token (`.process-job-token`): a 60% dot, then the content.
public struct JobMetaToken<Content: View>: View {
  private let content: Content
  public init(@ViewBuilder content: () -> Content) { self.content = content() }
  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text("·").opacity(0.6).accessibilityHidden(true)
      content
    }
  }
}

/// The web job row (`.process-job-card`, `.process-job-group`): a 20 pt glyph column, a 13/600
/// title (two lines on phones, unlimited open), a 14 pt chevron and the meta line beneath the
/// title; open rows take a subtle 80% fill and show their detail on the title column.
public struct JobRowDisclosure<Glyph: View, Title: View, Meta: View, Content: View>: View {
  private let identifier: String
  private let accessibilityText: String
  @Binding private var expanded: Bool
  private let openFill: Color?
  private let glyph: Glyph
  private let title: Title
  private let meta: Meta
  private let content: () -> Content
  @Environment(\.horizontalSizeClass) private var sizeClass

  public init(
    _ identifier: String, accessibilityLabel: String, expanded: Binding<Bool>,
    openFill: Color? = nil,
    @ViewBuilder glyph: () -> Glyph, @ViewBuilder title: () -> Title,
    @ViewBuilder meta: () -> Meta, @ViewBuilder content: @escaping () -> Content
  ) {
    self.identifier = identifier
    accessibilityText = accessibilityLabel
    _expanded = expanded
    self.openFill = openFill
    self.glyph = glyph()
    self.title = title()
    self.meta = meta()
    self.content = content
  }

  private var compact: Bool { sizeClass != .regular }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .top, spacing: compact ? 9 : 10) {
          glyph.padding(.top, -1).frame(minWidth: 20, alignment: .center)
          VStack(alignment: .leading, spacing: 2) {
            title
              .webFont(.jobTitle)
              .foregroundStyle(WebColor.text.color)
              .lineLimit(expanded ? nil : (compact ? 2 : 1))
              .fixedSize(horizontal: false, vertical: true)
            meta
              .webFont(.jobMeta)
              .foregroundStyle(WebColor.textMuted.color)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WebColor.textMuted.color)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .frame(width: 14, height: 18)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(minHeight: 52, alignment: .top)
        .contentShape(shape)
      }
      .buttonStyle(JobRowPressStyle())
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityText)
      .accessibilityAddTraits(.isButton)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") details")
      .accessibilityIdentifier(identifier)
      if expanded {
        VStack(alignment: .leading, spacing: 9) { content() }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, compact ? 37 : 40)
          .padding(.trailing, compact ? 8 : 10)
          .padding(.bottom, 12)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .background {
      if expanded {
        shape.fill(openFill ?? WebColor.surfaceSubtle.color.opacity(0.8))
      }
    }
  }
}

/// Job row press feedback: `--surface-hover` at 60% (web hover), never a system highlight.
struct JobRowPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background {
      if configuration.isPressed {
        RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
          .fill(WebColor.surfaceHover.color.opacity(0.6))
      }
    }
  }
}

/// `.process-job-output` / `.process-job-response`: mono 11/1.55 soft text in a bounded, scrolling
/// box (app-bg 55% into surface, 1 px line, radius 8).
public struct JobOutputBox: View {
  private let text: String
  private let maxHeight: CGFloat
  private let prose: Bool
  @Environment(\.consoleTheme) private var theme

  public init(_ text: String, maxHeight: CGFloat = 168, prose: Bool = false) {
    self.text = text
    self.maxHeight = maxHeight
    self.prose = prose
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    ScrollView {
      Text(text)
        .webFont(prose ? .jobDetail : .jobOutput)
        .foregroundStyle(prose ? WebColor.text.color : WebColor.textSoft.color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .background(
      prose
        ? WebColor.surface.color : theme.palette.canvas.mixed(55, with: WebColor.surface).color,
      in: shape
    )
    .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
  }
}

/// `.process-job-error` / `.activity-error`: danger text on an 8% danger wash, radius 8.
public struct JobErrorBox: View {
  private let message: String
  private let code: String?
  public init(_ message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(message).webFont(.jobDetail).foregroundStyle(WebColor.danger.color)
      if let code {
        Text(code).webFont(.jobOutput).foregroundStyle(WebColor.textMuted.color)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(
      WebColor.danger.color.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous))
  }
}

/// `.process-job-stack-history-toggle`: a 32 pt pill with a 1 px line, a bare count and a chevron.
public struct JobHistoryToggleStyle: ButtonStyle {
  private let open: Bool
  private let count: Int
  public init(open: Bool, count: Int) {
    self.open = open
    self.count = count
  }
  public func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.label.webFont(.jobEntry)
      Text("\(count)")
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(WebColor.textSoft.color)
        .padding(.vertical, 2).padding(.horizontal, 5)
        .frame(minWidth: 18)
        .background(WebColor.text.color.opacity(0.08), in: Capsule())
      Image(systemName: "chevron.down")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(WebColor.textMuted.color)
        .rotationEffect(.degrees(open ? 180 : 0))
    }
    .foregroundStyle(open ? WebColor.text.color : WebColor.textSoft.color)
    .padding(.leading, 11).padding(.trailing, 10)
    .frame(minHeight: WebMetrics.quietControl)
    .background(
      Capsule().fill(
        configuration.isPressed
          ? WebColor.surfaceHover.color : open ? WebColor.surfaceSubtle.color : .clear)
    )
    .overlay(Capsule().strokeBorder(WebColor.line.color, lineWidth: 1))
    .frame(minHeight: DesignMetrics.minimumHitTarget)
    .contentShape(Rectangle())
  }
}

/// The small settings-family button (`.settings-button`): 32 pt, radius 9, surface fill with a
/// 1 px strong line, soft 11.5/650 text. Used for in-card actions such as Refresh and Answer.
public struct WebSmallButtonStyle: ButtonStyle {
  public enum Tone: Sendable { case standard, accent }
  private let tone: Tone
  @Environment(\.consoleTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  public init(_ tone: Tone = .standard) { self.tone = tone }
  public func makeBody(configuration: Configuration) -> some View {
    let palette = theme.palette
    let shape = RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
    configuration.label
      .webFont(.jobOutputHead)
      .foregroundStyle(
        tone == .accent
          ? palette.accent.color
          : configuration.isPressed ? WebColor.text.color : WebColor.textSoft.color
      )
      .padding(.horizontal, 12)
      .frame(minHeight: WebMetrics.quietControl)
      .background(
        shape.fill(
          tone == .accent
            ? palette.accentSoft.color
            : configuration.isPressed ? WebColor.surfaceHover.color : WebColor.surface.color)
      )
      .overlay(
        shape.strokeBorder(
          tone == .accent ? palette.accent.color.opacity(0.24) : WebColor.lineStrong.color,
          lineWidth: 1)
      )
      .opacity(enabled ? 1 : 0.45)
      .frame(minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
  }
}

#if DEBUG
  private struct JobComponentsPreview: View {
    @State private var open = true
    @Environment(\.consoleTheme) private var theme
    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          ForEach(JobGlyphMark.allCases, id: \.self) { mark in
            JobGlyph(
              mark,
              tone: mark == .half
                ? .running
                : mark == .question
                  ? .question : mark == .check ? .success : mark.settled ? .danger : .waiting)
          }
        }
        JobRowDisclosure(
          "preview-job", accessibilityLabel: "Run the sample suite, Running", expanded: $open
        ) {
          JobGlyph(.half, tone: .running)
        } title: {
          Text("Run the sample test suite")
        } meta: {
          WebFlowLayout {
            Text("Running").fontWeight(.semibold).foregroundStyle(WebJobTone.running.text)
            JobMetaToken { Text("4m 12s").monospaced() }
            JobMetaToken { Label("Bash", systemImage: "terminal").labelStyle(.titleAndIcon) }
          }
        } content: {
          JobOutputBox("STDOUT:\n✓ sample.test.ts (12 tests)")
          JobErrorBox("The sample command failed.", code: "exit_nonzero")
        }
        Button("History") {}.buttonStyle(JobHistoryToggleStyle(open: false, count: 3))
      }
      .padding(6)
      .background(theme.palette.jobStackBackground.color)
    }
  }

  #Preview("Job components") { DesignPreviewMatrix { JobComponentsPreview() } }
#endif
