// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

// The web console's design tokens (`packages/web/webapp/src/styles.css`), mirrored exactly so
// the native app looks like the console. Names follow the CSS custom properties and classes.
// Themes override only app-bg, panel, rail and the accent roles (`ThemePalette`); every other
// colour here is theme-independent, as on the web.

/// Theme-independent web colour roles (`--surface…`, `--text…`, `--line…`, status hues).
public enum WebColor {
  /// `--surface`: cards and tables on the panel.
  public static let surface = AdaptiveColor(light: RGBColor(0xfdfdfb), dark: RGBColor(0x191c1a))
  /// `--surface-raised`: selected rows, popovers, focused fields.
  public static let surfaceRaised = AdaptiveColor(
    light: RGBColor(0xffffff), dark: RGBColor(0x1d211e))
  /// `--surface-subtle`: fields, header tiles, the user bubble.
  public static let surfaceSubtle = AdaptiveColor(
    light: RGBColor(0xf0f1ed), dark: RGBColor(0x202420))
  /// `--surface-hover`: hover/pressed fills, the stop button.
  public static let surfaceHover = AdaptiveColor(
    light: RGBColor(0xe9ebe6), dark: RGBColor(0x272c28))
  /// `--text`.
  public static let text = AdaptiveColor(light: RGBColor(0x191d1a), dark: RGBColor(0xf0f2ed))
  /// `--text-soft`: secondary labels and icons.
  public static let textSoft = AdaptiveColor(light: RGBColor(0x565d58), dark: RGBColor(0xb5bbb5))
  /// `--text-muted`: eyebrows, times, placeholders.
  public static let textMuted = AdaptiveColor(
    light: RGBColor(0x626a64), dark: RGBColor(0x9aa39b))
  /// `--line`: hairlines and row separators.
  public static let line = AdaptiveColor(light: RGBColor(0xdfe2dc), dark: RGBColor(0x2a2f2b))
  /// `--line-strong`: field and composer edges.
  public static let lineStrong = AdaptiveColor(
    light: RGBColor(0xcfd4cc), dark: RGBColor(0x383f39))
  /// `--cat-4`: delegation (agent/peer) identity.
  public static let delegation = AdaptiveColor(
    light: RGBColor(0x84528f), dark: RGBColor(0xc18dcc))
  /// `--danger` / `--danger-soft`.
  public static let danger = AdaptiveColor(light: RGBColor(0xa3423b), dark: RGBColor(0xeb8d83))
  public static let dangerSoft = AdaptiveColor(
    light: RGBColor(0xf4dfdc), dark: RGBColor(0x3b2523))
  /// `--warning` (web value; text uses `DesignColor.warning`, adjusted for AA).
  public static let warning = AdaptiveColor(light: RGBColor(0xa46618), dark: RGBColor(0xdaa258))
  /// `--success`.
  public static let success = AdaptiveColor(light: RGBColor(0x2f7a4d), dark: RGBColor(0x79c995))
  /// `.markdown pre code` text on the rail-coloured code block.
  public static let codeText = AdaptiveColor(light: RGBColor(0xe8eee8), dark: RGBColor(0xe8eee8))

  // Fixed job status colours: they never follow the console theme.
  /// `--process-job-progress`: running/progress glyphs.
  public static let jobProgress = AdaptiveColor(
    light: RGBColor(0xa07f00), dark: RGBColor(0xe2bf55))
  /// `--process-job-progress-text`.
  public static let jobProgressText = AdaptiveColor(
    light: RGBColor(0x786208), dark: RGBColor(0xe6ce83))
  /// `--process-job-warning-text`: questions.
  public static let jobWarningText = AdaptiveColor(
    light: RGBColor(0x7d5219), dark: RGBColor(0xe0b882))
  /// `--process-job-success-text`.
  public static let jobSuccessText = AdaptiveColor(
    light: RGBColor(0x2c6c45), dark: RGBColor(0x8bcfa2))
}

