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

## Web console tokens (fidelity)

The app mirrors the web console's `styles.css`, not generic iOS metrics:

- `ThemePalette` adds `panel` (the shared dashboard/chat material), `rail` (code blocks),
  `accentGlow` (focus ring) and `jobStackBackground`; `WebColor` carries the
  theme-independent surfaces (`surface`, `surfaceRaised`, `surfaceSubtle`, `surfaceHover`),
  text (`text`, `textSoft`, `textMuted`), lines (`line`, `lineStrong`), `delegation` and the
  fixed job status hues (`jobProgress…`, `jobWarningText`, `jobSuccessText`). Exact values and
  AA contrast on every web surface are unit-tested (`WebTokenTests`).
- `WebType` / `.webFont(_:)`: each role is the web px size at the default content size
  (`@ScaledMetric(relativeTo:)`), so Dynamic Type still scales it; weights, em tracking,
  line-height and uppercase eyebrows are carried over. Family: SF / SF Mono (the web has no
  `@font-face`).
- `WebSpace`, `WebRadius`, `WebMetrics`, `.webShadow(_:)`: gutters (dashboard 17, transcript
  12/24, dock 8/24, header 9), 23/28 section rhythm, 58 pt rows, 36 pt tiles in 44 pt hit
  targets, 42 pt search, 34 pt send, composer radius 14/16, shadow-sm/lg.
- Web primitives: `WebTileButtonStyle`, `WebQuietPillStyle` / `.webQuietPill()`,
  `WebRowButtonStyle`, `Eyebrow`, `ProjectBadge`, `TagBadge`, `UserBubble`,
  `MessageActionButton`, `TranscriptNotice`, `TranscriptMarkerRow`, `AttributionBox`,
  `CodeDocumentView(style: .block)`.

Glass stays limited to floating chrome: header tiles and back button, the composer root and
job shelf, footer/jump pills and system sheets. Their Reduce Transparency fallback is the
opaque web fill (`floatingGlass(in:tint:opaqueFill:opaqueStroke:)`). Inside glass, web
surfaces become `WebGlass` inks (see GLASS-RULES.md).

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
| Banner | `ConnectionBanner(_:title:message:actionTitle:action:)` | Kinds: insecure HTTP, offline, storage, problem (a refresh/read failed), notice. Icon stacks above text at accessibility sizes |
| Agent tile | `AgentTile(initials:caption:presence:selected:pinned:badge:)`, `AgentTile.accessibilityLabel(…)`, `AgentTile.badge(running:unread:)` | Monogram square. Presence symbol (online/degraded/offline, dashed when offline), pin star, one corner badge: running (bolt + count) wins over unread (outlined count); both are spoken |
| Tag / project chips | `TagChip(_:color:)`, `ProjectChip(_:color:)`, `LabelColor(serverValue:)` | Web `--project-ink` on `--project-tint` pairs for the eight wire colours; `default` follows the theme. Ink-on-tint is AA-tested |
| Activity | `ActivityIndicator(_:)`, `ActivityState` | Confirmed running vs last-known (unconfirmed): distinct symbols and spoken words |
| Conversation row | `ConversationRow(_:)`, `ConversationRowContent` | Value-driven row for recent, running, search and project lists: kind/monogram/folder tile, title (attributed for search highlights), unread, wake, activity, preview, project/tag chips (+N after three, wrapping), detail and one composed VoiceOver sentence. Tile moves above the text at accessibility sizes |
| States | `EmptyStateView`, `ErrorStateView`, `LoadingStateView` | Optional single action |
| Section header | `SectionHeader(_:detail:accessory:)` | Header trait; optional trailing accessory |
| Composer shell | `ComposerBarShell(leading:field:trailing:)` | Layout only: one `GlassEffectContainer`, readable width. No drafts or sending |
| Composer parts | `AttachmentChip(name:detail:isImage:thumbnail:phase:onRemove:)`, `SuggestionRow`, `QuotePreview(_:onDismiss:)`, `ChoiceRow(_:detail:selected:multiple:)` | Opaque content pieces used inside or above the composer and in question forms. Chips speak upload progress/failure; choices use symbols + the selected trait, never colour alone |
| Rich documents | `RichTextDocumentView(source:)`, `RichDocument.parse(_:)` | Bounded GFM parsing (≤4 KiB synchronously for final first layout; larger sources on a cancellation-aware serial actor, streaming leading/trailing throttled with an 83 ms maximum inter-parse wait; in-flight results publish without cancellation by new tokens), shared 8 MiB/256-document + 4 MiB/2048 attributed-run caches, native selectable inline text; HTML stays literal. Exact swift-markdown 0.7.3 / swift-cmark 0.9.0; see root README and bundled ThirdPartyNotices |
| Code | `CodeDocumentView(source:language:)` | Horizontal scroller, accessible selectable monospaced text, copy; bounded display with explicit notice |
| Activity | `ActivityDisclosure(_:summary:status:detail:identifier:expanded:content:)` | Value-driven expansion, lazy payload construction, non-colour status and VoiceOver expansion state |
| Content disclosure | `ContentDisclosure(_:expanded:content:label:)` | Opaque native button, independent nested identifiers, lazy payload, minimum hit target |
| Rich replies | `ReplyFileCard`, `ReplyFailureCard`, `ReplyImageTile`, `ReplyLightbox`, `RestartProposalCard` | Value-driven opaque web surfaces; local-image lightbox has swipe, bounded zoom, share and floating chrome; restart requires explicit confirmation actions |
| Context/cost | `ContextDisplay(_:expanded:)`, `ContextDisplayContent` | Value-only disclosure; header or composer placement, explicit unknown/partial labels, AX-stacked rows |
| Route | `RouteBadge(model:effort:detail:)` | Read-only route label with full accessible provenance, not evidence of a run |
| Sheets on glass | `WebSheetHeader(_:subtitle:closeLabel:closeIdentifier:divider:onClose:)`, `WebSheetSection(_:detail:divider:grouped:content:)`, `WebHairline(leading:trailing:)`, `.webGlassGroup(cornerRadius:outlined:)`, `.webGlassLegibilityVeil()`, `WebGlass`, `GlassInk` | Content drawn directly on a system sheet/popover material or the job shelf glass: hairline sections, translucent inks, AA-adjusted text roles (GLASS-RULES.md) |

Every component file has `#Preview`s across the four themes, dark mode, accessibility sizes
and/or the opaque fallback. Previews and their `DesignPreviewMatrix` helper are DEBUG-only.

## Glass rules

**Read [GLASS-RULES.md](GLASS-RULES.md) first.** Content is web: solid web tokens. Floating
chrome (header controls, composer, job shelf, menus, popovers, sheets) is one Liquid Glass
material per surface, with no solid web fill on or inside it. Its glass tokens are
`WebGlass`, `GlassInk`, `WebHairline`, `WebSheetHeader`, `WebSheetSection` and
`.webGlassGroup()`. The summary below predates it and still applies.

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
