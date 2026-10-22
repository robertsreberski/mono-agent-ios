# Mono Agent for iPhone and iPad

A native SwiftUI client for the mono-agent web console. This foundation includes saved
console connections, adaptive navigation and a Liquid Glass design system
([MonoAgentDesign](Packages/MonoAgentDesign/README.md)). It does not include agent or
conversation features yet. The connected console's theme (evergreen, ocean, plum or
terracotta) styles the app; disconnected or unknown themes use evergreen.
GPL-3.0-only; see [LICENSE](LICENSE).

## Prerequisites and build

- Xcode 27.1 or newer Xcode 27 with Swift 6.4+, iOS/iPadOS 27 deployment target.
- Install Xcode first-launch components and an iOS 27+ simulator runtime to run UI tests.
- Open `MonoAgent.xcodeproj`, choose the shared **MonoAgent** scheme, then an iPhone or iPad.
  No package downloads or project generator are required.

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

## Saved consoles and local data

Add, select, edit, remove and retry several saved consoles. Profiles are atomic versioned
JSON under the app's Application Support directory, excluded from backup and protected
until first unlock on iOS. Only endpoint, label, last identity, selection and HTTP
acknowledgment are retained; no raw responses, capability URLs or credentials are cached.
Network sessions use no shared disk cache or cookie storage. Relaunch does not show a
previously connected console as online without a fresh probe.

Changing an endpoint creates a new UUID namespace and clears prior connection identity.
Profiles are never merged by the server's advertised hostname (not a durable server ID).
Remove a console to delete its profile data. Delete the app to remove **all** local data;
reinstall starts empty. Transcript/cache/draft persistence arrives in a later change.

Only **one window** is supported. Multiple scenes need a separate selected-thread stream
and state design. No offline send queue, SSE, auth UI, transcript or embedded web content
is implemented in this foundation.

## Tests and synthetic screenshots

See [AGENTS.md](AGENTS.md) for exact commands and module boundaries. Ordinary tests never
contact a live console. Debug scenarios use isolated fresh storage and scripted responses;
script exhaustion fails closed. Launch with `--scenario connection-empty`,
`connection-failed`, or `console-online`, optionally `--appearance light|dark` and
`--reset-test-data`. The DEBUG design catalog opens with `--scenario design-catalog`,
`design-catalog-evergreen|ocean|plum|terracotta`, `design-catalog-accessibility` or
`design-catalog-reduce-transparency`. It always uses isolated empty fixture storage.
Unknown scenarios fail explicitly. Reset without a scenario selects
an isolated empty fixture, never deletes real saved consoles. Release ignores these flags.

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
synthetic PNGs listed in `Tools/screenshot-matrix.json` for each device. That is 19 per
device (38 in total):

- the 12 connection screens (three states × two appearances × two devices);
- the failed connection at Accessibility XL text;
- the design catalog per theme in light and dark;
- the catalog at Accessibility XL text;
- the catalog with the Reduce Transparency fallback.

`Artifacts/Screenshots/index.html` and `index.json` name the device, runtime, scenario,
appearance, theme, text size and transparency. Both image dimensions are ≤ 2000 px.
Results are retained as xcresult bundles. Move/remove old `Artifacts` before rerunning.
Time in the status bar, locale, scenario data and animations are controlled; no real
console networking is available to a fixture scenario.

CI builds both Debug and Release and checks the Release executable with `nm` and `strings`
for fixture symbols/hostnames, design-catalog types/scenario names and preview helpers
(`./Tools/check-release-fixtures`). TestSupport declarations, the catalog and previews
are DEBUG-only, not merely inactive in production.

CI runs on `xcode-27`, explicitly selects/asserts Xcode and Swift, chooses installed
simulators dynamically, uploads screenshots and xcresults, and gates on **Required verdict**.
Hosted exact-head CI is the broad gate. Simulator/UI tests and screenshots cannot run
locally until Xcode components/runtimes are installed; unsigned builds and host tests
are independent checks. Real-device permission, network and Personal Team checks remain
separate from simulator evidence. UI-changing PRs must supply iPhone and iPad screenshots;
the later full-feature screenshot checkpoint remains after the composer feature.

C2 uses provisional connection DTOs. `./Tools/check-contract --locked` honestly reports
blocked until the contract-client change imports published goldens; see [Contracts](Contracts/README.md).
