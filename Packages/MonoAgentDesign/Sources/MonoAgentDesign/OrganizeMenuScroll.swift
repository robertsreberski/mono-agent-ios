// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Material belongs to the system popover. Short registries fit their content;
/// long registries (including footer actions) stay reachable at accessibility sizes.
public struct OrganizeMenuScroll<Content: View>: View {
  let maximumHeight: CGFloat
  let content: Content
  @State private var contentHeight: CGFloat = 420
  public init(maximumHeight: CGFloat = 420, @ViewBuilder content: () -> Content) {
    self.maximumHeight = maximumHeight
    self.content = content()
  }
  public var body: some View {
    ScrollView {
      VStack(spacing: 0) { content }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          if $0 > 0 { contentHeight = $0 }
        }
    }
    .frame(height: min(max(contentHeight, 44), maximumHeight))
    .scrollBounceBehavior(.basedOnSize)
    .accessibilityElement(children: .contain)
  }
}
#if DEBUG
  #Preview("Long organize menu") {
    OrganizeMenuScroll {
      ForEach(1...30, id: \.self) { value in
        OrganizeMenuRow("Label \(value)", systemImage: "tag") {}
      }
    }
    .padding(4).frame(width: 280)
  }
#endif
