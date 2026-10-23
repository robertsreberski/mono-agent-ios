// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Opaque web `.settings-group`: raised surface, line border, 12 px corners.
/// Settings content never adopts the glass of its surrounding native sheet.
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
        .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.line.color, lineWidth: 1)
        }
        .compositingGroup()
        .webShadow(.small)
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
      .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.lineStrong.color, lineWidth: 1)
      }
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
