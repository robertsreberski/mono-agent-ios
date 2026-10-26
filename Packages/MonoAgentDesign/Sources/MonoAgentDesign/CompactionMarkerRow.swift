// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

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

/// Web compaction segments, without a decorative icon. Reduce Motion keeps the pulse static.
public struct CompactionMarkerRow: View {
  private let content: CompactionMarkerContent
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 10.5
  @State private var pulsing = false
  public init(_ content: CompactionMarkerContent) { self.content = content }
  private var text: Text {
    var text = Text(content.label).fontWeight(.semibold)
    if let counts = content.counts {
      text = Text(
        "\(text)\(Text(" · " + counts).font(.system(size: size, weight: .medium, design: .monospaced)))"
      )
    }
    if let detail = content.detail { text = Text("\(text) · \(detail)") }
    return Text("\(text) · \(content.trigger)")
  }
  public var body: some View {
    text
      .font(.system(size: size, weight: .medium))
      .foregroundStyle(content.failed ? DesignColor.danger.color : WebColor.textSoft.color)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 7)
      .opacity(content.running && !reduceMotion && pulsing ? 0.55 : 1)
      .animation(
        content.running && !reduceMotion
          ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : nil,
        value: pulsing
      )
      .onAppear { pulsing = true }
      .accessibilityLabel(content.text)
      .accessibilityIdentifier("compaction-marker")
  }
}
