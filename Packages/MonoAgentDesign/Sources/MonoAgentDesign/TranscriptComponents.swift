// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

// Web transcript pieces (`styles.css` `.message-*`, markers, notices). All opaque content.

/// The neutral user bubble (`.message-user-content`): subtle fill, 1 px line, radii
/// 16/16/4/16, padding 9×12, at most 88% of the column on phones (78% on tablets).
public struct UserBubble<Content: View>: View {
  private let content: Content
  @Environment(\.horizontalSizeClass) private var sizeClass
  public init(@ViewBuilder content: () -> Content) { self.content = content() }
  public var body: some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
      topTrailingRadius: 16, style: .continuous)
    let regular = sizeClass == .regular
    content
      .padding(.vertical, regular ? 11 : 9)
      .padding(.horizontal, regular ? 15 : 12)
      .background(WebColor.surfaceSubtle.color, in: shape)
      .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
      .fixedSize(horizontal: false, vertical: true)
      // At most 88% (78% on tablets) of the column, capped at 650; the bubble keeps its own
      // width inside that box on the trailing edge.
      .frame(maxWidth: .infinity, alignment: .trailing)
      .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in
        let gutter = regular ? WebSpace.transcriptGutterRegular : WebSpace.transcriptGutter
        return min(
          650,
          max(0, min(length, WebMetrics.column) - 2 * gutter)
            * (regular ? 0.78 : WebMetrics.bubbleWidth))
      }
  }
}

/// Places one subview at the trailing edge, no wider than `fraction` of the offered width.
struct TrailingFractionLayout: Layout {
  let fraction: CGFloat
  let cap: CGFloat
  private func limit(_ width: CGFloat?) -> CGFloat? {
    guard let width, width.isFinite else { return nil }
    return min(width * fraction, cap)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let first = subviews.first else { return .zero }
    let size = first.sizeThatFits(.init(width: limit(proposal.width), height: nil))
    // Fill a finite offer (so the bubble can sit on the trailing edge); never claim infinity.
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? size.width
    return CGSize(width: width, height: size.height)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let first = subviews.first else { return }
    let size = first.sizeThatFits(.init(width: limit(bounds.width), height: nil))
    first.place(
      at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
      proposal: .init(width: size.width, height: size.height))
  }
}

/// A web `.message-action` (Copy and friends): 27 pt high, muted 10 pt label, 44 pt hit target.
public struct MessageActionButton: View {
  private let title: String
  private let systemImage: String
  private let action: () -> Void
  @State private var done = false
  @Environment(\.consoleTheme) private var theme
  public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }
  public var body: some View {
    Button {
      action()
      done = true
    } label: {
      HStack(spacing: 5) {
        Image(systemName: done ? "checkmark" : systemImage).font(.system(size: 10, weight: .medium))
        Text(done ? "Copied" : title).webFont(.messageAction)
      }
      .foregroundStyle(done ? theme.palette.accent.color : WebColor.textMuted.color)
      .padding(.horizontal, 7)
      .frame(minHeight: 27)
      .frame(minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .task(id: done) {
      guard done else { return }
      try? await Task.sleep(for: .seconds(1.5))
      done = false
    }
  }
}

/// A centred, muted transcript notice ("History up to date", paging state).
public struct TranscriptNotice: View {
  private let text: String
  private let systemImage: String?
  public init(_ text: String, systemImage: String? = nil) {
    self.text = text
    self.systemImage = systemImage
  }
  public var body: some View {
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
          .accessibilityHidden(true)
      }
      Text(text).webFont(.notice)
    }
    .foregroundStyle(WebColor.textMuted.color)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// Model, project and compaction markers (`.model-transition`, `.context-compaction-row`):
/// a centred 10.5/600 label between 1 px rules of muted text at 20% (project ink at 22%).
public struct TranscriptMarkerRow: View {
  private let text: String
  private let systemImage: String?
  private let ink: Color?
  public init(_ text: String, systemImage: String? = nil, ink: Color? = nil) {
    self.text = text
    self.systemImage = systemImage
    self.ink = ink
  }
  public var body: some View {
    let rule = (ink ?? WebColor.textMuted.color).opacity(ink == nil ? 0.2 : 0.22)
    HStack(spacing: 12) {
      Rectangle().fill(rule).frame(height: 1)
      HStack(spacing: 5) {
        if let systemImage {
          Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            .accessibilityHidden(true)
        }
        Text(text).webFont(.marker).multilineTextAlignment(.center)
      }
      .foregroundStyle(ink ?? WebColor.textMuted.color)
      .layoutPriority(1)
      Rectangle().fill(rule).frame(height: 1)
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
  }
}

/// The web run attribution box (`.run-attribution`): fit-content, padding 8×10, radius 9, 1 px
/// line, subtle fill; a fallback adds the warning tint (`warning 45%` edge, `7%` fill).
public struct AttributionBox<Content: View>: View {
  private let fallback: Bool
  private let content: Content
  public init(fallback: Bool = false, @ViewBuilder content: () -> Content) {
    self.fallback = fallback
    self.content = content()
  }
  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
    VStack(alignment: .leading, spacing: 6) { content }
      .webFont(.runAttribution)
      .foregroundStyle(WebColor.textSoft.color)
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .background(
        fallback
          ? WebColor.warning.mixed(7, with: WebColor.surfaceSubtle).color
          : WebColor.surfaceSubtle.color, in: shape
      )
      .overlay(
        shape.strokeBorder(
          fallback ? WebColor.warning.mixed(45, with: WebColor.line).color : WebColor.line.color,
          lineWidth: 1)
      )
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8).padding(.bottom, 4)
  }
}

