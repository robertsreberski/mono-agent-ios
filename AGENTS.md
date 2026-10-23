# Repository engineering contract

## Scope and ownership

- `App/Composition`: dependency construction and single-scene lifecycle. `App/Connection`:
  saved-console UI. `App/Navigation`: ID-based compact stack / regular split-view routes.
  `App/Dashboard`: the console dashboard and conversation destination. Views read only from
  `ConsoleStore` and call its commands; pure decisions live in `DashboardModel`/`DashboardRows`
  with unit tests. `markVisible` follows `TranscriptVisibility` (on screen, active, selected).
- `Packages/MonoAgentKit`: complete typed API v1 client, SSE, deltas, uploads and capability
  access. Extend ConsoleAPI/RequestBuilder; do not add a second bootstrap/URL client.
- `Packages/MonoAgentKit/Sources/MonoAgentTestSupport`: fictional per-instance scripts and
  stable scenario catalog. TestSupport declarations are DEBUG-only; Release must contain no
  fixture symbols or strings (verified with nm and strings).
- `Packages/MonoAgentStore`: MainActor observable connection registry; actor-backed profile
  repository. Future persistence/recovery belongs here, not in views.
- `Packages/MonoAgentDesign`: iOS-only value-driven tokens/components; no Kit/Store/network.
  Screens use its tokens, `.consoleTheme`, and components. Follow the glass rules in its
  README: system bars first, custom glass only for floating controls, never on content,
  and opaque fallbacks for Reduce Transparency. Contrast changes need test updates.
- `App/Catalog`: DEBUG-only previews and the design catalog (`design-catalog…` scenarios).
  Release must not contain catalog code. Do not name DEBUG-only files after the release
  fixture markers, because `nm -a` lists source file names.
- App → Kit, Store, Design. Store → Kit. Tests/DEBUG composition → TestSupport → Kit.
  No inverse dependencies or project generators. The sole approved direct third-party dependency
  is Design’s exact-pinned swift-markdown renderer (and its locked swift-cmark transitive); see
  README and bundled ThirdPartyNotices. Do not add other packages.
- `.xcodeproj` uses synchronized source folders; add sources there without pbxproj edits.
  Keep build policy in xcconfig, signing overrides only in ignored `Config/Local.xcconfig`.

## Concurrency and safety

Swift 6 language mode, complete strict concurrency. MainActor + Observation owns UI
state; actors own I/O; cross-isolation values are Sendable. No Combine, global mutable
mock registry, unchecked Sendable or unsafe isolation escape hatch. Async results carry
profile/generation identity so removed/edited consoles cannot be resurrected. Never
probe during typing or on loading real profiles. Ordinary tests must not access a live
console, even for read-only health requests. Inject per-instance transport and storage.
Do not disable TLS checks, persist raw capability URLs, use shared response caches, forge
Host, or follow redirects/downgrades. See package README seam notes before extending them.

This is a **public GPL-3.0-only repository**. Use SPDX headers in Swift sources. Never
commit private names, dates, addresses, hostnames, financial/health/schedule data,
conversation/memory content, absolute local home paths, credentials or signing identities.
Use fictional fixtures (Flockbox, console.example.ts.net). Review generated artifacts too;
the hygiene script is only a backstop. Do not contact a console for screenshots.

Tooling tests must never assume `.build` or any other ignored directory exists.
Create required sandbox parents explicitly and test tooling from a fresh checkout.

## Exact verification commands

Run from the repository root with Xcode 27 / Swift 6.4 selected:

```sh
xcodebuild -version
xcrun swift --version
xcrun swift format lint --strict --recursive App AppTests AppUITests Packages
./Tools/check-repository
python3 -m unittest discover -s Tools/tests
./Tools/check-contract --locked
swift test --package-path Packages/MonoAgentKit
swift test --package-path Packages/MonoAgentStore
xcodebuild -project MonoAgent.xcodeproj -scheme MonoAgent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MonoAgent.xcodeproj -scheme MonoAgent -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build
./Tools/check-release-fixtures
```

Apply formatting with `xcrun swift format format --in-place --recursive App AppTests AppUITests Packages`.
Kit/Store declare macOS 14 minimum for host tests; Design is iOS-only.
The locked contract is source-pinned in `Contracts/console-api.lock.json`. Imported goldens
belong only to the Kit test target. Intentional updates use `Tools/update-contract` and
`Tools/generate-routes`; see the Kit README. No Last-Event-ID or automatic mutation retries.

With simulator components and a runtime installed:

```sh
./Tools/select-simulators
xcodebuild -project MonoAgent.xcodeproj -scheme MonoAgent \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath .build/Xcode -resultBundlePath Artifacts/Tests.xcresult \
  CODE_SIGNING_ALLOWED=NO test
./Tools/screenshots --iphone "$IPHONE_UDID" --ipad "$IPAD_UDID"
# Or dynamic device/runtime selection:
./Tools/screenshots
```

The shared test plan covers app unit tests and XCUI scenarios. Design package test sources are synchronized into the app unit-test bundle so they execute on iOS too. Host Kit/Store
tests are separate. Never hard-code a simulator runtime patch version. Use the newest runtime with both families,
skipping iPhone-only runtimes. Prefer iPhone 18 Pro Max, then iPhone 17 Pro Max, and
iPad Pro 13-inch (M5); log any fallback to first-available selection. CI uses the same tool. Every UI PR needs
representative iPhone + iPad screenshots, including light/dark, captured via XCUI synthetic
scenarios, not live data. PNG dimensions must both be ≤ 2000 px, with a device/runtime/
scenario/appearance index and a synthetic fixture label. Wait for accessibility readiness,
not sleeps; reject blank startup frames with the rendered-content guard. Maintain Dynamic Type, VoiceOver labels and non-color status cues.

Use focused local gates and hosted exact-head **Required verdict** for broad simulator/UI
proof. Report commands actually run, failures and honest **not run / blocked** limits.
A build is not a simulator test or user acceptance. Real-device Local Network permission
and Personal Team installation require distinct evidence.

## Commits and delivery

Use focused conventional commits (`feat:`, `fix:`, `test:`, `ci:`, `docs:`). PRs summarize
scope, acceptance evidence, contract/dependency changes and screenshot artifacts; keep
private task bookkeeping out of the public repository. Do not invent approval to push,
merge, release, deploy or contact a live console. No CHANGELOG is maintained yet.
