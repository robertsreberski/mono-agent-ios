// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Dense, opaque transcript activity; the caller owns expansion and work state.
public struct ActivityDisclosure<Content: View>: View {
  private let title: String
  private let summary: String
  private let status: StatusKind
  private let detail: String?
  private let identifier: String
  @Binding private var expanded: Bool
  private let content: () -> Content
  public init(
    _ title: String, summary: String = "", status: StatusKind = .disconnected,
    detail: String? = nil, identifier: String = "activity-disclosure", expanded: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.status = status
    self.detail = detail
    self.identifier = identifier
    _expanded = expanded
    self.content = content
  }
  /// Web `.activity-row` summary: 18 pt glyph column (7 pt status dot in a 3 pt tint ring),
  /// 11.5/650 label, 10.5 muted preview, mono time and a chevron; 44 pt on touch, radius 9.
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .center, spacing: 8) {
          // A dot at rest; running and failed rows change shape too, never colour alone.
          Group {
            if status.tone == .danger || status == .connecting {
              Image(systemName: status.tone == .danger ? "xmark" : "circle.lefthalf.filled")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(dotColor)
                .frame(width: 7, height: 7)
            } else {
              Circle().fill(dotColor).frame(width: 7, height: 7)
            }
          }
          .padding(3)
          .background(Circle().fill(dotColor.opacity(0.18)))
          .frame(width: 18)
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(title).webFont(.activityRowLabel).foregroundStyle(WebColor.text.color)
                .lineLimit(1)
              if !summary.isEmpty {
                Text(summary).webFont(.activityMeta).foregroundStyle(WebColor.textMuted.color)
                  .lineLimit(1)
              }
            }
            if let detail, !detail.isEmpty {
              Text(detail).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(WebColor.textMuted.color).lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .foregroundStyle(WebColor.textMuted.color)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }.buttonStyle(WebRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          [title, summary, detail ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") activity")
        .accessibilityIdentifier(identifier)
      if expanded {
        VStack(alignment: .leading, spacing: 7) { content() }
          .padding(.leading, 10)
          .overlay(alignment: .leading) {
            Rectangle().fill(WebColor.line.color).frame(width: 1)
          }
          .padding(.leading, 16)
          .padding(.trailing, 2)
          .padding(.bottom, 6)
      }
    }
  }
  private var dotColor: Color {
    switch status.tone {
    case .danger: WebColor.danger.color
    case .warning: WebColor.jobProgress.color
    case .success: WebColor.success.color
    default:
      status == .connecting ? WebColor.jobProgress.color : WebColor.textMuted.color
    }
  }
}
#if DEBUG
  #Preview("Activity disclosure") {
    DesignPreviewMatrix {
      ActivityDisclosure(
        "Read ×3", summary: "outline.md, sample.md +1", detail: "1 failed · 1.2s",
        expanded: .constant(true)
      ) {
        Text("Input and output").designFont(.code)
      }
    }
  }
#endif