/// Web `.run-attribution-warning`: the uppercase FALLBACK pill.
public struct AttributionWarning: View {
  private let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    Text(text).webFont(.failedTag)
      .foregroundStyle(WebColor.warning.color)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(WebColor.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
      .fixedSize()
  }
}

/// Web `.message-error`: danger text on danger-soft, 1 px danger 25%, radius 9, an uppercase
/// code over the message.
public struct MessageErrorCard: View {
  private let code: String
  private let message: String
  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
    VStack(alignment: .leading, spacing: 3) {
      if !code.isEmpty { Text(code).webFont(.messageErrorCode) }
      Text(message).webFont(.messageError).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(WebColor.danger.color)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10).padding(.horizontal, 12)
    .background(WebColor.dangerSoft.color, in: shape)
    .overlay(shape.strokeBorder(WebColor.danger.color.opacity(0.25), lineWidth: 1))
    .accessibilityElement(children: .combine)
  }
}

/// Web `.thinking-indicator`: three 5 pt muted dots bouncing in sequence (static under Reduce
/// Motion), shown while the assistant runs without new prose.
public struct ThinkingDots: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  public init() {}
  public var body: some View {
    Group {
      if reduceMotion {
        dots(phase: nil)
      } else {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
          dots(phase: context.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .frame(height: 24)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Agent is thinking")
    .accessibilityIdentifier("thinking-indicator")
  }
  private func dots(phase: TimeInterval?) -> some View {
    HStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { index in
        Circle().fill(WebColor.textMuted.color).frame(width: 5, height: 5)
          .offset(y: phase.map { offset($0, delay: Double(index) * 0.12) } ?? 0)
      }
    }
  }
  /// CSS `bounce 1.1s ease-in-out infinite`: a 4 pt lift at the middle of each cycle.
  private func offset(_ time: TimeInterval, delay: Double) -> CGFloat {
    let cycle =
      ((time - delay).truncatingRemainder(dividingBy: 1.1) + 1.1)
      .truncatingRemainder(dividingBy: 1.1) / 1.1
    return -4 * CGFloat(sin(.pi * cycle) * sin(.pi * cycle))
  }
}

#if DEBUG
  #Preview("Transcript pieces") {
    DesignPreviewMatrix {
      VStack(alignment: .trailing, spacing: 8) {
        UserBubble {
          Text("Can you help outline a fictional garden planner?").webFont(.prose)
        }
        MessageActionButton("Copy", systemImage: "doc.on.doc") {}
        TranscriptMarkerRow("Model · sample:large → sample:small", systemImage: "sparkles")
        TranscriptNotice("History up to date", systemImage: "checkmark")
        AttributionBox(fallback: true) { Text("Fallback: sample:large → sample:small") }
        MessageErrorCard(code: "Agent error", message: "The response ended with an error.")
        ThinkingDots()
      }
    }
  }
#endif
