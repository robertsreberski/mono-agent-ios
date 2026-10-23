// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The named colours a console gives tags and projects (`WebTagColor` / `WebProjectColor`).
/// Ink is the text/symbol colour, tint the fill behind it; both mirror the web console's
/// `--project-ink` / `--project-tint` pairs. `standard` follows the console theme.
public enum LabelColor: String, CaseIterable, Sendable {
  case standard = "default"
  case blue, purple, amber, rose, green, teal, red

  /// Exact wire values only; anything unknown falls back to the theme colour.
  public init(serverValue: String?) {
    self = serverValue.flatMap(LabelColor.init(rawValue:)) ?? .standard
  }

  public func ink(in theme: ConsoleTheme) -> AdaptiveColor {
    switch self {
    case .standard: theme.palette.accentStrong
    case .blue: AdaptiveColor(light: RGBColor(0x235d91), dark: RGBColor(0x9ecbfa))
    case .purple: AdaptiveColor(light: RGBColor(0x70438e), dark: RGBColor(0xd5b2ed))
    case .amber: AdaptiveColor(light: RGBColor(0x79530a), dark: RGBColor(0xe7c37d))
    case .rose: AdaptiveColor(light: RGBColor(0x943c59), dark: RGBColor(0xefadc2))
    case .green: AdaptiveColor(light: RGBColor(0x28613c), dark: RGBColor(0xa0d7ae))
    case .teal: AdaptiveColor(light: RGBColor(0x196467), dark: RGBColor(0x91d6d8))
    case .red: AdaptiveColor(light: RGBColor(0xa23832), dark: RGBColor(0xf4aaa3))
    }
  }

  public func tint(in theme: ConsoleTheme) -> AdaptiveColor {
    switch self {
    case .standard: theme.palette.accentSoft
    case .blue: AdaptiveColor(light: RGBColor(0xe3effb), dark: RGBColor(0x23394c))
    case .purple: AdaptiveColor(light: RGBColor(0xf0e6f7), dark: RGBColor(0x3c294b))
    case .amber: AdaptiveColor(light: RGBColor(0xf7edcf), dark: RGBColor(0x423719))
    case .rose: AdaptiveColor(light: RGBColor(0xf9e6ec), dark: RGBColor(0x492c38))
    case .green: AdaptiveColor(light: RGBColor(0xe3f2e7), dark: RGBColor(0x233d2b))
    case .teal: AdaptiveColor(light: RGBColor(0xdff1f1), dark: RGBColor(0x203d3e))
    case .red: AdaptiveColor(light: RGBColor(0xfbe6e3), dark: RGBColor(0x492a28))
    }
  }
}

/// A conversation tag: a colour dot and the tag name in its ink, on its tint. Content, not glass.
public struct TagChip: View {
  private let name: String
  private let color: LabelColor
  @Environment(\.consoleTheme) private var theme
  @ScaledMetric(relativeTo: .caption2) private var dot: CGFloat = 5

  public init(_ name: String, color: LabelColor = .standard) {
    self.name = name
    self.color = color
  }

  public var body: some View {
    LabelChipLayout(color: color) {
      Circle().fill(color.ink(in: theme).color).frame(width: dot, height: dot)
    } text: {
      Text(name)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tag \(name)")
  }
}

/// The project a conversation belongs to: a folder symbol and the project name.
public struct ProjectChip: View {
  private let name: String
  private let color: LabelColor
  @Environment(\.consoleTheme) private var theme

  public init(_ name: String, color: LabelColor = .standard) {
    self.name = name
    self.color = color
  }

  public var body: some View {
    LabelChipLayout(color: color) {
      Image(systemName: "folder.fill").imageScale(.small)
    } text: {
      Text(name)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Project \(name)")
  }
}

private struct LabelChipLayout<Mark: View>: View {
  let color: LabelColor
  @ViewBuilder let mark: () -> Mark
  @ViewBuilder let text: () -> Text
  @Environment(\.consoleTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let ink = color.ink(in: theme).color
    HStack(spacing: DesignSpacing.xs) {
      mark().accessibilityHidden(true)
      text().lineLimit(1)
    }
    .font(.system(.caption, weight: .semibold))
    .foregroundStyle(ink)
    .padding(.horizontal, DesignSpacing.sm - DesignSpacing.xxs)
    .padding(.vertical, DesignSpacing.xxs)
    .background(color.tint(in: theme).color, in: Capsule())
    .overlay {
      if contrast == .increased { Capsule().strokeBorder(ink, lineWidth: 1) }
    }
  }
}

#if DEBUG
  #Preview("Chips — themes") {
    DesignPreviewMatrix {
      HStack {
        ProjectChip("Field notes")
        TagChip("Research", color: .blue)
        TagChip("Urgent", color: .red)
        TagChip("Default")
      }
    }
  }

  #Preview("Chips — every colour, dark, accessibility size") {
    DesignPreviewMatrix {
      VStack(alignment: .leading) {
        ForEach(LabelColor.allCases, id: \.self) { color in
          HStack {
            TagChip(color.rawValue, color: color)
            ProjectChip(color.rawValue, color: color)
          }
        }
      }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
  }
#endif
