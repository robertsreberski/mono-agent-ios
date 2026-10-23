// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Opaque-content disclosure with a bounded hit target and an independently identifiable
/// button. The identifier is deliberately not inherited by nested interactive controls.
public struct ContentDisclosure<Header: View, Content: View>: View {
  private let identifier: String
  @Binding private var expanded: Bool
  private let header: () -> Header
  private let content: () -> Content
  public init(
    _ identifier: String, expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder label: @escaping () -> Header
  ) {
    self.identifier = identifier
    _expanded = expanded
    self.content = content
    self.header = label
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .center, spacing: DesignSpacing.sm) {
          header().frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WebColor.textMuted.color)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
        }.frame(minHeight: DesignMetrics.minimumHitTarget).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") details")
        .accessibilityIdentifier(identifier)
      if expanded { content() }
    }
  }
}
#if DEBUG
  #Preview("Content disclosure") {
    DesignPreviewMatrix {
      ContentDisclosure("sample-disclosure", expanded: .constant(true)) {
        Text("Readable native detail").designFont(.body)
      } label: {
        Label("Details", systemImage: "terminal").designFont(.headline)
      }
      .contentSurface()
    }
  }
#endif
