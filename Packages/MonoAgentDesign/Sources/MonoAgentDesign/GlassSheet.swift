// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

// Content drawn directly on a Liquid Glass surface: system sheets and popovers (presentation
// material) and the floating job shelf. See GLASS-RULES.md. One material per surface: no
// solid web panel/surface fills on or inside glass. Sections are separated by hairlines and,
// where grouping needs it, at most a subtle translucent ink that works in light and dark.

/// A web colour at a per-appearance opacity, for marks drawn on a material (hairlines, quiet
/// group fills, meter tracks). Translucent, so it reads the same over the medium-detent glass
/// and the opaque large detent.
public struct GlassInk: Hashable, Sendable {
  public let base: AdaptiveColor
  public let lightOpacity: Double
  public let darkOpacity: Double

  public init(_ base: AdaptiveColor, light: Double, dark: Double) {
    self.base = base
    lightOpacity = light
    darkOpacity = dark
  }

  public var color: Color { base.color(lightOpacity: lightOpacity, darkOpacity: darkOpacity) }

  /// The ink as it appears over an opaque backdrop (for contrast checks).
  public func composited(over backdrop: RGBColor, _ scheme: ColorScheme) -> RGBColor {
    base.resolved(scheme).composited(
      over: backdrop, opacity: scheme == .dark ? darkOpacity : lightOpacity)
  }
}

/// Web tokens adapted for glass. Text keeps the web scale and roles; colours change only where
/// the web value fails AA on the material (documented in GLASS-RULES.md, unit-tested).
public enum WebGlass {
  /// System material backdrops sampled from iOS 27 simulator screenshots: the opaque large
  /// detent (`#ffffff` / `#1c1c1e`) and the medium-detent sheet over a plain and over a busy
  /// Markdown transcript (light `#e3e3e0`–`#dddddb`, dark `#292c2a`–`#353736`).
  public static func referenceBackdrops(_ scheme: ColorScheme) -> [RGBColor] {
    (scheme == .dark
      ? [0x1c1c1e, 0x292c2a, 0x353736]
      : [0xffffff, 0xe3e3e0, 0xdddddb]).map(RGBColor.init)
  }

  /// Section divider. The web `--line` is `--text` at ≈14% over the raised surface (light) and
  /// ≈6% (dark); 6% vanishes on the dark material, so dark uses 12%.
  public static let hairline = GlassInk(WebColor.text, light: 0.14, dark: 0.12)
  /// Quiet grouping (preview boxes, open job rows): the web `--surface-subtle` step as ink.
  public static let groupFill = GlassInk(WebColor.text, light: 0.04, dark: 0.06)
  /// Selected or pressed rows.
  public static let selectedFill = GlassInk(WebColor.text, light: 0.07, dark: 0.10)
  /// Meter tracks (context window, plan usage).
  public static let track = GlassInk(WebColor.text, light: 0.09, dark: 0.14)

  /// The consent-prompt veil (`webGlassLegibilityVeil`).
  public static let legibilityVeil = GlassInk(WebColor.surfaceRaised, light: 0.75, dark: 0.75)

  /// `--text-soft` passes AA on every backdrop.
  public static let textSoft = WebColor.textSoft
  /// `--text-muted` is 4.3:1 on the light medium-detent glass, so light uses `--text-soft`.
  /// Dark lifts the web muted 60% toward `--text-soft` (#9aa39b → ≈#aab1aa) so it keeps AA on
  /// the quiet group ink over the busiest sampled dark glass (the web value measures 3.9:1).
  public static let textMuted = AdaptiveColor(
    light: WebColor.textSoft.light,
    dark: WebColor.textMuted.mixed(40, with: WebColor.textSoft).dark,
    lightHighContrast: WebColor.text.light, darkHighContrast: WebColor.textSoft.dark)

