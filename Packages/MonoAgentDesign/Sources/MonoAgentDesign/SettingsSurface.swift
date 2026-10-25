// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Web `.settings-group`: raised surface, line border, 12 px corners in the content layer. In a
/// sheet (`webMaterial == .glass`) it becomes quiet group ink with a hairline (GLASS-RULES.md).
public struct SettingsGroup<Content: View>: View {
  private let title: String?
  private let content: Content

  public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        Text(title).webFont(.settingsTitle).accessibilityAddTraits(.isHeader)
      }
      VStack(alignment: .leading, spacing: 10) { content }
        .webFont(.rowTitle)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webLayeredSurface(
          RoundedRectangle(cornerRadius: 12), fill: WebColor.surfaceRaised.color,
          stroke: WebColor.line.color, shadow: .small)
    }
    .foregroundStyle(WebColor.text.color)
  }
}

/// The web dialog/settings input, retaining native editing and Dynamic Type.
extension View {
  public func settingsField() -> some View {
    self
      .webFont(.search)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .webLayeredSurface(
        RoundedRectangle(cornerRadius: 12), fill: WebColor.surfaceSubtle.color,
        stroke: WebColor.lineStrong.color)
  }
}

#if DEBUG
  #Preview("Settings — web surfaces") {
    DesignPreviewMatrix {
      SettingsGroup("Console") {
        TextField("Display name", text: .constant("Sample console"))
          .settingsField()
        Text("Connect only to a console you trust.").webFont(.notice)
      }
    }
  }
#endif
