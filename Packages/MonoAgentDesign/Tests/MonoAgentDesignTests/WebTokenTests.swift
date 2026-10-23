// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

@Suite("Web console tokens")
struct WebTokenTests {
  @Test func neutralRolesMirrorTheWebStylesheet() {
    let expected: [(AdaptiveColor, String, String)] = [
      (WebColor.surface, "#fdfdfb", "#191c1a"),
      (WebColor.surfaceRaised, "#ffffff", "#1d211e"),
      (WebColor.surfaceSubtle, "#f0f1ed", "#202420"),
      (WebColor.surfaceHover, "#e9ebe6", "#272c28"),
      (WebColor.text, "#191d1a", "#f0f2ed"),
      (WebColor.textSoft, "#565d58", "#b5bbb5"),
      (WebColor.textMuted, "#626a64", "#9aa39b"),
      (WebColor.line, "#dfe2dc", "#2a2f2b"),
      (WebColor.lineStrong, "#cfd4cc", "#383f39"),
      (WebColor.delegation, "#84528f", "#c18dcc"),
      (WebColor.danger, "#a3423b", "#eb8d83"),
      (WebColor.warning, "#a46618", "#daa258"),
      (WebColor.success, "#2f7a4d", "#79c995"),
      (WebColor.jobProgress, "#a07f00", "#e2bf55"),
      (WebColor.jobProgressText, "#786208", "#e6ce83"),
      (WebColor.jobWarningText, "#7d5219", "#e0b882"),
      (WebColor.jobSuccessText, "#2c6c45", "#8bcfa2"),
    ]
    for (color, light, dark) in expected {
      #expect(color.light.hexString == light)
      #expect(color.dark.hexString == dark)
    }
  }

  @Test func themePanelsAndRailsMirrorTheWebCascade() {
    let expected: [ConsoleTheme: [String]] = [
      .evergreen: ["#f7f7f4", "#141715", "#171a18", "#0b0d0c"],
      .ocean: ["#f6f8fa", "#13191e", "#111a21", "#091017"],
      .plum: ["#faf7fa", "#18141a", "#1b151d", "#0f0b11"],
      .terracotta: ["#faf7f5", "#191411", "#201611", "#100b09"],
    ]
    for theme in ConsoleTheme.allCases {
      let palette = theme.palette
      #expect(
        [palette.panel.light, palette.panel.dark, palette.rail.light, palette.rail.dark].map(
          \.hexString) == expected[theme])
    }
    // `--process-job-stack-bg` is mix(panel 55%, surface): rounded web value #fafaf7 / #161917.
    let stack = ConsoleTheme.evergreen.palette.jobStackBackground
    #expect(stack.light.hexString == "#fafaf7")
    #expect(stack.dark.hexString == "#161917")
  }

  /// Text roles keep the web's contrast on every web surface they sit on, light and dark.
  @Test(arguments: ConsoleTheme.allCases)
  func webTextRolesPassAAOnWebSurfaces(_ theme: ConsoleTheme) {
    for scheme in [ColorScheme.light, .dark] {
      let surfaces = [
        theme.palette.panel, WebColor.surface, WebColor.surfaceRaised, WebColor.surfaceSubtle,
        theme.palette.jobStackBackground,
      ].map { $0.resolved(scheme) }
      for surface in surfaces {
        for role in [WebColor.text, WebColor.textSoft, WebColor.textMuted] {
          #expect(role.resolved(scheme).contrastRatio(with: surface) >= 4.5, "\(theme) \(scheme)")
        }
        // Accent on the soft accent fill (send button, new tile) stays a 3:1 graphic.
        let soft = theme.palette.accentSoft.resolved(scheme)
        #expect(theme.palette.accent.resolved(scheme).contrastRatio(with: soft) >= 3)
      }
      let code = WebColor.codeText.resolved(scheme)
      #expect(code.contrastRatio(with: theme.palette.rail.resolved(scheme)) >= 7)
    }
  }

  @Test func jobStatusTextPassesAAOnTheShelf() {
    for scheme in [ColorScheme.light, .dark] {
      let shelf = ConsoleTheme.evergreen.palette.jobStackBackground.resolved(scheme)
      for role in [WebColor.jobProgressText, WebColor.jobWarningText, WebColor.jobSuccessText] {
        #expect(role.resolved(scheme).contrastRatio(with: shelf) >= 4.5, "\(scheme)")
      }
    }
  }

  @Test func typeScaleKeepsTheWebSizes() {
    #expect(WebType.eyebrow.spec.size == 10 && WebType.eyebrow.spec.uppercase)
    #expect(WebType.eyebrow.spec.tracking == 0.14)
    #expect(WebType.rowTitle.spec.size == 12)
    #expect(WebType.rowSubtitle.spec.size == 10)
    #expect(WebType.prose.spec.size == 13.5 && WebType.prose.spec.lineHeight == 1.62)
    #expect(WebType.composerInput.spec.size == 16)
    #expect(WebType.search.spec.size == 16)
    #expect(WebType.conversationTitle.spec.size == 13)
    #expect(WebType.contextTrigger.spec.mono)
    #expect(WebType.allCases.allSatisfy { $0.spec.size >= 8 && $0.spec.size <= 18 })
  }

  @Test func geometryKeepsTheWebMetrics() {
    #expect(WebSpace.dashboardGutter == 17)
    #expect(WebSpace.transcriptGutter == 12)
    #expect(WebSpace.dockGutter == 8)
    #expect(WebSpace.headerGutter == 9)
    #expect(WebSpace.sectionGap == 23)
    #expect(WebMetrics.headerHeight == 58 && WebMetrics.tile == 36)
    #expect(WebMetrics.agentSquare == 44 && WebMetrics.searchHeight == 42)
    #expect(WebMetrics.rowHeight == 58 && WebMetrics.send == 34)
    #expect(WebRadius.tile == 10 && WebRadius.composerRegular == 16)
    // Visual tiles are smaller than the platform minimum; their hit targets are not.
    #expect(DesignMetrics.minimumHitTarget >= 44)
  }
}
