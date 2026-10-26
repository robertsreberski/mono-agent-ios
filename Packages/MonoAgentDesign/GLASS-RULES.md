# Glass rules: web content, Liquid Glass chrome

The app looks like the web console, and it follows the platform's Liquid Glass design. The
two meet at one boundary. **Content is web. Floating chrome is glass. A surface never mixes
the two.** The failure this prevents is three materials stacked on one sheet: a translucent
header band, a solid web body, and the system glass showing around the edges.

## Two layers

| Layer | What belongs here | Material |
|---|---|---|
| **Content** | Dashboard lists and rows, the transcript canvas, transcript cards (messages, tool calls, code, Markdown, reply files, MCP app frames), forms that *are* the screen | Solid web tokens (`ThemePalette.panel/canvas`, `WebColor.surface…`, `--line`). Unchanged. |
| **Floating / navigation** | Header controls, the composer, the composer job shelf, jump-to-latest, footer buttons, toolbars, menus, popovers, sheets | **One** Liquid Glass material per surface |

## Rules for the floating layer

There are two kinds of floating surface:

- **Text-carrying sheets and popovers** use the system material plus the frosted web veil.
  This covers the context sheet and iPad popover, run settings, the skill browser, the
  peer-question sheet, quote selection, console management and the connection editor, MCP
  consent, project/tag settings, the wake editor, and the composer's job shelf, suggestion
  popover and status line. Menus are native SwiftUI `Menu`s: no veil and no custom background.
  The veil is only for text-heavy custom popovers a `Menu` cannot express (for example a
  model browser with search or a colour-swatch editor).
- **Compact floating controls** stay pure glass with no veil. This covers the composer root,
  header tiles, jump-to-latest, footer buttons, toolbars and native system menus.

1. **One material per surface.** Never put a solid web panel or surface fill on or inside
   glass. Bands, bodies, cards and footers inside a sheet have no fill of their own.
2. **Sheets and popovers use the system presentation material.** No
   `presentationBackground`, no header band and no body fill. There is no custom
   `presentationCornerRadius`: the system radius is concentric with the device.
3. **Text-carrying sheets and popovers lay the frosted veil over the material**
   (`.webSheetVeil()`). The veil is the web raised surface, uniform and edge to edge: one
   tinted material, never a band. Its opacity is the minimum that keeps muted text AA over
   the busiest bleed we sampled (see *The frosted veil* below). Consent prompts use the
   stronger `.webSheetVeil(.consent)`. Custom popovers drawn with `floatingGlass` (the
   composer job shelf, suggestions and status line) put the same veil inside their glass shape.
4. **Compact floating controls are pure glass.** No veil, no web fill tint. Where the web
   draws a 1 px `--line-strong` edge (the composer, the job shelf, the suggestion popover),
   light mode keeps it as a stroke only. Dark glass already separates from the dark
   transcript.
5. **Headers sit on the material** (`WebSheetHeader`). They use web title and subtitle type,
   the web's plain borderless ✕ in a 44 pt hit target with the existing accessibility label,
   and a hairline below.
6. **Sections are separated by hairlines** (`WebSheetSection`, `WebHairline`). Where grouping
   needs it (an argument preview, an open job row, a form row), use at most the quiet
   translucent ink (`.webGlassGroup()`, `WebGlass.groupFill`). Expanded job rows tint only
   their headers, never an entire nested subtree: compounded inks can wash out dark text.
7. **Layer-aware components.** `.webSheetVeil()` and `.webGlassContent()` set
   `EnvironmentValues.webMaterial = .glass`. `SettingsGroup`, `.settingsField()`,
   `.webInput()`, `ChoiceRow`, `QuotePreview`, `AttachmentChip` and `SuggestionRow` then
   swap their solid web surfaces for inks through `.webLayeredSurface(…)`. Screens reused
   in a sheet use `.webPanelBackground(panel)`, which paints only in the content layer. The
   same component therefore stays solid in the transcript and turns translucent in a sheet.
8. **Web accents for meters and figures.** Meter fills use `palette.accent`. Tracks use
   `WebGlass.track`. Accent *text* uses `WebGlass.accentText`. Icon tiles use
   `palette.accentInk`. Thinking-chip labels/edges and composer effort badges use `palette.accentStrong` in both
   appearances: ordinary dark accent text on accent ink falls below AA on busy sheet bleed
   (`selectedEffortLabelsPassAA`).
9. **Actions:** primary is `.glassProminent` tinted with the web accent, with `onAccent`
   labels. Secondary is `.glass`. Use `.designButtonStyle(_, placement: .floating)`; it falls
   back to opaque styles under Reduce Transparency. Small in-row actions inside the job shelf
   (`WebSmallButtonStyle`) use translucent ink, not nested glass.