extension AdaptiveColor {
  /// The colour at a per-appearance opacity, e.g. `--accent-glow` (accent at 16% / 12%).
  public func color(lightOpacity: Double, darkOpacity: Double) -> Color {
    let value = self
    return Color(
      uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        let contrast: ColorSchemeContrast =
          traits.accessibilityContrast == .high ? .increased : .standard
        return value.resolved(dark ? .dark : .light, contrast: contrast).uiColor
          .withAlphaComponent(dark ? darkOpacity : lightOpacity)
      })
  }

  /// `color-mix(in srgb, self p%, other)` for two opaque roles.
  public func mixed(_ percent: Double, with other: AdaptiveColor) -> AdaptiveColor {
    let fraction = percent / 100
    return AdaptiveColor(
      light: light.composited(over: other.light, opacity: fraction),
      dark: dark.composited(over: other.dark, opacity: fraction),
      lightHighContrast: lightHighContrast.composited(
        over: other.lightHighContrast, opacity: fraction),
      darkHighContrast: darkHighContrast.composited(over: other.darkHighContrast, opacity: fraction)
    )
  }
}

// MARK: Typography

/// The web console's type scale. Each role is the web px size at the default content size and
/// scales with Dynamic Type relative to `textStyle`. The family is the system font (the web has
/// no `@font-face`; its Inter fallback resolves to SF on Apple) and SF Mono for mono roles.
public enum WebType: CaseIterable, Sendable {
  /// `.eyebrow`, `.dashboard-section-label`: 10 / 700 / .14em, uppercase.
  case eyebrow
  /// `.dashboard-section-count`: 10 / 500.
  case sectionCount
  /// `.dashboard-agent-name`: 18 / 700 / −.01em.
  case agentName
  /// `.agent-chip-initials`: 12 / 700 / .02em.
  case agentInitials
  /// `.agent-chip-label`: 10 / 600.
  case agentLabel
  /// `.agent-chip-badge`: 9 / 700.
  case agentBadge
  /// `.dashboard-search input` (touch): 16.
  case search
  /// `.dashboard-chip`: 10 / 650.
  case chip
  /// `.thread-title`, `.project-title`, `.running-card-title`: 12 / 650.
  case rowTitle
  /// `.thread-preview`, `.project-preview`: 10, leading 1.35.
  case rowSubtitle
  /// Thread time: 10, tabular.
  case rowTime
  /// `.archive-toggle`, `.data-mode-indicator`: 10.5.
  case footer
  /// `.conversation-title` (phone): 13 / 650.
  case conversationTitle
  /// Breadcrumb project/tag line: 10.5 / 600 (project badge metadata).
  case breadcrumb
  /// `.markdown` (phone): 13.5 / 1.62.
  case prose
  /// `.markdown table` (phone): 11.5.
  case table
  /// `.markdown pre`, inline code: mono 0.88em of prose.
  case code
  /// `.message-action`: 10.
  case messageAction
  /// `.message-system`: 12.
  case system
  /// `.reasoning-trigger`: 11.
  case reasoningTrigger
  /// `.reasoning-text`: 12 / 1.58.
  case reasoningText
  /// `.activity-trigger .reasoning-trigger-label`: 9.5 / 750 / .12em, uppercase.
  case activityLabel
  /// `.activity-row-label`: 11.5 / 650.
  case activityRowLabel
  /// `.activity-row-summary`, `.activity-meta`: 10.5.
  case activityMeta
  /// `.run-attribution`: 10.5 / 1.45.
  case runAttribution
  /// `.model-transition`, `.context-compaction-row`: 10.5 / 600 / .02em.
  case marker
  /// `.composer-input` (touch): 16 / 1.55.
  case composerInput
  /// `.composer-hint`: 10 / 1.5.
  case composerHint
  /// `.model-selector__model-name`: 12 / 650.
  case modelName
  /// `.model-selector__badge`: 10 / 750 / .05em, uppercase.
  case effortBadge
  /// `.context-display-trigger`: mono 9.
  case contextTrigger
  /// `.composer-trigger-item-copy strong`: 11.5 / 680.
  case triggerTitle
  /// `.composer-trigger-item-copy small`: 9.5.
  case triggerDetail
  /// `.process-job-stack-entry-name`, `.process-job-chip`: 12 / 650.
  case jobEntry
  /// `.process-job-title`: 13 / 600.
  case jobTitle
  /// `.process-job-meta`: 11.5.
  case jobMeta
  /// `.process-job-time`, `.process-job-detail`: mono 11, tabular.
  case jobMono
  /// `.process-job-output`: mono 11 / 1.55.
  case jobOutput
  /// `.process-job-output-head`, `.process-job-call-tool`: 11.5 / 650.
  case jobOutputHead
  /// `.process-job-error`, `.peer-question`, call bodies: 12.5 / 1.5.
  case jobDetail
  /// `.activity-step-tool`: mono 10.5 / 600.
  case stepTool
  /// `.activity-step-summary`: 10.
  case stepSummary
  /// `.activity-step-time`, `.activity-row-time`: mono 9.
  case stepTime
  /// `.attachment-chip`: 11.
  case attachment
  /// `.connection-banner` (phone): 10.
  case banner
  case sheetTitle, sheetSubtitle, optionName, optionID, effortOption
  case contextFigure, contextFigureRegular, contextNote, contextEyebrow

