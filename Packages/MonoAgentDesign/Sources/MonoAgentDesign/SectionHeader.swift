// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// A section title with optional detail and trailing accessory (count, unread, action).
public struct SectionHeader<Accessory: View>: View {
  private let title: String
  private let detail: String?
  private let accessory: Accessory

  public init(_ title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
    self.title = title
    self.detail = detail
    self.accessory = accessory()
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(title)
          .designFont(.sectionTitle)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        if let detail {
          Text(detail).designFont(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: DesignSpacing.sm)
      accessory
    }
    .textCase(nil)
  }
}

extension SectionHeader where Accessory == EmptyView {
  public init(_ title: String, detail: String? = nil) {
    self.init(title, detail: detail) { EmptyView() }
  }
}

#if DEBUG
  #Preview("Section header — themes") {
    DesignPreviewMatrix {
      SectionHeader("Saved consoles")
      SectionHeader("Agents", detail: "3 active") { UnreadMarker(count: 4) }
    }
  }
#endif
