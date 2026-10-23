// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The server-selected console theme (`console.theme` in the bootstrap identity).
public enum ConsoleTheme: String, CaseIterable, Identifiable, Sendable {
  case evergreen
  case ocean
  case plum
  case terracotta

  /// The theme used while disconnected and for any value this app does not know.
  public static let fallback: ConsoleTheme = .evergreen

  /// Maps the exact wire value. `nil`, unknown or differently-cased values use `fallback`.
  public init(serverValue: String?) {
    self = serverValue.flatMap(ConsoleTheme.init(rawValue:)) ?? .fallback
  }

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .evergreen: "Evergreen"
    case .ocean: "Ocean"
    case .plum: "Plum"
    case .terracotta: "Terracotta"
    }
  }

  public var palette: ThemePalette { ThemePalette(self) }
}

/// Per-theme accent roles mirrored from the web console's light/dark CSS palettes.
///
/// Content uses native semantic surfaces; only accent roles and the page canvas are themed.
public struct ThemePalette: Hashable, Sendable {
  public let theme: ConsoleTheme
  /// Web `--accent`. Under Increase Contrast this resolves to `accentStrong`.
  public let accent: AdaptiveColor
  /// Web `--accent-strong`.
  public let accentStrong: AdaptiveColor
  /// Label colour on accent fills. Web `--on-accent`: white in light, a deep tint in dark.
  public let onAccent: AdaptiveColor
  /// Web `--accent-soft`, for selection and quiet emphasis behind primary-coloured text.
  public let accentSoft: AdaptiveColor
  /// Web `--app-bg`, the page canvas behind grouped content.
  public let canvas: AdaptiveColor
  /// Web `--panel`: the shared dashboard and chat material.
  public let panel: AdaptiveColor
  /// Web `--rail`: the dark code-block fill.
  public let rail: AdaptiveColor
  /// Web `--accent-glow`: the 3 px focus ring around focused fields.
  public var accentGlow: Color {
    accent.color(lightOpacity: 0.16, darkOpacity: theme == .evergreen ? 0.12 : 0.13)
  }
  /// Web `--process-job-stack-bg`: `color-mix(panel 55%, surface)`.
  public var jobStackBackground: AdaptiveColor { panel.mixed(55, with: WebColor.surface) }

  init(_ theme: ConsoleTheme) {
    self.theme = theme
    let values:
      (
        accent: Pair, strong: Pair, onAccentDark: RGBColor, soft: Pair, canvas: Pair, panel: Pair,
        rail: Pair
      ) =
        switch theme {
        case .evergreen:
          (
            Pair(0x24725f, 0x68b8a2), Pair(0x185b4c, 0x8bd0bd), RGBColor(0x0a1713),
            Pair(0xdcece6, 0x1d3a32), Pair(0xeeefeb, 0x0f1110), Pair(0xf7f7f4, 0x141715),
            Pair(0x171a18, 0x0b0d0c)
          )
        case .ocean:
          (
            Pair(0x266a91, 0x72b5dc), Pair(0x1b5477, 0x94c9e8), RGBColor(0x08151c),
            Pair(0xdcebf4, 0x193548), Pair(0xedf1f4, 0x0d1115), Pair(0xf6f8fa, 0x13191e),
            Pair(0x111a21, 0x091017)
          )
        case .plum:
          (
            Pair(0x7b4c87, 0xc18dcc), Pair(0x62396d, 0xd5a9dd), RGBColor(0x1b0c1e),
            Pair(0xeadfed, 0x3a2640), Pair(0xf2eef3, 0x120f14), Pair(0xfaf7fa, 0x18141a),
            Pair(0x1b151d, 0x0f0b11)
          )
        case .terracotta:
          (
            Pair(0x9b5037, 0xdf8e70), Pair(0x7d3c28, 0xefa98f), RGBColor(0x22100a),
            Pair(0xf1e1da, 0x432a21), Pair(0xf4efec, 0x130f0d), Pair(0xfaf7f5, 0x191411),
            Pair(0x201611, 0x100b09)
          )
        }
    accent = AdaptiveColor(
      light: values.accent.light, dark: values.accent.dark,
      lightHighContrast: values.strong.light, darkHighContrast: values.strong.dark)
    accentStrong = AdaptiveColor(light: values.strong.light, dark: values.strong.dark)
    onAccent = AdaptiveColor(light: RGBColor(0xffffff), dark: values.onAccentDark)
    accentSoft = AdaptiveColor(light: values.soft.light, dark: values.soft.dark)
    canvas = AdaptiveColor(light: values.canvas.light, dark: values.canvas.dark)
    panel = AdaptiveColor(light: values.panel.light, dark: values.panel.dark)
    rail = AdaptiveColor(light: values.rail.light, dark: values.rail.dark)
  }

  private struct Pair {
    let light: RGBColor
    let dark: RGBColor
    init(_ light: UInt32, _ dark: UInt32) {
      self.light = RGBColor(light)
      self.dark = RGBColor(dark)
    }
  }
}

extension EnvironmentValues {
  /// The active console theme. Defaults to `ConsoleTheme.fallback`.
  @Entry public var consoleTheme: ConsoleTheme = .fallback
  /// Forces the opaque fallbacks used for Reduce Transparency, without changing the
  /// system setting. The catalog and screenshots use it; components also honour the
  /// system `accessibilityReduceTransparency` value.
  @Entry public var prefersOpaqueSurfaces = false
}

extension View {
  /// Applies a console theme to the environment and to the system tint.
  public func consoleTheme(_ theme: ConsoleTheme) -> some View {
    environment(\.consoleTheme, theme).tint(theme.palette.accent.color)
  }

  /// Forces design components to their opaque, non-glass fallbacks.
  public func prefersOpaqueSurfaces(_ enabled: Bool = true) -> some View {
    environment(\.prefersOpaqueSurfaces, enabled)
  }
}
