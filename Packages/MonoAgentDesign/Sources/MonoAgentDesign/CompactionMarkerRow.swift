// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

public struct CompactionMarkerContent: Sendable, Equatable {
  public let label: String
  public let counts: String?
  public let detail: String?
  public let trigger: String
  public let running: Bool
  public let failed: Bool
  public init(
    label: String, counts: String? = nil, detail: String? = nil, trigger: String,
    running: Bool = false, failed: Bool = false
  ) {
    self.label = label
    self.counts = counts
    self.detail = detail
    self.trigger = trigger
    self.running = running
    self.failed = failed
  }
  public var text: String {
    [label, counts, detail, trigger].compactMap { $0 }.joined(separator: " · ")
  }
}

/// Web compaction segments, without a decorative icon. Idle and reduced-motion rows
/// have no animation timeline; fixture captures honor the app's UIKit animation switch.
public struct CompactionMarkerRow: View {
  private let content: CompactionMarkerContent
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 10.5
  private var size: CGFloat { max(10.5, scaledSize) }
  public init(_ content: CompactionMarkerContent) { self.content = content }
  private var text: Text {
    var text = Text(content.label).fontWeight(.semibold)
      .foregroundColor(content.failed ? DesignColor.danger.color : WebColor.textSoft.color)
    if let counts = content.counts {
      text = Text(
        "\(text)\(Text(" · " + counts).font(.system(size: size, weight: .medium, design: .monospaced)))"
      )
    }
    if let detail = content.detail { text = Text("\(text) · \(detail)") }
    return Text("\(text) · \(content.trigger)")
  }
  public var body: some View {
    CompactionMarkerLayout {
      rule
      Group {
        if Self.animates(
          running: content.running, reduceMotion: reduceMotion,
          animationsEnabled: UIView.areAnimationsEnabled)
        {
          TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            text.opacity(Self.opacity(at: context.date.timeIntervalSinceReferenceDate))
          }
        } else {
          text
        }
      }
      .font(.system(size: size, weight: .medium))
      .foregroundStyle(WebColor.textSoft.color)
      .multilineTextAlignment(.center)
      rule
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.text)
    .accessibilityIdentifier("compaction-marker")
  }
  private var rule: some View {
    Rectangle().fill(WebColor.textMuted.color.opacity(0.2)).frame(height: 1)
      .accessibilityHidden(true)
  }
  static func animates(running: Bool, reduceMotion: Bool, animationsEnabled: Bool) -> Bool {
    running && !reduceMotion && animationsEnabled
  }
  static func opacity(at time: TimeInterval) -> Double {
    0.775 + 0.225 * cos(time * 2 * .pi / 1.2)
  }
}

/// CSS flex rules flank content capped at 80% of its column, with 12 pt gaps and
/// at least 12 pt of rule on either side. Measuring text here avoids a geometry state loop.
private struct CompactionMarkerLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews[1].sizeThatFits(.unspecified).width + 48
    let text = subviews[1].sizeThatFits(
      .init(width: min(width * 0.8, max(0, width - 48)), height: nil))
    return CGSize(width: width, height: text.height)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let text = subviews[1].sizeThatFits(
      .init(width: min(bounds.width * 0.8, max(0, bounds.width - 48)), height: nil))
    let ruleWidth = max(0, (bounds.width - text.width - 24) / 2)
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
      proposal: .init(width: ruleWidth, height: 1))
    subviews[1].place(
      at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
      proposal: .init(width: text.width, height: text.height))
    subviews[2].place(
      at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
      proposal: .init(width: ruleWidth, height: 1))
  }
}