  public struct Spec: Sendable, Equatable {
    public var size: CGFloat
    public var weight: Font.Weight
    /// Letter spacing in em.
    public var tracking: CGFloat = 0
    /// CSS line-height as a multiple of the size; nil keeps the natural leading.
    public var lineHeight: CGFloat?
    public var uppercase = false
    public var mono = false
    public var tabular = false
    public var textStyle: Font.TextStyle = .body
  }

  public var spec: Spec {
    switch self {
    case .eyebrow:
      Spec(size: 10, weight: .bold, tracking: 0.14, uppercase: true, textStyle: .caption2)
    case .sectionCount:
      Spec(size: 10, weight: .medium, tabular: true, textStyle: .caption2)
    case .agentName: Spec(size: 18, weight: .bold, tracking: -0.01, textStyle: .title3)
    case .agentInitials:
      Spec(size: 12, weight: .bold, tracking: 0.02, textStyle: .footnote)
    case .agentLabel: Spec(size: 10, weight: .semibold, textStyle: .caption2)
    case .agentBadge: Spec(size: 9, weight: .bold, tabular: true, textStyle: .caption2)
    case .search: Spec(size: 16, weight: .regular, textStyle: .body)
    case .chip: Spec(size: 10, weight: .semibold, textStyle: .caption2)
    case .rowTitle: Spec(size: 12, weight: .semibold, textStyle: .subheadline)
    case .rowSubtitle: Spec(size: 10, weight: .regular, lineHeight: 1.35, textStyle: .caption2)
    case .rowTime: Spec(size: 10, weight: .regular, tabular: true, textStyle: .caption2)
    case .footer: Spec(size: 10.5, weight: .regular, textStyle: .caption2)
    case .conversationTitle: Spec(size: 13, weight: .semibold, textStyle: .subheadline)
    case .breadcrumb: Spec(size: 10.5, weight: .semibold, textStyle: .caption2)
    case .prose: Spec(size: 13.5, weight: .regular, lineHeight: 1.62, textStyle: .body)
    case .table: Spec(size: 11.5, weight: .regular, textStyle: .footnote)
    case .code: Spec(size: 11.88, weight: .regular, lineHeight: 1.5, mono: true, textStyle: .body)
    case .messageAction: Spec(size: 10, weight: .regular, textStyle: .caption2)
    case .system: Spec(size: 12, weight: .regular, textStyle: .footnote)
    case .reasoningTrigger: Spec(size: 11, weight: .regular, textStyle: .caption)
    case .reasoningText: Spec(size: 12, weight: .regular, lineHeight: 1.58, textStyle: .footnote)
    case .activityLabel:
      Spec(size: 9.5, weight: .heavy, tracking: 0.12, uppercase: true, textStyle: .caption2)
    case .activityRowLabel: Spec(size: 11.5, weight: .semibold, textStyle: .caption)
    case .activityMeta: Spec(size: 10.5, weight: .regular, textStyle: .caption2)
    case .runAttribution:
      Spec(size: 10.5, weight: .regular, lineHeight: 1.45, textStyle: .caption2)
    case .marker: Spec(size: 10.5, weight: .semibold, tracking: 0.02, textStyle: .caption2)
    case .composerInput: Spec(size: 16, weight: .regular, textStyle: .body)
    case .composerHint: Spec(size: 10, weight: .regular, textStyle: .caption2)
    case .modelName: Spec(size: 12, weight: .semibold, textStyle: .footnote)
    case .effortBadge:
      Spec(size: 10, weight: .heavy, tracking: 0.05, uppercase: true, textStyle: .caption2)
    case .contextTrigger: Spec(size: 9, weight: .regular, mono: true, textStyle: .caption2)
    case .triggerTitle: Spec(size: 11.5, weight: .bold, textStyle: .caption)
    case .triggerDetail: Spec(size: 9.5, weight: .regular, textStyle: .caption2)
    case .jobEntry: Spec(size: 12, weight: .semibold, tabular: true, textStyle: .footnote)
    case .jobTitle: Spec(size: 13, weight: .semibold, textStyle: .subheadline)
    case .jobMeta: Spec(size: 11.5, weight: .regular, textStyle: .caption)
    case .jobMono: Spec(size: 11, weight: .regular, mono: true, tabular: true, textStyle: .caption)
    case .jobOutput:
      Spec(size: 11, weight: .regular, lineHeight: 1.55, mono: true, textStyle: .caption)
    case .jobOutputHead: Spec(size: 11.5, weight: .semibold, textStyle: .caption)
    case .jobDetail: Spec(size: 12.5, weight: .regular, lineHeight: 1.5, textStyle: .footnote)
    case .stepTool: Spec(size: 10.5, weight: .semibold, mono: true, textStyle: .caption2)
    case .stepSummary: Spec(size: 10, weight: .regular, textStyle: .caption2)
    case .stepTime: Spec(size: 9, weight: .regular, mono: true, tabular: true, textStyle: .caption2)
    case .attachment: Spec(size: 11, weight: .regular, textStyle: .caption)
    case .banner: Spec(size: 10, weight: .regular, textStyle: .caption2)
    case .sheetTitle: Spec(size: 14, weight: .semibold, textStyle: .headline)
    case .sheetSubtitle: Spec(size: 10.5, weight: .regular, lineHeight: 1.45, textStyle: .caption2)
    case .optionName: Spec(size: 14, weight: .semibold, textStyle: .subheadline)
    case .optionID: Spec(size: 11, weight: .regular, mono: true, textStyle: .caption)
    case .effortOption: Spec(size: 12, weight: .semibold, textStyle: .footnote)
    case .contextFigure: Spec(size: 21, weight: .bold, tabular: true, textStyle: .title3)
    case .contextFigureRegular: Spec(size: 18, weight: .bold, tabular: true, textStyle: .title3)
    case .contextNote: Spec(size: 12, weight: .regular, lineHeight: 1.45, textStyle: .footnote)
    case .contextEyebrow:
      Spec(size: 10, weight: .heavy, tracking: 0.08, uppercase: true, textStyle: .caption2)
    }
  }

