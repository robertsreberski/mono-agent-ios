// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Web dialog header, drawn directly on the system presentation material (no band of its own):
/// web title type, the web's plain ✕ in a 44 pt hit target and a hairline below.
public struct WebSheetHeader: View {
  private let title: String
  private let subtitle: String?
  private let closeLabel: String
  private let closeIdentifier: String
  private let divider: Bool
  private let onClose: () -> Void
  public init(
    _ title: String, subtitle: String? = nil, closeLabel: String = "Close",
    closeIdentifier: String = "sheet-close", divider: Bool = true,
    onClose: @escaping () -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.closeLabel = closeLabel
    self.closeIdentifier = closeIdentifier
    self.divider = divider
    self.onClose = onClose
  }
  public var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).webFont(.sheetTitle).foregroundStyle(WebColor.text.color)
          .accessibilityAddTraits(.isHeader)
        if let subtitle {
          Text(subtitle).webFont(.sheetSubtitle).foregroundStyle(WebGlass.textMuted.color)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 12)
      // The web `.sheet-close`: a borderless ✕, soft ink, no fill or glass of its own.
      Button(closeLabel, systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly).font(.system(size: 15, weight: .regular))
        .foregroundStyle(WebGlass.textSoft.color)
        .frame(width: DesignMetrics.minimumHitTarget, height: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier(closeIdentifier)
    }
    // Inset from the sheet's concentric corner so the close button never crowds it.
    .padding(.leading, 16).padding(.trailing, 14).padding(.top, 8)
    .frame(minHeight: subtitle == nil ? 56 : 72)
    .overlay(alignment: .bottom) {
      if divider { WebHairline() }
    }
  }
}

/// Web model/skill search: 50 pt row with an unfilled field and one bottom hairline.
public struct WebSearchField: View {
  private let prompt: String
  @Binding private var text: String
  public init(_ prompt: String, text: Binding<String>) {
    self.prompt = prompt
    _text = text
  }
  public var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass").font(.system(size: 14)).accessibilityHidden(true)
      TextField(prompt, text: $text).webFont(.search)
        .foregroundStyle(WebColor.text.color)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    .foregroundStyle(WebGlass.textMuted.color)
    .padding(.horizontal, 16).frame(minHeight: 50)
    .overlay(alignment: .bottom) { WebHairline() }
  }
}

/// Web model option: 52 pt touch row, 14 pt name, 11 pt mono description and a 24 pt check ring.
/// The selected row takes the translucent selection ink, never a solid surface.
public struct WebModelRow: View {
  private let name: String
  private let detail: String?
  private let selected: Bool
  @Environment(\.consoleTheme) private var theme
  public init(_ name: String, detail: String? = nil, selected: Bool) {
    self.name = name
    self.detail = detail
    self.selected = selected
  }
  public var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(name).webFont(.optionName).foregroundStyle(WebColor.text.color)
        if let detail, !detail.isEmpty {
          Text(detail).webFont(.optionID).foregroundStyle(WebGlass.textMuted.color)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if selected {
        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
          .foregroundStyle(WebGlass.accentText(theme.palette).color)
          .frame(width: 24, height: 24)
          .overlay(Circle().strokeBorder(theme.palette.accent.color, lineWidth: 1))
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 6).padding(.horizontal, 10)
    .frame(minHeight: 52)
    .background(
      selected ? WebGlass.selectedFill.color : .clear, in: RoundedRectangle(cornerRadius: 9)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// Web effort option. Unselected: translucent group ink with a hairline edge (it sits on the
/// sheet material); selected: accent ink, accent text and a 1 px accent edge.
public struct WebEffortButtonStyle: ButtonStyle {
  private let selected: Bool
  @Environment(\.consoleTheme) private var theme
  public init(selected: Bool) { self.selected = selected }
  public func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8)
    configuration.label.webFont(.effortOption)
      .foregroundStyle(
        selected ? WebGlass.accentText(theme.palette).color : WebGlass.textSoft.color
      )
      .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
      .background(
        selected
          ? theme.palette.accentInk
          : configuration.isPressed ? WebGlass.selectedFill.color : WebGlass.groupFill.color,
        in: shape
      )
      .overlay(
        shape.strokeBorder(
          selected ? WebGlass.accentText(theme.palette).color : WebGlass.hairline.color,
          lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

#if DEBUG
  #Preview("Sheet parts") {
    DesignPreviewMatrix {
      SheetMaterialSample {
        VStack(spacing: 0) {
          WebSheetHeader("Run settings", subtitle: "Choose the next turn's route") {}
          WebSearchField("Search models", text: .constant(""))
          WebModelRow("Sample Large", detail: "sample:large", selected: true).padding(6)
          HStack {
            Button("Low") {}.buttonStyle(WebEffortButtonStyle(selected: false))
            Button("High") {}.buttonStyle(WebEffortButtonStyle(selected: true))
          }.padding(12)
        }
      }
    }
  }
#endif
