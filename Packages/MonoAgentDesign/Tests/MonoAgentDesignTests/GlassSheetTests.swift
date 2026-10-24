// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

/// Content drawn on the system presentation material (GLASS-RULES.md): text keeps AA on every
/// sampled backdrop, hairlines stay visible but quiet, group inks stay subtle.
@Suite("Glass sheet tokens")
struct GlassSheetTests {
  private let schemes: [ColorScheme] = [.light, .dark]

  @Test func textRolesPassAAOnTheMaterial() {
    for scheme in schemes {
      for backdrop in WebGlass.referenceBackdrops(scheme) {
        // Text sits on the bare material or on the quiet group ink.
        let grounds = [backdrop, WebGlass.groupFill.composited(over: backdrop, scheme)]
        for ground in grounds {
          for role in [WebColor.text, WebGlass.textSoft, WebGlass.textMuted] {
            let ratio = role.resolved(scheme).contrastRatio(with: ground)
            #expect(ratio >= 4.5, "\(scheme) \(role.resolved(scheme)) on \(ground): \(ratio)")
          }
        }
      }
    }
  }

  /// The documented adjustment: the web muted grey fails on the light medium-detent glass.
  @Test func webMutedNeedsTheGlassAdjustmentInLight() {
    let glass = RGBColor(0xe3e3e0)
    #expect(WebColor.textMuted.light.contrastRatio(with: glass) < 4.5)
    #expect(WebGlass.textMuted.light.contrastRatio(with: glass) >= 4.5)
    // Dark stays between the web muted and soft greys, keeping the muted/soft hierarchy.
    let muted = WebGlass.textMuted.dark.relativeLuminance
    #expect(muted > WebColor.textMuted.dark.relativeLuminance)
    #expect(muted < WebColor.textSoft.dark.relativeLuminance)
  }

  @Test(arguments: ConsoleTheme.allCases)
  func accentTextAndMetersPassOnTheMaterial(_ theme: ConsoleTheme) {
    let palette = theme.palette
    for scheme in schemes {
      for backdrop in WebGlass.referenceBackdrops(scheme) {
        let text = WebGlass.accentText(palette).resolved(scheme)
        #expect(text.contrastRatio(with: backdrop) >= 4.5, "\(theme) \(scheme) on \(backdrop)")
        // Meter fills are graphics: 3:1 against the translucent track.
        let track = WebGlass.track.composited(over: backdrop, scheme)
        #expect(palette.accent.resolved(scheme).contrastRatio(with: track) >= 3)
      }
    }
  }

  /// The consent veil keeps AA where bright or dark content bleeds through the medium-detent
  /// glass (sampled: light glass over a code block, dark glass over a light app frame).
  @Test(arguments: ConsoleTheme.allCases)
  func legibilityVeilKeepsAAOverBleed(_ theme: ConsoleTheme) {
    let bleed: [ColorScheme: RGBColor] = [.light: RGBColor(0x9b9e9b), .dark: RGBColor(0x6a706d)]
    for scheme in schemes {
      let ground = WebGlass.legibilityVeil.composited(over: bleed[scheme]!, scheme)
      for role in [
        WebColor.text, WebGlass.textSoft, WebGlass.textMuted,
        WebGlass.accentText(theme.palette),
      ] {
        let ratio = role.resolved(scheme).contrastRatio(with: ground)
        #expect(ratio >= 4.5, "\(theme) \(scheme) \(role.resolved(scheme)) on \(ground): \(ratio)")
      }
    }
  }

  @Test func inksStayTranslucentAndQuiet() {
    for scheme in schemes {
      for backdrop in WebGlass.referenceBackdrops(scheme) {
        let hairline = WebGlass.hairline.composited(over: backdrop, scheme)
        let group = WebGlass.groupFill.composited(over: backdrop, scheme)
        let track = WebGlass.track.composited(over: backdrop, scheme)
        // Visible as a divider, but a hairline rather than a rule.
        #expect((1.25...1.8).contains(hairline.contrastRatio(with: backdrop)))
        // Group fills only hint at grouping.
        #expect((1.03...1.3).contains(group.contrastRatio(with: backdrop)))
        #expect(track.contrastRatio(with: backdrop) > group.contrastRatio(with: backdrop))
      }
    }
    for ink in [WebGlass.hairline, WebGlass.groupFill, WebGlass.selectedFill, WebGlass.track] {
      #expect(ink.lightOpacity > 0 && ink.lightOpacity < 0.2)
      #expect(ink.darkOpacity > 0 && ink.darkOpacity < 0.2)
    }
  }
}
