# MCP app isolation core

This core is not connected to the transcript. It delivers bounded transport envelopes,
not JSON-RPC method semantics or native effects. The transcript placeholder remains.

Each host owns a nonpersistent website data store, content controller, fixed custom-scheme
shell, and scripts-only sandboxed srcdoc. The shell's response-header envelope CSP and
the inner document's canonical meta CSP apply together. No console URL, headers,
capability, or credential enters WebKit. A deny-by-default content rule list allows only mono-mcp-host:, about:, data: and blob:
documents/resources; all other URL loads, including HTTP(S) and WS(S), are blocked. The rules
are compiled before load.
Only the initial shell/srcdoc navigation is allowed. A rejected navigation or second iframe
load retires the session. File attempts rejected internally by WebKit before any load leave
the original document/session intact; tests verify its per-document marker. Native file
requests reaching navigation policy are rejected. All future loads still retire.

The app posts raw JSON-RPC to window.parent, just like the web SDK. The isolated-world
listener requires a trusted MessageEvent from the current inner window, an opaque origin
and exactly one frame load. It privately wraps the payload with nonce/generation; neither
secret leaves that world. Native replies/notifications relay raw JSON-RPC back to the opaque
inner window with targetOrigin "*". Swift independently checks the main
WKFrameInfo, shell URL/origin, session identity and serialized envelope byte cap. HTML's
2 MiB cap counts secured UTF-8 bytes, not JSON-escaped transport bytes. The bridge cap is
1 MiB + 64 KiB including its native transport envelope. Native serialization does not escape slashes, matching JSON.stringify byte accounting.
Owners should call `close()` for prompt disposal; isolated deinit also retires the document
and removes handlers/scripts. A strong webView-owned policy survives a released host and
defaults to cancel/deny, even when the view is retained elsewhere. Fresh hosts never reuse
a session identity. Link previews, context menus and link/image drag interactions are denied.

## WebRTC mitigation and residual limits

The web console's canonical CSP has no WebRTC restriction. The same baseline policy on
iOS 27.0 with Xcode 27.1 permits STUN UDP and TURN TCP despite HTTP/HTTPS content rules.
No supported disable-WebRTC preference exists in the public WebKit SDK. Adding the
native-only `webrtc 'block'` directive to both CSPs produces no observed violation or
reduction in that traffic on this runtime; it remains defense in depth for future engines.

The native host additionally installs a **page-world, all-frame, document-start** script
that replaces WebRTC constructor globals with nonwritable, nonconfigurable undefined
properties (including the prefixed peer-connection constructor and RTP/data-channel types).
It does not touch the isolated world or the bridge. This is JavaScript defense in depth,
not an engine-level network firewall.

The real-WebKit suite records zero connections/datagrams at both loopback sinks for direct
construction, caching in the first app script, prototype/descriptor recovery and attempts
to restore constructors. App-created about:blank frames cannot expose a constructor to
the app: sandbox-origin access is denied immediately, native policy rejects their load,
and the host retires. After-load access and document.write attempts also yield zero hits.
Because these new frames cannot load, this does not establish injection timing in an
otherwise permitted nested realm. All tested WebRTC variants are normal zero-hit assertions;
the historical known issue is not suppressed as an expected failure anymore.

Ordinary fetch/XHR/WebSocket/EventSource/beacon/resource and numeric-loopback prefetch/preconnect/
DNS-prefetch probes also record zero inbound connections without retiring the host. Form
submission is sandbox-blocked (no allow-forms); WebTransport is tested when present. CSS
@import and SVG images are covered. Separate anchor-ping and HTTP meta-refresh attempts
are stopped by retirement/navigation policy, not credited to resource blocking alone. Tests
use native TCP/UDP positive controls and a real WebKit-originated isolated-world STUN/TURN
control that must reach both sinks. An outer-shell WebSocket test (no restrictive connect-src)
proves the content rules block sockets independently; removing only the rules permits the
same WebKit socket to reach the sinks. There is no live console. These bounded runtime tests do not prove
DNS-name privacy, eliminate unknown JavaScript-realm bypasses, or attribute every result to
CSP versus content rules versus navigation policy. Keep the sandbox and navigation gate;
do not rely on global removal alone or advertise a general network firewall.

Public WKWebView APIs also provide no hard per-host CPU or memory quota. The bridge's
method allowlist, effects, consent, request/rate limits and lifecycle presentation are not
implemented here.

