# Mono Agent for iPhone and iPad

A native SwiftUI client for the mono-agent web console. It includes saved console
connections, an offline-capable observable console store, a Liquid Glass design system
([MonoAgentDesign](Packages/MonoAgentDesign/README.md)) and the console dashboard. The
conversation transcript includes live Markdown, reasoning and tool activity; the composer is still a placeholder. The connected console's theme (evergreen, ocean, plum or
terracotta) styles the app; disconnected or unknown themes use evergreen.
GPL-3.0-only; see [LICENSE](LICENSE).

## Prerequisites and build

- Xcode 27.1 or newer Xcode 27 with Swift 6.4+, iOS/iPadOS 27 deployment target.
- Install Xcode first-launch components and an iOS 27+ simulator runtime to run UI tests.
- Open `MonoAgent.xcodeproj`, choose the shared **MonoAgent** scheme, then an iPhone or iPad.
  SwiftPM resolves the pinned Markdown parser; no project generator is required.

For a physical device with a free Apple Personal Team:

1. Add your Apple account in Xcode Settings → Accounts.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored).
3. Set your unique `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` locally, or choose
   your Personal Team in Signing & Capabilities without committing those project edits.
4. Enable Developer Mode on the device, pair/trust it, select it and run.

Free provisioning generally expires after **7 days**; reconnect and run from Xcode to
reprovision. No paid-program capability, push entitlement or background polling is used.
Never commit signing identities, team IDs or provisioning files.

Unsigned compile (does not need a booted simulator):

```sh
xcodebuild -project MonoAgent.xcodeproj -scheme MonoAgent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build
```

## Connect safely

Tap **Add console**, enter an explicit `http://` or `https://` root URL, then **Connect**.
Loopback, LAN IPv4/IPv6 (IPv6 in brackets), Tailscale HTTPS DNS and transparent reverse
proxies at the root are supported. Optional ports and a trailing slash are accepted;
path prefixes, credentials, query strings and fragments are rejected. On a physical
phone, `localhost` means the **phone**, not your computer: use the computer's LAN address
or a private HTTPS tunnel instead.

**There is no application login. Anyone who can reach the console may control its agents.**
Use a trusted network or private tunnel; do not expose it to the public internet. Native
connections do not share browser login cookies or browser certificate exceptions.
Certificate verification is never disabled. Redirects are rejected: enter the final URL.

HTTP is visibly labeled insecure for every console. Non-local HTTP requires an explicit
risk acknowledgment. Traffic can be read or changed on the network. ATS uses
`NSAllowsArbitraryLoads` to allow arbitrary user-entered HTTP hostnames; narrower global
ATS keys must not be added alongside it. **This policy also applies to future WKWebView
content**; embedded web apps must be hardened separately before shipping.

The app probes only on Connect/Retry, not when a URL is typed or a saved profile is loaded.
Local Network permission must be checked on a real device. A generic connection error
does not prove permission denial; check Settings, server reachability and the address.
HTTP 421 means the hostname may need `MONO_AGENT_WEB_ALLOWED_HOSTS` on the console host;
using its LAN or Tailscale IP address or Tailscale Serve URL is another option.

## Dashboard