10. **Navigation bars.** On phones, the conversation's web header is a `safeAreaBar` with the
    system hard scroll-edge effect and no panel band. On iPad, the system bar keeps its own
    glass, with no `toolbarBackground`. The two standalone dashboard footer buttons are a
    bottom overlay: content scrolls beneath them, with bottom content margins so the last row
    clears their hit targets. No shared pill, hard scroll-edge effect, band or fade. Jump to
    latest overlays the dock's top edge at −20 pt, with no reserved safe-area band. While
    shown, the first dock surface has 24 pt of non-interactive top padding, clear of its full
    44 pt target. The circle's lower glass is clipped over full-width dock material (especially
    the job shelf), so the dock supplies that part's material rather than stacking two glasses.
11. **Text keeps the web scale, spacing and hierarchy.** The web colour is used unless it
    fails AA on the material. In that case use the `WebGlass` adjustment (table below).
12. **The large detent is opaque** (the system does this). The veil and inks are translucent,
    so they read the same over the medium-detent glass and the opaque sheet.
13. **Reduce Transparency** keeps working through `floatingGlass(…opaqueFill:opaqueStroke:)`
    and the design button styles. System sheets handle it themselves.

### The frosted veil

The medium-detent glass lets strong content show through. Measured on the iOS 27 simulator:

| Backdrop | Glass lifts or drops to | Without a veil |
|---|---|---|
| Dark code block behind the light sheet | `#9b9e9b` | muted text 2.5:1 |
| Light MCP app frame behind the dark sheet | `#6a706d` | muted text 2.3:1 |

No text colour fixes this, and vibrancy measured worse in the common case (see below). So
every text-carrying sheet lays the web raised surface over the material. Its opacity is the
lowest that keeps `WebGlass.textMuted` ≥ 4.5:1 over those two bleeds, including the
quiet group, selected-row and compounded form-row/code-preview inks (not just the bare veil):

| Veil | Light | Dark | Guarantee | Test |
|---|---|---|---|---|
| `WebGlass.sheetVeil` | 71% | 84% | Muted, soft and primary text AA, including two group inks (4.52:1 light, 4.50:1 dark). A 1% lower veil fails AA on compounded ink. | `GlassSheetTests.sheetVeilsKeepAAOverBleed`, `sheetVeilIsTheMinimum` |
| `WebGlass.consentVeil` | 75% | 84% | Accent text AA as well; never weaker than standard | same |

The Markdown dark capture alone needs no veil (6.16:1). The dark value is bound by the
brighter MCP-frame bleed and the peer form’s two group inks. Accent text is lighter than muted text in dark mode and passes
on the standard veil too. Consent, where the accent names the tool method, uses at least
the standard veil in each scheme (stronger in light mode).
This mirrors the web: its sheets are opaque raised surfaces, and its MCP confirmation is
`--surface-raised` at 96% over a blurred frame.

## Glass tokens (`GlassSheet.swift`)

| Token | Value | Why |
|---|---|---|
| `WebGlass.hairline` | `--text` at 14% (light) / 12% (dark) | The web `--line` is `--text` at ≈14% over raised (light) and ≈6% (dark). 6% is invisible on dark glass (1.05:1). Measured 1.3–1.45:1 on every backdrop. |
| `WebGlass.groupFill` | `--text` 4% / 6% | The `--surface-subtle` step as ink: 1.08–1.2:1, a hint, not a card |
| `WebGlass.selectedFill` | `--text` 7% / 10% | Selected model row, pressed rows |
| `WebGlass.track` | `--text` 9% / 14% | Meter tracks. The accent fill keeps ≥ 3:1 against it. |
| `WebGlass.textSoft` | web `--text-soft` | Passes AA everywhere (≥ 4.98:1) |
| `WebGlass.textMuted` | light `--text-soft`; dark muted lifted 60% toward soft | The web muted is **4.34:1** on light glass (`#e3e3e0`) and 3.9:1 on the dark group ink. Both are adjusted. |
| `WebGlass.accentText` | light `--accent-strong`; dark `--accent` | The light `--accent` is 4.48:1 on light glass |
| `WebGlass.sheetVeil` | `--surface-raised` 71% light / 84% dark | Every text-carrying sheet and popover |
| `WebGlass.consentVeil` | `--surface-raised` 75% light / 84% dark | Consent prompts |
| `palette.accentInk` | `--accent` 12% / 20% | `--accent-soft` icon tiles and selections as ink |

Reference backdrops (`WebGlass.referenceBackdrops`) were sampled from simulator screenshots.
Large detent: `#ffffff` / `#1c1c1e`. Medium detent over plain and busy Markdown transcripts:
light `#e3e3e0`–`#dddddb`, dark `#292c2a`–`#353736`. `GlassSheetTests` holds every text role
to AA on all of them, bare and on the group ink. Veiled-bleed checks also cover
standard-veil accent text (all themes), compounded groups and Increase Contrast resolution.

The expanded job shelf over the tall synthetic code fixture samples a worst empty-area pixel of
`#929593` in light mode: glass muted text is only 2.24:1 there (the modal
`#a0a3a1` is 2.66:1). It therefore carries the same veil inside its
rounded glass shape. The composer root stays pure glass: its sampled worst open-area
backdrops (`#f3f3f1` / `#353836`) keep muted text above AA. See
`GlassSheetTests.floatingTextKeepsAAOverCode` and the `bleed` job-stack captures.

