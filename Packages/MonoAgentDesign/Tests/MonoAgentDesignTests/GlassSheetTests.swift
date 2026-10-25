// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

/// Content drawn on the system presentation material (GLASS-RULES.md): text keeps AA on every
/// sampled backdrop, hairlines stay visible but quiet, group inks stay subtle.
@Suite("Glass sheet tokens")
struct GlassSheetTests {
  private let schemes: [ColorScheme] = [.light, .dark]
  private let contrasts: [ColorSchemeContrast] = [.standard, .increased]

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

  /// Every reading role passes on the veil, selected ink, and the peer form's compounded
  /// Form-row / CodeDocumentView group inks. Resolve both foreground and ink under Increase Contrast.
  @Test(arguments: ConsoleTheme.allCases)
  func sheetVeilsKeepAAOverBleed(_ theme: ConsoleTheme) {
    for scheme in schemes {
      for contrast in contrasts {
        let bleed = WebGlass.sampledBleed(scheme)
        let sheet = WebGlass.sheetVeil.composited(over: bleed, scheme, contrast: contrast)
        let group = WebGlass.groupFill.composited(over: sheet, scheme, contrast: contrast)
        let grounds = [
          sheet, group,
          WebGlass.selectedFill.composited(over: sheet, scheme, contrast: contrast),
          WebGlass.groupFill.composited(over: group, scheme, contrast: contrast),
        ]
        for ground in grounds {
          for role in [WebColor.text, WebGlass.textSoft, WebGlass.textMuted] {
            let ratio = role.resolved(scheme, contrast: contrast).contrastRatio(with: ground)
            #expect(ratio >= 4.5, "\(scheme) \(contrast) \(role) on \(ground): \(ratio)")
          }
        }
        // Context figures and composer accent labels sit directly on the standard veil.
        let accent = WebGlass.accentText(theme.palette).resolved(scheme, contrast: contrast)
        #expect(accent.contrastRatio(with: sheet) >= 4.5, "\(theme) \(scheme) \(contrast)")
        let consent = WebGlass.consentVeil.composited(over: bleed, scheme, contrast: contrast)
        for role in [
          WebColor.text, WebGlass.textSoft, WebGlass.textMuted, WebGlass.accentText(theme.palette),
        ] {
          let ratio = role.resolved(scheme, contrast: contrast).contrastRatio(with: consent)
          #expect(ratio >= 4.5, "\(theme) \(scheme) \(contrast) \(role) on \(consent): \(ratio)")
        }
      }
    }
  }

  /// Wake day chips use the theme accent as ink, never a second material. Their primary
  /// labels/checkmarks keep AA in every theme, including Increase Contrast resolution.
  @Test(arguments: ConsoleTheme.allCases)
  func selectedWakeDayLabelsPassAA(_ theme: ConsoleTheme) {
    let selected = GlassInk(theme.palette.accent, light: 0.12, dark: 0.20)
    for scheme in schemes {
      for contrast in contrasts {
        for backdrop in WebGlass.referenceBackdrops(scheme) + [WebGlass.sampledBleed(scheme)] {
          let sheet = WebGlass.sheetVeil.composited(over: backdrop, scheme, contrast: contrast)
          let chip = selected.composited(over: sheet, scheme, contrast: contrast)
          #expect(
            WebColor.text.resolved(scheme, contrast: contrast).contrastRatio(with: chip) >= 4.5,
            "\(theme) \(scheme) \(contrast) selected day on \(chip)")
        }
      }
    }
  }

  @Test func consentVeilIsAtLeastAsStrongAsStandard() {
    #expect(WebGlass.consentVeil.lightOpacity >= WebGlass.sheetVeil.lightOpacity)
    #expect(WebGlass.consentVeil.darkOpacity >= WebGlass.sheetVeil.darkOpacity)
  }

  /// One step (1%) less veil fails muted AA on the compounded peer form ink.
  @Test func sheetVeilIsTheMinimum() {
    for scheme in schemes {
      let veil = WebGlass.sheetVeil
      let lower = GlassInk(
        veil.base, light: veil.lightOpacity - 0.01, dark: veil.darkOpacity - 0.01)
      let sheet = lower.composited(over: WebGlass.sampledBleed(scheme), scheme)
      let group = WebGlass.groupFill.composited(over: sheet, scheme)
      let ground = WebGlass.groupFill.composited(over: group, scheme)
      #expect(WebGlass.textMuted.resolved(scheme).contrastRatio(with: ground) < 4.5)
    }
  }

  /// Worst pixels in empty-area samples of floating controls over the tall synthetic code fixture.
  @Test func floatingTextKeepsAAOverCode() {
    for scheme in schemes {
      let shelfBleed = RGBColor(scheme == .dark ? 0x393c3a : 0x929593)
      let shelf = WebGlass.sheetVeil.composited(over: shelfBleed, scheme)
      let composer = RGBColor(scheme == .dark ? 0x353836 : 0xf3f3f1)
      for ground in [shelf, WebGlass.groupFill.composited(over: shelf, scheme), composer] {
        #expect(WebGlass.textMuted.resolved(scheme).contrastRatio(with: ground) >= 4.5)
      }
      if scheme == .light {
        #expect(WebGlass.textMuted.light.contrastRatio(with: shelfBleed) < 4.5)
      }
    }
  }

  @Test func increasedContrastResolvesGlassRoles() {
    #expect(WebGlass.textMuted.resolved(.light, contrast: .increased) == WebColor.text.light)
    #expect(WebGlass.textMuted.resolved(.dark, contrast: .increased) == WebColor.textSoft.dark)
    for theme in ConsoleTheme.allCases {
      for scheme in schemes {
        #expect(
          WebGlass.accentText(theme.palette).resolved(scheme, contrast: .increased)
            == theme.palette.accentStrong.resolved(scheme))
      }
    }
  }

  @Test func mutedTextFollowsItsLayer() {
    #expect(WebMaterial.content.textMuted == WebColor.textMuted)
    #expect(WebMaterial.glass.textMuted == WebGlass.textMuted)
  }

  @Test(arguments: ConsoleTheme.allCases)
  func jobActionTextPassesOnGroupedMaterial(_ theme: ConsoleTheme) {
    for scheme in schemes {
      for backdrop in WebGlass.referenceBackdrops(scheme) {
        let group = WebGlass.groupFill.composited(over: backdrop, scheme)
        let wash = GlassInk(theme.palette.accent, light: 0.16, dark: 0.22)
        let button = wash.composited(over: group, scheme)
        #expect(WebColor.text.resolved(scheme).contrastRatio(with: button) >= 4.5)
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