A console with a saved identity opens on its dashboard (offline from the device cache until
**Connect**/**Retry** or pull to refresh). On iPad and other regular widths it is the sidebar
of a split view and conversations open in the detail column; on iPhone and compact widths it
is the root of a stack and conversations are pushed. Selection survives rotation, resizing
and backgrounding, and is restored per console after the system discards the scene.

- **Agents**: pinned agents first, presence, running (bolt) or unread counts, offline agents
  folded behind "N offline".
- **Running**: the fleet grouped by agent (two cards each, then "+N more"); without a fresh
  live listing the section says *last known* and rows show an unconfirmed marker.
- **Projects** (collapsible; the project page is a placeholder), **Recent** for the selected
  agent with unread, running, tags and project chips, and **Load older conversations**.
- **Search** (two or more characters, debounced) replaces the sections with highlighted hits.
- **Archived** and the **data mode** (Auto/Lean/Full) are in the bottom toolbar; the
  **Consoles** button opens saved-console management; **New conversation** opens the
  composer placeholder. Offline, refresh, storage and insecure-HTTP banners stay visible.

Opening a conversation shows its ordered transcript, current route, reasoning disclosures,
clustered tool calls and run attribution. Full tool bodies load only on request. Markdown
supports GFM tables/task lists, selectable code with Copy and external links; HTML is literal
text. Oversized/complex input shows an explicitly bounded preview. Scrolling follows live
writes only while already at the bottom; otherwise use **Jump to latest**. Older history loads
at the top, preserving a message anchor. Cached truncation and stale history are labelled.
It is marked read only while that destination is on screen in an active scene.
Archive, pin, tag and project edits are not available yet.

## Saved consoles and local data

Add, select, edit, remove and retry several saved consoles. Profiles are atomic versioned
JSON under the app's Application Support directory, excluded from backup and protected
until first unlock on iOS. Only endpoint, label, last identity, selection and HTTP
acknowledgment are retained in the profile record. The separate
[Store repository](Packages/MonoAgentStore/README.md) retains bounded sanitized transcripts,
text drafts/read markers and submission recovery references; capability URLs and credentials
are stripped.
Network sessions use no shared disk cache or cookie storage. Relaunch does not show a
previously connected console as online without a fresh probe.

Changing an endpoint creates a new UUID namespace and clears prior connection identity.
Profiles are never merged by the server's advertised hostname (not a durable server ID).
Remove a console to delete its profile and retained local data. Delete the app to remove
**all** local data; reinstall starts empty. Cache pruning never evicts drafts or unresolved
submission references. Persistence failures are exposed by the Store, not hidden as success.

Only **one window** is supported. Multiple scenes need a separate selected-thread stream
and state design. No offline send queue, auth UI or embedded web content
is implemented in this foundation. Kit supplies typed API/SSE/upload primitives; the
Store supplies ordered transcript projections, live sync, unread, drafts and GET-only
submission recovery for later feature screens. Cached running turns require fresh summary
confirmation. Selecting a saved profile hydrates offline without probing.

## Tests and synthetic screenshots

See [AGENTS.md](AGENTS.md) for exact commands and module boundaries. Ordinary tests never
contact a live console. Debug scenarios use isolated fresh storage and scripted responses;
script exhaustion fails closed. Launch with `--scenario connection-empty`,
`connection-failed`, or `console-online`, optionally `--appearance light|dark` and
`--reset-test-data`. The DEBUG design catalog opens with `--scenario design-catalog`,
`design-catalog-evergreen|ocean|plum|terracotta`, `design-catalog-accessibility` or
`design-catalog-reduce-transparency`. It always uses isolated empty fixture storage.
Unknown scenarios fail explicitly. Reset without a scenario selects
an isolated empty fixture, never deletes real saved consoles. DEBUG Store preparation
scenarios are `store-offline`, `store-streaming`, `store-unread`, `store-uncertain`.
Dashboard scenarios use synthetic agents and conversations at a fixed reference time:
`dashboard-populated`, `dashboard-empty`, `dashboard-offline`, `dashboard-search` and
`conversation-placeholder` (legacy alias for the transcript), `conversation-transcript`,
`conversation-streaming`, `conversation-tools`, `conversation-long` (500 loaded messages plus
40 older rows and large collapsed outputs), `conversation-markdown`; `--fixture-theme ocean|plum|terracotta` changes the synthetic
console theme. Release ignores these flags.

```sh
swift test --package-path Packages/MonoAgentKit
swift test --package-path Packages/MonoAgentStore
xcrun swift format lint --strict --recursive App AppTests AppUITests Packages
./Tools/check-repository
./Tools/screenshots
```

The screenshot command picks the newest installed iOS runtime with both families,
skipping iPhone-only runtimes. It prefers iPhone 18 Pro Max, then iPhone 17 Pro Max, and
iPad Pro 13-inch (M5); if those names are absent, it logs a fallback to the first
available device in that family. CI uses the same selector. Or pass `--iphone "$IPHONE_UDID" --ipad "$IPAD_UDID"`.
It runs the shared app test plan (app/Design Swift Testing and XCUI scenarios),
waits for readiness identifiers and a non-blank rendered frame, and exports the labeled
synthetic PNGs listed in `Tools/screenshot-matrix.json` for each device. That is 43 per
device (86 in total):

- the 12 connection screens (three states × two appearances × two devices; a connected
  console now shows its dashboard);
- the failed connection at Accessibility XL text;
- the design catalog per theme in light and dark;
- the catalog at Accessibility XL text;
- the catalog with the Reduce Transparency fallback;
- the five dashboard scenarios in light and dark, the populated dashboard in the plum
  theme (dark) and at Accessibility XL text;
- five transcript scenarios in light/dark, plus Markdown in plum and at Accessibility XL.

`Artifacts/Screenshots/index.html` and `index.json` name the device, runtime, scenario,
appearance, theme, text size and transparency. Both image dimensions are ≤ 2000 px.
Results are retained as xcresult bundles. Every device runs even if an earlier one fails;
the command then exits non-zero. Failures skip slow diagnostics collection. Move/remove old `Artifacts` before rerunning.
Time in the status bar, locale, scenario data and animations are controlled; no real
console networking is available to a fixture scenario.

CI runs iPhone and iPad tests as parallel matrix jobs, then merges their screenshot
indexes and PNGs into one artifact. `Tools/screenshots` still runs both locally;
`--family iPhone|iPad` selects one CI leg. CI builds both Debug and Release and checks the Release executable with `nm` and `strings`
for fixture symbols/hostnames, design-catalog types/scenario names and preview helpers
(`./Tools/check-release-fixtures`). TestSupport declarations, the catalog and previews
are DEBUG-only, not merely inactive in production.

CI runs on `xcode-27`, selects the newest stable Xcode 27 (betas are excluded after resolving
symlinks; no stable 27.x fails), asserts Xcode and Swift, chooses installed
simulators dynamically, uploads screenshots and xcresults, and gates on **Required verdict**.
Hosted exact-head CI is the broad gate. Simulator/UI tests and screenshots require installed Xcode components/runtimes;
unsigned builds and host tests are independent checks. Real-device permission, network and Personal Team checks remain
separate from simulator evidence. UI-changing PRs must supply iPhone and iPad screenshots;
the later full-feature screenshot checkpoint remains after the composer feature.

`./Tools/check-contract --locked` verifies the source-pinned API v1 artifacts, route ledger
and golden coverage. See [Contracts](Contracts/README.md) and the
[Kit API inventory](Packages/MonoAgentKit/README.md). No npm release is required for this pin.

## Markdown dependency and notices

`RichTextDocumentView` is app-owned SwiftUI rendering over **swift-markdown 0.7.3**
(`7d9a5ce307528578dfa777d505496bd5f544ad94`, Apache-2.0 with Swift runtime exception).
The resolved runtime graph contains **swift-cmark 0.9.0**
(`08ddb528923cc1a6527e02b7a1aee9e516ca749a`, MIT with BSD-derived component notices).
There are no other resolved packages. Both licenses are GPL-3.0 compatible. Full upstream
licenses and NOTICE are retained in [ThirdPartyNotices](App/Resources/ThirdPartyNotices.txt),
also bundled in the app. Package.resolved files lock both package and app graphs.

The parser is off-main; input is capped at 65,536 UTF-8 bytes, long lines and excessive
nesting/table widths fall back before parsing, and the value tree has node/depth/row limits.
No HTML, images, embedded scripts or arbitrary URL schemes execute. Code display is limited
to 16,384 UTF-8 bytes while Copy includes the entire supplied value. Deferred jobs/subagents,
files/images/MCP/restart and ask/reply controls remain explicitly labelled for later features.

Focused capture: `./Tools/screenshots --transcript-only` runs app/Design unit tests and the
12 transcript XCUI captures on both device families, without removing existing matrix entries.
The default screenshot command still captures the complete matrix (43 images per device).
