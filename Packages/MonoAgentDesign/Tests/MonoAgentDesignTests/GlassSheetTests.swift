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

  /// The sheet veil is the lowest opacity that keeps muted (and soft, primary) text AA over
  /// the busiest sampled bleed; the consent veil also keeps accent text AA there.
  @Test(arguments: ConsoleTheme.allCases)
  func sheetVeilsKeepAAOverBleed(_ theme: ConsoleTheme) {
    for scheme in schemes {
      let bleed = WebGlass.sampledBleed(scheme)
      let sheet = WebGlass.sheetVeil.composited(over: bleed, scheme)
      let grounds = [
        sheet, WebGlass.groupFill.composited(over: sheet, scheme),
        WebGlass.selectedFill.composited(over: sheet, scheme),
      ]
      for ground in grounds {
        for role in [WebColor.text, WebGlass.textSoft, WebGlass.textMuted] {
          let ratio = role.resolved(scheme).contrastRatio(with: ground)
          #expect(ratio >= 4.5, "\(scheme) \(role.resolved(scheme)) on \(ground): \(ratio)")
        }
      }
      let consent = WebGlass.consentVeil.composited(over: bleed, scheme)
      for role in [
        WebColor.text, WebGlass.textSoft, WebGlass.textMuted, WebGlass.accentText(theme.palette),
      ] {
        let ratio = role.resolved(scheme).contrastRatio(with: consent)
        #expect(ratio >= 4.5, "\(theme) \(scheme) \(role.resolved(scheme)) on \(consent)")
      }
    }
  }

  /// Minimal: one step (1%) less veil no longer keeps muted text AA over the bleed.
  @Test func sheetVeilIsTheMinimum() {
    for scheme in schemes {
      let veil = WebGlass.sheetVeil
      let lower = GlassInk(
        veil.base, light: veil.lightOpacity - 0.01, dark: veil.darkOpacity - 0.01)
      let sheet = lower.composited(over: WebGlass.sampledBleed(scheme), scheme)
      let ground = WebGlass.selectedFill.composited(over: sheet, scheme)
      #expect(WebGlass.textMuted.resolved(scheme).contrastRatio(with: ground) < 4.5)
    }
  }

  @Test func mutedTextFollowsItsLayer() {
    #expect(WebMaterial.content.textMuted == WebColor.textMuted)
    #expect(WebMaterial.glass.textMuted == WebGlass.textMuted)
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
