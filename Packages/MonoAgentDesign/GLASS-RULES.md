# Glass rules: web content, Liquid Glass chrome

The app looks like the web console, and it follows the platform's Liquid Glass design. The
two meet at one boundary. **Content is web. Floating chrome is glass. A surface never mixes
the two.** The failure this prevents is three materials stacked on one sheet: a translucent
header band, a solid web body, and the system glass showing around the edges.

## Two layers

| Layer | What belongs here | Material |
|---|---|---|
| **Content** | Dashboard lists and rows, the transcript canvas, transcript cards (messages, tool calls, code, Markdown, reply files, MCP app frames), forms that *are* the screen | Solid web tokens (`ThemePalette.panel/canvas`, `WebColor.surface…`, `--line`). Unchanged. |
| **Floating / navigation** | Header controls, the composer, the composer job shelf, jump-to-latest, footer pills, toolbars, menus, popovers, sheets | **One** Liquid Glass material per surface |

## Rules for the floating layer

1. **One material per surface.** Never put a solid web panel or surface fill on or inside
   glass. Bands, bodies, cards and footers inside a sheet have no fill of their own.
2. **Sheets and popovers use the system presentation material.** No solid
   `presentationBackground`, no header band, no body fill, no custom
   `presentationCornerRadius` (the system radius is concentric with the device).
3. **Headers sit on the material** (`WebSheetHeader`): web title/subtitle type, a glass
   close button, a hairline below.
4. **Sections are separated by hairlines** (`WebSheetSection`, `WebHairline`). Where grouping
   needs it (an argument preview, an open job row), use at most the quiet translucent ink
   (`.webGlassGroup()`, `WebGlass.groupFill`). It works in light and dark and at both detents.
5. **Web accents for meters and figures.** Meter fills use `palette.accent`. Tracks use
   `WebGlass.track`. Accent *text* uses `WebGlass.accentText`.
6. **Actions:** primary is `.glassProminent` tinted with the web accent, with `onAccent`
   labels. Secondary is `.glass`. Use `.designButtonStyle(_, placement: .floating)`; it falls
   back to opaque styles under Reduce Transparency. Small in-row actions inside the job shelf
   (`WebSmallButtonStyle`) use translucent ink, not nested glass.
7. **Text keeps the web scale, spacing and hierarchy.** The web colour is used unless it
   fails AA on the material. In that case use the `WebGlass` adjustment (table below).
8. **The large detent is opaque** (the system does this). Content must read there with no
   extra fill. Translucent inks are chosen so they work over both the glass and the opaque
   sheet.
9. **Reduce Transparency** keeps working through `floatingGlass(…opaqueFill:opaqueStroke:)`
   and the design button styles. System sheets handle it themselves.

### The one exception: consent over third-party content

The medium-detent glass lets strong content show through. Measured on the iOS 27 simulator,
a light MCP app frame behind the dark consent sheet lifts the glass to `#6a706d`. That drops
the web soft text to 2.6:1 and the accent method name to 2.2:1. A consent prompt must stay
legible over arbitrary app content. So `McpConsentView` applies `.webGlassLegibilityVeil()`:
the web raised surface at 75%, edge to edge, behind the whole sheet. The sheet stays one
(tinted) material with no band. This mirrors the web, where the MCP confirmation is
`--surface-raised` at 96% over a blurred app frame. Every role keeps ≥ 4.5:1 over the sampled
bleed (`GlassSheetTests.legibilityVeilKeepsAAOverBleed`).

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
| `WebGlass.legibilityVeil` | `--surface-raised` 75% | Consent exception only |

Reference backdrops (`WebGlass.referenceBackdrops`) were sampled from simulator screenshots.
Large detent: `#ffffff` / `#1c1c1e`. Medium detent over plain and busy Markdown transcripts:
light `#e3e3e0`–`#dddddb`, dark `#292c2a`–`#353736`. `GlassSheetTests` holds every text role
to AA on all of them, bare and on the group ink.

### Why not hierarchical `.secondary`?

The vibrant `.secondary` style was measured on the same sheets. It does help in light mode
when a dark code block bleeds through the glass: 4.4:1, against 2.5:1 for the web grey. On
the plain material and at the opaque large detent, though, it renders as a pale grey:
3.2:1 (`#7e7e7b` on `#e4e4e1`) and 3.44:1 (`#8a8a8e` on white). In dark mode it measured 3.3:1. The web-derived colours above are therefore the
default. Over very strong bleed (a dark code block directly behind the light medium sheet),
secondary text can still drop below AA. This is listed as an open design question.

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
simulator measurements on iOS 27.0 and may change between OS releases and on device. Glass
buttons on the sheet material (the close button and the actions) follow the system sheet
toolbar pattern. Apple's guidance otherwise discourages layering glass, so we use glass
only for those controls and never for content boxes.

## Checklist for a new floating surface

- [ ] No `presentationBackground`, `presentationCornerRadius` or `.background(WebColor…)`
      on or inside the surface (except the documented consent veil).
- [ ] Header: `WebSheetHeader`. Sections: `WebSheetSection` / `WebHairline`. Boxes:
      `.webGlassGroup()`.
- [ ] Secondary text uses `WebGlass.textMuted` / `textSoft`. Accent text uses
      `WebGlass.accentText`.
- [ ] Actions: `.designButtonStyle(.primary/.secondary, placement: .floating)`.
- [ ] Capture light and dark, medium and large detents, and the iPad popover. Check them
      over a busy transcript.
