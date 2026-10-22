// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

@Suite("Console theme mapping")
struct ThemeMappingTests {
  @Test(arguments: ["evergreen", "ocean", "plum", "terracotta"])
  func knownServerValuesMapExactly(_ value: String) {
    #expect(ConsoleTheme(serverValue: value).rawValue == value)
  }

  @Test(arguments: [nil, "", "unknown", "Ocean", " plum", "TERRACOTTA", "sunset"] as [String?])
  func unknownOrMissingValuesFallBackToEvergreen(_ value: String?) {
    #expect(ConsoleTheme(serverValue: value) == .evergreen)
    #expect(ConsoleTheme.fallback == .evergreen)
  }

  @Test func everyThemeHasADistinctPaletteAndName() {
    #expect(ConsoleTheme.allCases.count == 4)
    let accents = Set(ConsoleTheme.allCases.map { $0.palette.accent })
    #expect(accents.count == 4)
    #expect(Set(ConsoleTheme.allCases.map(\.displayName)).count == 4)
    for theme in ConsoleTheme.allCases { #expect(theme.palette.theme == theme) }
  }

  /// The web console's accents, before any accessibility adjustment (`styles.css`).
  @Test func accentsMirrorTheWebConsoleExactly() {
    let expected: [ConsoleTheme: (light: String, dark: String)] = [
      .evergreen: ("#24725f", "#68b8a2"),
      .ocean: ("#266a91", "#72b5dc"),
      .plum: ("#7b4c87", "#c18dcc"),
      .terracotta: ("#9b5037", "#df8e70"),
    ]
    for theme in ConsoleTheme.allCases {
      let accent = theme.palette.accent
      #expect(accent.light.hexString == expected[theme]?.light)
      #expect(accent.dark.hexString == expected[theme]?.dark)
      #expect(accent.resolved(.light) == accent.light)
      #expect(accent.resolved(.dark) == accent.dark)
      // Increase Contrast uses the web `--accent-strong` role.
      #expect(accent.resolved(.light, contrast: .increased) == theme.palette.accentStrong.light)
      #expect(accent.resolved(.dark, contrast: .increased) == theme.palette.accentStrong.dark)
    }
  }

  @Test func onAccentIsWhiteInLightAndDeepTintInDark() {
    for theme in ConsoleTheme.allCases {
      #expect(theme.palette.onAccent.light == RGBColor(0xffffff))
      #expect(theme.palette.onAccent.dark.relativeLuminance < 0.02)
    }
  }
}

@Suite("Colour arithmetic")
struct ColourArithmeticTests {
  @Test func contrastRatioMatchesWCAGReferencePoints() {
    let white = RGBColor(0xffffff)
    let black = RGBColor(0x000000)
    #expect(abs(white.contrastRatio(with: black) - 21) < 0.001)
    #expect(abs(white.contrastRatio(with: white) - 1) < 0.001)
    #expect(white.contrastRatio(with: black) == black.contrastRatio(with: white))
    // #767676 is the canonical lightest grey that passes 4.5:1 on white.
    #expect(RGBColor(0x767676).contrastRatio(with: white) >= 4.5)
    #expect(RGBColor(0x777777).contrastRatio(with: white) < 4.5)
  }

  @Test func hexRoundTripsAndCompositingIsLinear() {
    #expect(RGBColor(0x0a1713).hexString == "#0a1713")
    let red = RGBColor(0xff0000)
    #expect(red.composited(over: RGBColor(0xffffff), opacity: 0) == RGBColor(0xffffff))
    #expect(red.composited(over: RGBColor(0xffffff), opacity: 1) == red)
    #expect(RGBColor(0x000000).composited(over: RGBColor(0xffffff), opacity: 0.5).red == 0.5)
  }
}