## Native protocol / effect layer (no transcript integration yet)

`McpAppBridge.make(store:session:consent:opener:environment:)` consumes a loaded,
connected Store session. `McpStoreGateway` is the sole production forwarding adapter:
App → ConsoleStore → CapabilityService → ConsoleAPI. No App API client, credentials or
capability URL enter WK. PR2 owns native consent presentation, visibility and the live-host
cap; it must call `teardown()` (or immediate `close()`) when abandoning a bridge.
The injected presenter must settle pending confirmation when `cancel()` is called.

- Raw JSON-RPC supports initialize, initialized, size, app/host teardown; host tool-input,
  tool-result and host-context notifications; ping (`{}`); and the SDK default display-mode
  request (returns current `inline`, even when fullscreen/pip was requested).
- Initialize requires appInfo(name/version), appCapabilities and protocolVersion. The shipped
  web negotiates 2026-01-26 / 2025-11-21; unknown revisions fall back to latest. The pinned
  SDK's own supported list is latest-only: **web behaviour wins** for the legacy revision.
  Repeated initialization with a new ID responds normally, as the SDK/web do.
- Host capabilities exactly match the web's fixed openLinks/serverTools/serverResources,
  sandbox.csp and updateModelContext text/resource/resourceLink/structuredContent set.
  No clipboard-write, camera, microphone or other permissions are advertised. Context has
  theme, inline/available modes, dimensions (width240–1400, height160–1600), locale/timeZone,
  native userAgent, mobile platform and injected touch/hover capabilities. Environment/height
  changes send context notifications without rebuilding the host. Size bursts coalesce16ms.
- Only resources/read, tools/call, ui/open-link and ui/update-model-context forward. Native
  alone supplies confirmed; app-supplied confirmed is discarded. One consent at a time;
  others auto-decline. Tool preview ports web secret-key redaction, depth4, 12 array items,
  16 fields, 240-unit strings, 120-unit keys and2048 UTF-8 bytes. Native sorts preview keys
  for deterministic output and does not split UTF-8 scalars at the byte ceiling.
- Open-link requires confirmation, server allowed===true and opens the **returned** HTTP(S)
  URL in the system default browser, through an injected opener. A changed destination is
  not refused. Native rejects file/custom schemes and URL credentials rather than handing
  native app/file privileges to an HTML app. A refused open returns isError:true.
- Model context succeeds only on accepted===true; refusal exposes a control-cleaned reason
  bounded to500 UTF-16 units, like the web's bounded text. Tool/resource result structure is
  checked before delivery. Initial tool-result fallback deliberately matches the web's
  content-array test, including its fixed error result; tool-input requires an object.
- App `ui/notifications/request-teardown` closes and requires Reopen. Host teardown sends
  `ui/resource-teardown` and closes on reply/error or500ms timeout. Retirement, Store session
  invalidation and close synchronously cancel native consent, pending effects and size work;
  late approval/results cannot deliver or open a URL. No automatic reopen or crash loop.

Intentional native divergences from the web: local-only isolated shell/opaque relay and
WebRTC defence described above; no clipboard-write; complete handshake before forwarding
an effect; safe finite integer IDs / ≤256-byte string IDs and depth≤32; at most4 in-flight
requests (extra requests get an error), a **sliding**256-ID duplicate window (duplicate closes,
no lifetime1024-ID quota), token bucket20 messages/s with burst40 (excess closes with Reopen).
Message ceiling remains1MiB+64KiB. Transport-invalid batches/oversize envelopes are discarded
by the isolation layer, not forwarded. Resource reads renew once; effects never replay.
On expiry, `renewAccessForRetry()` is an explicit native action that only refreshes access:
the app must issue a new request and obtain fresh native consent. The old operation is not
retained for replay. Unlike web fetch retry, native cannot silently repeat a confirmed effect.

`AppTests/Resources/mcp-protocol-vectors.json` contains minimal schema/default-handler
vectors from integrity-verified ext-apps1.7.5, with the full original transition LICENSE
beside it. Both are test-bundle-only; no SDK code/dependency is installed. DEBUG-only
`McpGardenFixture` supplies an inline synthetic planner for real-WK semantic tests, not a
transcript/catalog route. Release checks reject its symbols/strings and test resources.
The tests inject consent and URL opening; they are not physical gesture, UIKit dialog or
actual external-browser launch proof. Those UI integrations remain PR2 work.