### Why not hierarchical `.secondary`?

The vibrant `.secondary` style was measured on the same sheets. It does help in light mode
when a dark code block bleeds through the glass: 4.4:1, against 2.5:1 for the web grey. On
the plain material and at the opaque large detent, though, it renders as a pale grey:
3.2:1 (`#7e7e7b` on `#e4e4e1`) and 3.44:1 (`#8a8a8e` on white). In dark mode it measured 3.3:1. The web-derived colours above are therefore the
default. Over very strong bleed (a dark code block directly behind the light medium sheet),
these colours alone are insufficient; the approved frosted veil now resolves that case.

### Organize surfaces

Project/tag editors and the wake editor use `.webSheetVeil()` edge to edge. Their fields and
destructive-action groups use quiet group ink; headings, counters and explanatory labels use
the glass muted role. `OrganizeSheetHeader` keeps a plain ✕ (spoken as Cancel), a hairline,
and the floating primary Save action with its opaque accessibility fallback. The wake day
choices use accent ink with primary labels/checkmarks when selected, quiet group ink otherwise,
not seven nested glass surfaces (`selectedWakeDayLabelsPassAA`). Accent secondary affordances
keep `WebGlass.accentText`; they must not silently become neutral labels.

Conversation actions, project pickers and tag checklists use native `Menu`s, including nested
menus and toggles. Do not draw a solid background or veil behind menu content. Editors that
need richer content (colour swatches, searchable model lists, wake forms) keep their veiled
sheet/popover. `OrganizeMenuScroll` is only a bounded scrolling layout, not a menu material;
`WakeSummaryView` resolves muted text from `webMaterial`. Rename alerts, destructive
alerts/confirmation dialogs and the dashboard context menu retain the system appearance.
The project page stays solid web content; header tiles remain compact glass controls and its
inline context Edit action is plain web text, not glass on a content card.

## Apple guidance this relies on

- HIG, *Materials*
  (<https://developer.apple.com/design/human-interface-guidelines/materials>):
  - "Liquid Glass forms a distinct functional layer for controls and navigation elements …
    that floats above the content layer."
  - "**Don't use Liquid Glass in the content layer.** … use standard materials for elements
    in the content layer."
  - "**Use Liquid Glass effects sparingly.**"
  - "Help ensure legibility by using vibrant colors on top of materials." We measured
    vibrancy and kept web colours where they measured better. See above.
- *Adopting Liquid Glass*
  (<https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass>):
  - "standard components like bars, sheets, popovers, and controls automatically adopt this
    material."
  - "**Reduce your use of custom backgrounds in controls and navigation elements.**"
  - "half sheets are inset from the edge of the display to allow content to peek through
    … When a half sheet expands to full height, it transitions to a more opaque appearance."
  - "**Audit the backgrounds of sheets and popovers.** … remove those custom background
    views."
  - "avoid overcrowding or layering Liquid Glass elements on top of each other."
- HIG, *Color* → *Liquid Glass color*
  (<https://developer.apple.com/design/human-interface-guidelines/color>):
  - "To emphasize primary actions, apply color to the background rather than to symbols or
    text."
  - "Refrain from adding color to the background of multiple controls." This is why only
    the primary action is tinted.
- Xcode 27's bundled *Implementing Liquid Glass Design* notes (SwiftUI/UIKit): "Ensure
  sufficient contrast between text and the glass background."

These quotes were fetched from Apple's documentation in October 2026. Apple does not
publish numbers for how translucent a medium-detent sheet is. The figures here are
simulator measurements on iOS 27.0 and may change between OS releases and on device. The sheet
close button is the web's plain ✕, not a glass circle. Glass actions on a sheet (consent)
follow the system sheet toolbar pattern. Apple's guidance otherwise discourages layering
glass, so we use glass only for those controls and never for content boxes. The frosted veil
tints the material. Apple's guidance asks for the system background, so the veil is uniform
and edge to edge. It keeps the sheet one material and follows the HIG's advice to ensure
legibility (as with a dimming layer behind clear glass).

## Checklist for a new floating surface

- [ ] No `presentationBackground`, `presentationCornerRadius` or `.background(WebColor…)`
      on or inside the surface.
- [ ] Can a native `Menu` express it? Use one, with no veil or custom background.
      Text-heavy sheet/custom popover? `.webSheetVeil()` (or the veil inside a custom `floatingGlass` shape).
      Compact control? Pure glass, with a light-mode `--line-strong` stroke if the web has
      an edge.
- [ ] Header: `WebSheetHeader`. Sections: `WebSheetSection` / `WebHairline`. Boxes:
      `.webGlassGroup()`.
- [ ] Secondary text uses `WebGlass.textMuted` / `textSoft`. Accent text uses
      `WebGlass.accentText`.
- [ ] Actions: `.designButtonStyle(.primary/.secondary, placement: .floating)`.
- [ ] Capture light and dark, medium and large detents, and the iPad popover. Check them
      over a busy transcript.
