// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

/// Opaque surfaces text and controls sit on: iOS system backgrounds (sRGB values of
/// systemBackground, systemGroupedBackground, secondary/tertiary grouped backgrounds),
/// the theme canvas and the opaque glass fallback.
private func surfaces(_ scheme: ColorScheme, _ theme: ConsoleTheme) -> [RGBColor] {
  let system: [UInt32] =
    scheme == .light ? [0xffffff, 0xf2f2f7] : [0x000000, 0x1c1c1e, 0x2c2c2e]
  return system.map(RGBColor.init)
    + [
      theme.palette.canvas.resolved(scheme),
      DesignColor.opaqueControlSurface.resolved(scheme),
    ]
}

private let schemes: [ColorScheme] = [.light, .dark]
private let contrasts: [ColorSchemeContrast] = [.standard, .increased]
private let textAA = 4.5
private let graphicsAA = 3.0

@Suite("WCAG AA contrast")
struct ContrastTests {
  @Test(arguments: ConsoleTheme.allCases)
  func accentTextPassesAAOnEverySurface(_ theme: ConsoleTheme) {
    for scheme in schemes {
      for surface in surfaces(scheme, theme) {
        let standard = theme.palette.accent.resolved(scheme)
        let increased = theme.palette.accent.resolved(scheme, contrast: .increased)
        #expect(
          standard.contrastRatio(with: surface) >= textAA,
          "\(theme) \(scheme) accent \(standard) on \(surface)")
        #expect(increased.contrastRatio(with: surface) >= standard.contrastRatio(with: surface))
      }
    }
  }

  @Test(arguments: ConsoleTheme.allCases)
  func labelsOnAccentFillsPassAA(_ theme: ConsoleTheme) {
    for scheme in schemes {
      for contrast in contrasts {
        let fill = theme.palette.accent.resolved(scheme, contrast: contrast)
        let label = theme.palette.onAccent.resolved(scheme, contrast: contrast)
        #expect(
          label.contrastRatio(with: fill) >= textAA, "\(theme) \(scheme) \(contrast) on-accent")
      }
    }
  }

  /// Why dark filled controls never use a white label: every dark web accent fails it.
  @Test(arguments: ConsoleTheme.allCases)
  func whiteLabelsOnDarkAccentsWouldFail(_ theme: ConsoleTheme) {
    #expect(RGBColor(0xffffff).contrastRatio(with: theme.palette.accent.dark) < textAA)
  }

  @Test func statusColoursPassAAAsTextAndAsChipIcons() {
    let tones = [DesignColor.success, DesignColor.warning, DesignColor.danger, DesignColor.neutral]
    for theme in ConsoleTheme.allCases {
      for scheme in schemes {
        let label = RGBColor(scheme == .light ? 0x000000 : 0xffffff)
        for surface in surfaces(scheme, theme) {
          for tone in tones {
            let colour = tone.resolved(scheme)
            #expect(colour.contrastRatio(with: surface) >= textAA, "\(colour) on \(surface)")
            let fill = colour.composited(over: surface, opacity: DesignColor.toneFillOpacity)
            #expect(colour.contrastRatio(with: fill) >= graphicsAA, "\(colour) icon on fill")
            #expect(label.contrastRatio(with: fill) >= textAA)
          }
          let accent = theme.palette.accent.resolved(scheme)
          let accentFill = accent.composited(over: surface, opacity: DesignColor.toneFillOpacity)
          #expect(accent.contrastRatio(with: accentFill) >= graphicsAA)
        }
      }
    }
  }

  /// Documented adjustment: web `--warning` light `#a46618` fails AA on grouped surfaces.
  @Test func warningAdjustmentIsNecessaryAndMinimal() {
    let web = RGBColor(0xa46618)
    let grouped = RGBColor(0xf2f2f7)
    #expect(web.contrastRatio(with: grouped) < textAA)
    #expect(DesignColor.warning.light.hexString == "#8f5a12")
    #expect(DesignColor.warning.dark.hexString == "#daa258")
  }
}
