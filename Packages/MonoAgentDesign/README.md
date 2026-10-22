# MonoAgentDesign

The iOS-only, value-driven design system: semantic tokens, console themes and Liquid Glass
components. It has no Kit, Store or network dependency. Components take values and
actions. They never fetch data, mutate stores or own navigation. Feature screens build
from these tokens and components rather than ad hoc colours, fonts or glass.

The package test directory is also a file-system-synchronized source root of the app
unit-test target, so these tests run in the shared iOS test plan. The linked-package
scheme otherwise does not discover package tests when invoked through the app project.
Add source/test files without project edits.

## Themes

`ConsoleTheme(serverValue:)` maps the bootstrap identity's `console.theme`
(`evergreen`, `ocean`, `plum`, `terracotta`). Exact wire values only. `nil`, unknown or
differently-cased values fall back to evergreen, as does any console that is not live
(the app derives the theme from a `.connected` identity). Apply it with
`.consoleTheme(_:)`. This sets `EnvironmentValues.consoleTheme` and the system tint.

`ThemePalette` mirrors the web console (`styles.css`): `accent`, `accentStrong`,
`onAccent`, `accentSoft` and the page `canvas`. Content uses native semantic surfaces
(`DesignColor.contentSurface`), not reproduced browser geometry. Colours are exact
`RGBColor` values wrapped in `AdaptiveColor` light/dark/Increase Contrast sets, so the
WCAG contrast of every pairing is unit-tested.

| Theme | Accent light / dark (web, unchanged) | Lowest accent-on-surface ratio light / dark | Label on accent fill light (white) / dark (`onAccent`) |
|---|---|---|---|
| Evergreen | `#24725f` / `#68b8a2` | 4.99 / 5.95 | 5.76 / 7.83 |
| Ocean | `#266a91` / `#72b5dc` | 5.20 / 6.21 | 5.91 / 8.25 |
| Plum | `#7b4c87` / `#c18dcc` | 5.67 / 5.28 | 6.51 / 7.11 |
| Terracotta | `#9b5037` / `#df8e70` | 5.12 / 5.47 | 5.84 / 7.19 |

Surfaces tested: white, `#f2f2f7` (light grouped), black, `#1c1c1e`, `#2c2c2e`, each
theme canvas and the opaque glass fallback. All accents pass AA (4.5:1) as text, so **no
accent is adjusted**. Pairing rule: dark accents are light, so a white label on them
fails (2.24–2.64). Filled controls therefore always use `onAccent`, never white. Under
Increase Contrast, `accent` resolves to web `--accent-strong`.

Status hues are theme-independent and match the web values except one adjustment:

| Tone | Light / dark | Lowest ratio light / dark | Note |
|---|---|---|---|
| Success | `#2f7a4d` / `#79c995` | 4.53 / 7.04 | web value |
| Warning | `#8f5a12` / `#daa258` | 5.00 / 6.17 | **adjusted**: web light `#a46618` is 4.05 on grouped/canvas surfaces |
| Danger | `#a3423b` / `#eb8d83` | 5.35 / 5.75 | web value |
| Neutral | `#626a64` / `#9aa39b` | 4.83 / 5.37 | web `--text-muted` |

Chip and banner fills are the tone at 14% opacity. Their icons keep at least 3:1 and their
labels use primary text. Every status also has a distinct SF Symbol and a text label, so
colour is never the only cue.

## Tokens

- `DesignSpacing` `xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32`.
- `DesignRadius` `sm 8 · md 12 · lg 18 · xl 24` (continuous corners).
- `DesignMetrics` minimum hit target 44 pt, readable width 680 pt, unread dot 10 pt
  (scaled with Dynamic Type).
- `DesignTextStyle` / `.designFont(_:)`: screen title, section title, headline, body,
  callout, supporting, caption and code. These are Dynamic Type text styles only.
- `DesignColor` content and opaque surfaces, separator, status tones and fill opacity.

## Components

| Component | API | Notes |
|---|---|---|
| Theme environment | `.consoleTheme(_:)`, `\.consoleTheme`, `.prefersOpaqueSurfaces(_:)` | Opaque override for previews/catalog; the system Reduce Transparency setting is honoured too |
| Buttons | `.designButtonStyle(.primary/.secondary, placement: .inline/.floating)` | Inline: `.borderedProminent`/`.bordered`. Floating: `.glassProminent`/`.glass`, falling back to opaque styles |
| Floating glass | `.floatingGlass(in:tint:interactive:)` | The only custom `glassEffect` entry point |
| Content card | `.contentSurface(padding:)` | Opaque, readable; outline under Increase Contrast |
| Status | `StatusKind`, `StatusTone`, `StatusIndicator(_:label:)`, `StatusChip(_:label:placement:)` | Symbol + text; floating chips use glass |
| Unread | `UnreadMarker(count:)` | Dot, count, `99+`; spoken as "N unread" |
| Banner | `ConnectionBanner(_:title:message:actionTitle:action:)` | Kinds: insecure HTTP, offline, storage, notice. Icon stacks above text at accessibility sizes |
| States | `EmptyStateView`, `ErrorStateView`, `LoadingStateView` | Optional single action |
| Section header | `SectionHeader(_:detail:accessory:)` | Header trait; optional trailing accessory |
| Composer shell | `ComposerBarShell(leading:field:trailing:)` | Layout only: one `GlassEffectContainer`, readable width. No drafts or sending |
| Markdown slot | `RichMarkdownPlaceholder(source:)` | **Placeholder**: shows raw source, labelled as such, until the rich renderer arrives |

Every component file has `#Preview`s across the four themes, dark mode, accessibility sizes
and/or the opaque fallback. Previews and their `DesignPreviewMatrix` helper are DEBUG-only.

## Glass rules

- System navigation bars, toolbars, tab bars and sheets adopt Liquid Glass automatically.
  Prefer them.
- Custom glass (`.floating` buttons, floating chips, `floatingGlass`, `ComposerBarShell`)
  is only for controls that float above content. Place bottom bars with
  `.safeAreaBar(edge: .bottom)`. Text-heavy screens add
  `.scrollEdgeEffectStyle(.hard, for: .bottom)` so the bar stays legible over text.
- Never put transcripts, forms, dense lists or banners on glass. Never nest glass in glass.
  Group neighbouring custom glass in one `GlassEffectContainer`.
- `glassEffectID` is reserved for real morph transitions. None exist yet.
- Reduce Transparency (system or `prefersOpaqueSurfaces`) swaps every custom glass
  surface for an opaque surface. Opaque floating buttons are fully opaque so content never
  shows through. Increase Contrast adds outlines and strong accents. Reduce Motion
  disables interactive glass.

## Catalog

The DEBUG app catalog (`App/Catalog/ComponentCatalog.swift`) shows every component. Its
toolbar switches theme, accessibility text size and the Reduce Transparency fallback.
Launch it with `--scenario design-catalog`, `design-catalog-<theme>`,
`design-catalog-accessibility` or `design-catalog-reduce-transparency`. New components
add a catalog section. New screenshots add an XCUI capture named
`synthetic-fixture__<scenario>__<appearance>[__<variant>]` and an entry in
`Tools/screenshot-matrix.json`.
