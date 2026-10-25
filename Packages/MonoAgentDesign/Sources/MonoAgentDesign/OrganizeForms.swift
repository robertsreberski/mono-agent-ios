// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

public struct OrganizeSheetHeader: View {
  let title: String
  let saving: Bool
  let canSave: Bool
  let cancel: () -> Void
  @Environment(\.consoleTheme) private var theme
  let save: () -> Void
  public init(
    _ title: String, saving: Bool, canSave: Bool, cancel: @escaping () -> Void,
    save: @escaping () -> Void
  ) {
    self.title = title
    self.saving = saving
    self.canSave = canSave
    self.cancel = cancel
    self.save = save
  }
  public var body: some View {
    HStack(spacing: 12) {
      Button(action: cancel) {
        Image(systemName: "xmark").font(.system(size: 16))
          .frame(width: DesignMetrics.minimumHitTarget, height: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(WebGlass.textSoft.color)
      .accessibilityLabel("Cancel")
      Spacer(minLength: 0)
      Text(title).webFont(.sheetTitle).accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      Button(saving ? "Saving…" : "Save", action: save)
        .designButtonStyle(.primary, placement: .floating)
        .foregroundStyle(theme.palette.onAccent.color).disabled(!canSave || saving)
        .accessibilityIdentifier("organize-save")
    }
    .webFont(.system).frame(minHeight: 52).padding(.horizontal, 17)
    .overlay(alignment: .bottom) { WebHairline() }
  }
}

public struct LabelPalette: View {
  @Binding var selection: LabelColor
  let colors: [LabelColor]
  let kind: String
  @Environment(\.consoleTheme) private var theme
  public init(selection: Binding<LabelColor>, colors: [LabelColor], kind: String) {
    _selection = selection
    self.colors = colors
    self.kind = kind
  }
  public var body: some View {
    ViewThatFits {
      HStack(spacing: 3) { swatches }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 3) { swatches }
    }
  }
  private var swatches: some View {
    ForEach(colors, id: \.rawValue) { color in
      Button {
        selection = color
      } label: {
        RoundedRectangle(cornerRadius: 8).fill(color.tint(in: theme).color.opacity(0.5))
          .overlay {
            if color == selection {
              Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color.ink(in: theme).color)
            }
          }
          .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(
              color.ink(in: theme).color.opacity(color == selection ? 1 : 0.2))
          }
          .frame(width: 32, height: 32).frame(width: 44, height: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "\(color == .standard ? "Accent" : color.rawValue.capitalized) \(kind) color"
      )
      .accessibilityAddTraits(color == selection ? .isSelected : [])
    }
  }
}

#if DEBUG
  #Preview {
    DesignPreviewMatrix {
      VStack(alignment: .leading, spacing: 16) {
        OrganizeSheetHeader("New project", saving: false, canSave: true, cancel: {}, save: {})
        LabelPalette(
          selection: .constant(.blue), colors: [.standard, .blue, .purple, .amber, .rose],
          kind: "project")
      }
    }
  }
#endif