  /// Accent text and figures. The light web `--accent` is 4.5:1 on the light glass with no
  /// margin, so light text uses `--accent-strong`; dark keeps `--accent`. Meters keep `accent`.
  public static func accentText(_ palette: ThemePalette) -> AdaptiveColor {
    AdaptiveColor(
      light: palette.accentStrong.light, dark: palette.accent.dark,
      lightHighContrast: palette.accentStrong.light, darkHighContrast: palette.accentStrong.dark)
  }
}

extension View {
  /// A uniform legibility veil over the whole presentation material (the web raised surface
  /// at 75%). The only sanctioned sheet exception: prompts that must stay AA over arbitrary
  /// third-party content (MCP consent). Applied edge to edge, so the sheet stays one material.
  public func webGlassLegibilityVeil() -> some View {
    background { WebGlass.legibilityVeil.color.ignoresSafeArea() }
  }
}

/// A 1 pt divider in the glass hairline ink.
public struct WebHairline: View {
  private let leading: CGFloat
  private let trailing: CGFloat
  public init(leading: CGFloat = 0, trailing: CGFloat = 0) {
    self.leading = leading
    self.trailing = trailing
  }
  public var body: some View {
    Rectangle().fill(WebGlass.hairline.color).frame(height: 1)
      .padding(.leading, leading).padding(.trailing, trailing)
      .accessibilityHidden(true)
  }
}

/// A sheet/popover section (web `.context-detail section`, P10/16/12): an uppercase eyebrow,
/// an optional mono trailing detail, the content and a hairline above. No fill unless
/// `grouped`, which adds only the quiet translucent group ink.
public struct WebSheetSection<Content: View>: View {
  private let title: String?
  private let detail: String?
  private let divider: Bool
  private let grouped: Bool
  private let content: Content

  public init(
    _ title: String? = nil, detail: String? = nil, divider: Bool = true, grouped: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    self.divider = divider
    self.grouped = grouped
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if title != nil || detail != nil {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          if let title {
            Text(title).webFont(.contextEyebrow).foregroundStyle(WebGlass.textMuted.color)
              .accessibilityAddTraits(.isHeader)
          }
          Spacer(minLength: 0)
          if let detail {
            Text(detail).webFont(.optionID).foregroundStyle(WebGlass.textMuted.color)
          }
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 10).padding(.horizontal, 16).padding(.bottom, 12)
    .background {
      if grouped {
        RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
          .fill(WebGlass.groupFill.color).padding(.horizontal, 8).padding(.vertical, 4)
      }
    }
    .overlay(alignment: .top) {
      if divider { WebHairline() }
    }
  }
}

extension View {
  /// The quiet translucent group ink with a hairline edge, for boxes on glass (argument
  /// previews, job output). Never a solid web surface.
  public func webGlassGroup(cornerRadius: CGFloat = WebRadius.small, outlined: Bool = true)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return background(WebGlass.groupFill.color, in: shape)
      .overlay {
        if outlined { shape.strokeBorder(WebGlass.hairline.color, lineWidth: 1) }
      }
  }
}

#if DEBUG
  /// Catalog/preview stand-in for a presentation material: the real sheets use the system one.
  struct SheetMaterialSample<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
      content()
        .frame(maxWidth: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
  }

  #Preview("Sheet sections on glass") {
    DesignPreviewMatrix {
      SheetMaterialSample {
        VStack(spacing: 0) {
          WebSheetHeader("Context and cost") {}
          WebSheetSection("Context window", detail: "standard", divider: false) {
            Text("84k / 200k tokens").webFont(.contextNote)
          }
          WebSheetSection("Estimated cost") {
            Text("$0.42").webFont(.optionID)
          }
          WebSheetSection("Arguments", grouped: true) {
            Text("{ \"beds\": 3 }").webFont(.optionID).padding(8).frame(
              maxWidth: .infinity, alignment: .leading
            ).webGlassGroup()
          }
        }
      }
    }
  }
#endif