  /// SF's natural line height as a multiple of the point size (ascender + descender + leading).
  static let naturalLineHeight: CGFloat = 1.19
}

/// Applies a `WebType` role: scaled size, weight, tracking, leading and case.
struct WebFontModifier: ViewModifier {
  let spec: WebType.Spec
  @ScaledMetric private var size: CGFloat

  init(_ type: WebType) {
    spec = type.spec
    _size = ScaledMetric(wrappedValue: type.spec.size, relativeTo: type.spec.textStyle)
  }

  func body(content: Content) -> some View {
    let font = Font.system(
      size: size, weight: spec.weight, design: spec.mono ? .monospaced : .default)
    content
      .font(spec.tabular ? font.monospacedDigit() : font)
      .tracking(spec.tracking * size)
      .lineSpacing(spec.lineHeight.map { max(0, ($0 - WebType.naturalLineHeight) * size) } ?? 0)
      .textCase(spec.uppercase ? .uppercase : nil)
  }
}

extension View {
  /// Sets a web console type role. Default content size equals the web px; Dynamic Type scales.
  public func webFont(_ type: WebType) -> some View { modifier(WebFontModifier(type)) }
}

// MARK: Geometry

/// Web spacing, named after the surfaces that use it (phone values unless noted).
public enum WebSpace {
  /// Dashboard/project/settings side gutters (`--gutter-left/right`).
  public static let dashboardGutter: CGFloat = 17
  /// Transcript column padding at ≤560 px (`--column-padding`).
  public static let transcriptGutter: CGFloat = 12
  /// Transcript column padding on tablet widths (901–1100 px).
  public static let transcriptGutterRegular: CGFloat = 24
  /// Composer dock side/bottom padding at ≤560 px.
  public static let dockGutter: CGFloat = 8
  /// Composer dock padding on tablet widths.
  public static let dockGutterRegular: CGFloat = 24
  /// Chat header side padding at ≤560 px.
  public static let headerGutter: CGFloat = 9
  /// Successive dashboard sections and transcript messages (phone).
  public static let sectionGap: CGFloat = 23
  /// Successive dashboard sections and messages on tablet.
  public static let sectionGapRegular: CGFloat = 28
  /// Section head to its first row.
  public static let sectionHeadBottom: CGFloat = 8
  /// Header trailing tiles (phone 3, dashboard 8).
  public static let tileGap: CGFloat = 3
  public static let dashboardTileGap: CGFloat = 8
  /// Agent chip column gap.
  public static let agentGap: CGFloat = 8
  /// Thread/project row padding and the −8 px bleed.
  public static let rowPaddingVertical: CGFloat = 7
  public static let rowPaddingHorizontal: CGFloat = 8
  public static let rowGap: CGFloat = 10
  /// Title/subtitle gap inside a row (`.thread-copy`).
  public static let rowCopyGap: CGFloat = 3
}

