// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// An exact sRGB value. Tokens are stored as values so contrast is testable without rendering.
public struct RGBColor: Hashable, Sendable, CustomStringConvertible {
  public let red: Double
  public let green: Double
  public let blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
  }

  /// `RGBColor(0x24725f)` mirrors a CSS `#24725f` literal.
  public init(_ hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }

  /// Lowercase `#rrggbb`, matching the web console's CSS notation.
  public var hexString: String {
    let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
    return "#"
      + components.map { component in
        let digits = String(component, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
      }.joined()
  }

  public var description: String { hexString }

  /// WCAG 2.x relative luminance.
  public var relativeLuminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG 2.x contrast ratio, 1…21. AA requires 4.5 for body text and 3 for UI graphics.
  public func contrastRatio(with other: RGBColor) -> Double {
    let first = relativeLuminance
    let second = other.relativeLuminance
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  /// Source-over compositing of this colour at `opacity` on an opaque background.
  public func composited(over background: RGBColor, opacity: Double) -> RGBColor {
    let alpha = min(max(opacity, 0), 1)
    return RGBColor(
      red: red * alpha + background.red * (1 - alpha),
      green: green * alpha + background.green * (1 - alpha),
      blue: blue * alpha + background.blue * (1 - alpha))
  }

  public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

  var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

/// A light/dark pair with optional Increase Contrast variants. It resolves from the
/// environment's trait collection, so `preferredColorScheme` and system settings apply.
public struct AdaptiveColor: Hashable, Sendable {
  public let light: RGBColor
  public let dark: RGBColor
  public let lightHighContrast: RGBColor
  public let darkHighContrast: RGBColor

  public init(
    light: RGBColor, dark: RGBColor,
    lightHighContrast: RGBColor? = nil, darkHighContrast: RGBColor? = nil
  ) {
    self.light = light
    self.dark = dark
    self.lightHighContrast = lightHighContrast ?? light
    self.darkHighContrast = darkHighContrast ?? dark
  }

  public func resolved(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard)
    -> RGBColor
  {
    switch (scheme, contrast) {
    case (.dark, .increased): darkHighContrast
    case (.dark, _): dark
    case (_, .increased): lightHighContrast
    default: light
    }
  }

  public var color: Color {
    let value = self
    return Color(
      uiColor: UIColor { traits in
        let scheme: ColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
        let contrast: ColorSchemeContrast =
          traits.accessibilityContrast == .high ? .increased : .standard
        return value.resolved(scheme, contrast: contrast).uiColor
      })
  }
}
