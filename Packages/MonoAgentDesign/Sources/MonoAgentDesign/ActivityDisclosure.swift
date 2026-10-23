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
  public var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: DesignSpacing.sm) {
          VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            StatusIndicator(status, label: title)
            if !summary.isEmpty {
              Text(summary).designFont(.supporting).foregroundStyle(.secondary).lineLimit(2)
            }
            if let detail { Text(detail).designFont(.caption).foregroundStyle(.secondary) }
          }.frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: expanded ? "chevron.down" : "chevron.right").accessibilityHidden(true)
        }.padding(.vertical, DesignSpacing.sm).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") activity")
        .accessibilityIdentifier(identifier)
      if expanded { content().padding(.leading, DesignSpacing.sm) }
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