/// Web radii and control sizes.
public enum WebRadius {
  /// `--radius-sm` (tables, footer pills).
  public static let small: CGFloat = 8
  /// Thread/project rows.
  public static let row: CGFloat = 9
  /// Header tiles, send/stop, code blocks.
  public static let tile: CGFloat = 10
  /// Agent squares, search, running cards (`--radius-md`).
  public static let medium: CGFloat = 12
  /// Job shelf (phone, closed).
  public static let shelf: CGFloat = 13
  /// Composer root (phone).
  public static let composer: CGFloat = 14
  /// Composer root (tablet), open job shelf, user bubble outer corners.
  public static let composerRegular: CGFloat = 16
  /// `--radius-lg`.
  public static let large: CGFloat = 18
}

public enum WebMetrics {
  /// Mobile header minimum height.
  public static let headerHeight: CGFloat = 58
  /// Header action tiles.
  public static let tile: CGFloat = 36
  /// Agent strip square.
  public static let agentSquare: CGFloat = 44
  /// Dashboard search field.
  public static let searchHeight: CGFloat = 42
  /// Thread/project/running row minimum height.
  public static let rowHeight: CGFloat = 58
  /// Row glyph column and running/project tiles.
  public static let rowGlyph: CGFloat = 30
  /// Footer pills and composer tools.
  public static let quietControl: CGFloat = 32
  /// Composer send/stop.
  public static let send: CGFloat = 34
  /// User bubble maximum width fraction (phone).
  public static let bubbleWidth: CGFloat = 0.88
  /// Transcript column maximum width.
  public static let column: CGFloat = 880
  /// Composer and job shelf maximum width.
  public static let composerWidth: CGFloat = 820
  /// iPad dashboard column width.
  public static let dashboardColumn: CGFloat = 340
}

/// `--shadow-sm` / `--shadow-lg` (zero spread; SwiftUI radius approximates CSS blur / 2).
public enum WebShadow: Sendable {
  case small, large
}

extension View {
  /// Applies a web elevation shadow, adapted for light and dark.
  public func webShadow(_ shadow: WebShadow) -> some View {
    modifier(WebShadowModifier(shadow: shadow))
  }
}

struct WebShadowModifier: ViewModifier {
  let shadow: WebShadow
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let dark = scheme == .dark
    switch shadow {
    case .small:
      content
        .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(dark ? 0.14 : 0.04), radius: 6, y: 3)
    case .large:
      content
        .shadow(color: .black.opacity(dark ? 0.55 : 0.20), radius: 40, y: 24)
        .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: 10, y: 4)
    }
  }
}

// MARK: Web primitives

/// The dashboard/chat header action tile: 36×36 (44 pt hit target), radius 10, subtle fill, soft
/// glyph; `.accent` is the new-conversation tile (accent-soft fill, accent glyph). Floats above
/// content, so it is Liquid Glass tinted with the web fill (opaque under Reduce Transparency).
public struct WebTileButtonStyle: ButtonStyle {
  public enum Tone: Sendable { case standard, accent }
  /// `.glass` floats the tile on Liquid Glass tinted with its fill; `.flat` is the web's plain
  /// fill (used where glass would read heavier than the web header, e.g. the phone chat bar).
  public enum Material: Sendable { case glass, flat }
  private let tone: Tone
  private let material: Material
  @Environment(\.consoleTheme) private var theme
  @Environment(\.isEnabled) private var enabled

  public init(_ tone: Tone = .standard, material: Material = .glass) {
    self.tone = tone
    self.material = material
  }

