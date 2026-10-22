// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// Layout spacing on a 4-point grid (plus a 2-point hairline step).
public enum DesignSpacing {
  public static let xxs: CGFloat = 2
  public static let xs: CGFloat = 4
  public static let sm: CGFloat = 8
  public static let md: CGFloat = 12
  public static let lg: CGFloat = 16
  public static let xl: CGFloat = 24
  public static let xxl: CGFloat = 32

  public static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl, xxl]
}

/// Continuous corner radii. Mirrors the web `--radius-sm/md/lg` steps.
public enum DesignRadius {
  public static let sm: CGFloat = 8
  public static let md: CGFloat = 12
  public static let lg: CGFloat = 18
  /// Floating control surfaces such as the composer field.
  public static let xl: CGFloat = 24

  public static let scale: [CGFloat] = [sm, md, lg, xl]
}

/// Layout metrics that are not spacing.
public enum DesignMetrics {
  /// Apple's minimum interactive target.
  public static let minimumHitTarget: CGFloat = 44
  /// Readable content column on wide layouts (iPad, landscape).
  public static let readableWidth: CGFloat = 680
  /// Unread dot diameter at the default text size; scaled with Dynamic Type.
  public static let unreadDot: CGFloat = 10
}

/// Semantic typography. Every role is a Dynamic Type text style, never a fixed size.
public enum DesignTextStyle: CaseIterable, Sendable {
  case screenTitle
  case sectionTitle
  case headline
  case body
  case callout
  case supporting
  case caption
  case code

  public var textStyle: Font.TextStyle {
    switch self {
    case .screenTitle: .title2
    case .sectionTitle: .headline
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .supporting: .subheadline
    case .caption: .footnote
    case .code: .callout
    }
  }

  public var font: Font {
    switch self {
    case .screenTitle: .system(textStyle, weight: .bold)
    case .sectionTitle: .system(textStyle, weight: .semibold)
    case .code: .system(textStyle, design: .monospaced)
    default: .system(textStyle)
    }
  }
}

extension View {
  public func designFont(_ style: DesignTextStyle) -> some View { font(style.font) }
}

/// Theme-independent semantic colours. Content surfaces are native system colours.
public enum DesignColor {
  /// Readable, opaque surface for grouped content (cards, banners, transcript later).
  public static let contentSurface = Color(uiColor: .secondarySystemGroupedBackground)
  /// Opaque replacement for glass when transparency is reduced.
  public static let opaqueControlSurface = AdaptiveColor(
    light: RGBColor(0xffffff), dark: RGBColor(0x2c2c2e))
  public static let separator = Color(uiColor: .separator)

  /// Status hues mirror the web `--success/--warning/--danger/--text-muted` values.
  /// Light warning is darkened from `#a46618` to meet AA on grouped/canvas surfaces.
  public static let success = AdaptiveColor(light: RGBColor(0x2f7a4d), dark: RGBColor(0x79c995))
  public static let warning = AdaptiveColor(light: RGBColor(0x8f5a12), dark: RGBColor(0xdaa258))
  public static let danger = AdaptiveColor(light: RGBColor(0xa3423b), dark: RGBColor(0xeb8d83))
  public static let neutral = AdaptiveColor(light: RGBColor(0x626a64), dark: RGBColor(0x9aa39b))

  /// Opacity of a tone behind its chip or banner content.
  public static let toneFillOpacity: Double = 0.14
}
