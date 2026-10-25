// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Web conversation/tag/project menu row. The system popover owns its material.
public struct OrganizeMenuRow: View {
  let title: String
  let systemImage: String
  let detail: String?
  let destructive: Bool
  let action: () -> Void
  @Environment(\.webMaterial) private var material

  public init(
    _ title: String, systemImage: String, detail: String? = nil,
    destructive: Bool = false, action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
    self.destructive = destructive
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage).font(.system(size: 16)).frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).webFont(.system)
          if let detail {
            Text(detail).webFont(.rowSubtitle).foregroundStyle(material.textMuted.color)
          }
        }
        Spacer(minLength: 0)
      }
      .foregroundStyle(destructive ? WebColor.danger.color : WebColor.text.color)
      .padding(.horizontal, 10)
      .frame(minHeight: DesignMetrics.minimumHitTarget, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

#if DEBUG
  #Preview {
    DesignPreviewMatrix {
      VStack(spacing: 0) {
        OrganizeMenuRow("Move to project", systemImage: "folder", detail: "Garden planner") {}
        OrganizeMenuRow("Schedule wake-up", systemImage: "clock") {}
        OrganizeMenuRow("Archive conversation", systemImage: "archivebox") {}
        OrganizeMenuRow("Permanently delete", systemImage: "trash", destructive: true) {}
      }
      .padding(4)
    }
  }
#endif