  public func makeBody(configuration: Configuration) -> some View {
    let palette = theme.palette
    let shape = RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    let fill = tone == .accent ? palette.accentSoft : WebColor.surfaceSubtle
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: 15, weight: .medium))
      .foregroundStyle(tone == .accent ? palette.accent.color : WebColor.textSoft.color)
      .frame(width: WebMetrics.tile, height: WebMetrics.tile)
      .background {
        if material == .flat {
          shape.fill(
            configuration.isPressed && tone == .standard
              ? WebColor.surfaceHover.color : fill.color)
        }
      }
      .modifier(TileGlass(enabled: material == .glass, shape: shape, fill: fill.color))
      .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
      .frame(
        minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget
      )
      .contentShape(Rectangle())
  }
}

struct TileGlass<S: Shape>: ViewModifier {
  let enabled: Bool
  let shape: S
  let fill: Color
  func body(content: Content) -> some View {
    if enabled {
      content.floatingGlass(in: shape, tint: fill, opaqueFill: fill)
    } else {
      content
    }
  }
}

/// A quiet 32 pt footer/notice pill (data mode, archived, jump to latest): muted text, no heavy
/// fill at rest. It floats above content, so it uses Liquid Glass.
public struct WebQuietPillStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label.webQuietPill(pressed: configuration.isPressed)
  }
}

struct WebQuietPillModifier: ViewModifier {
  let pressed: Bool
  var hitTarget = true
  @Environment(\.isEnabled) private var enabled

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    content
      .webFont(.footer)
      .foregroundStyle(pressed ? WebColor.text.color : WebColor.textSoft.color)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .frame(minHeight: WebMetrics.quietControl)
      .floatingGlass(in: shape, opaqueFill: WebColor.surfaceSubtle.color)
      .opacity(enabled ? 1 : 0.45)
      .frame(minHeight: hitTarget ? DesignMetrics.minimumHitTarget : nil)
      .contentShape(Rectangle())
  }
}

extension View {
  /// The quiet glass pill look for labels that are not buttons (for example a `Menu` label,
  /// whose control supplies its own hit target: pass `hitTarget: false`).
  public func webQuietPill(pressed: Bool = false, hitTarget: Bool = true) -> some View {
    modifier(WebQuietPillModifier(pressed: pressed, hitTarget: hitTarget))
  }
}

/// Dense web list rows: no system highlight, a `--surface-hover` wash while pressed.
public struct WebRowButtonStyle: ButtonStyle {
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        if configuration.isPressed {
          RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
            .fill(WebColor.surfaceHover.color)
        }
      }
  }
}

/// An uppercase eyebrow label (`.eyebrow`): 10 / 700 / .14em, muted.
public struct Eyebrow: View {
  private let text: String
  private let color: Color?
  public init(_ text: String, color: Color? = nil) {
    self.text = text
    self.color = color
  }
  public var body: some View {
    Text(text).webFont(.eyebrow).foregroundStyle(color ?? WebColor.textMuted.color)
      .lineLimit(1)
  }
}

#if DEBUG
  private struct WebTokenPreview: View {
    @Environment(\.consoleTheme) private var theme
    var body: some View {
      VStack(alignment: .leading, spacing: WebSpace.sectionHeadBottom) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Eyebrow("Sample console")
            Text("Atlas").webFont(.agentName).foregroundStyle(WebColor.text.color)
          }
          Spacer()
          Button("Settings", systemImage: "slider.horizontal.3") {}
            .buttonStyle(WebTileButtonStyle())
          Button("New", systemImage: "plus") {}.buttonStyle(WebTileButtonStyle(.accent))
        }
        Text("Row title 12 / 650").webFont(.rowTitle).foregroundStyle(WebColor.text.color)
        Text("Subtitle 10").webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
        Button {
        } label: {
          Label("Archived", systemImage: "archivebox")
        }
        .buttonStyle(WebQuietPillStyle())
      }
      .padding(WebSpace.dashboardGutter)
      .background(theme.palette.panel.color)
    }
  }

  #Preview("Web tokens — themes") { DesignPreviewMatrix { WebTokenPreview() } }

  #Preview("Web tokens — dark, AX") {
    DesignPreviewMatrix { WebTokenPreview() }
      .preferredColorScheme(.dark)
      .dynamicTypeSize(.accessibility3)
  }
#endif
