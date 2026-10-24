# MCP app isolation core

This core is not connected to the transcript. The isolation layer delivers bounded raw
JSON-RPC envelopes; the native bridge above it owns method semantics and consent-gated
effects through Store. The transcript placeholder remains.

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
and exactly one frame load before delivery. Trusted current-inner/null-origin messages that
arrive before that load are snapshotted in order, bounded to 16 messages and a total serialized
transport budget of 1 MiB + 64 KiB. Overflow messages are dropped; a second load or retirement
clears the buffer. Native semantics still receive nothing before the verified first load.
The listener privately wraps each payload with nonce/generation; neither
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

Public WKWebView APIs provide no hard per-host CPU or memory quota. The bridge below
bounds requests and effects; native presentation and transcript lifecycle ownership remain
separate PR2 work.

## Native protocol / effect layer (no transcript integration yet)

`McpAppBridge.make(store:session:consent:opener:environment:)` consumes a loaded,
connected Store session. `McpStoreGateway` is the sole production forwarding adapter:
App → ConsoleStore → CapabilityService → ConsoleAPI. No App API client, credentials or
capability URL enter WK. PR2 owns native consent presentation, visibility and the live-host
cap; it must call `teardown()` (or immediate `close()`) when abandoning a bridge.
PR2 implements the `McpConsentPresenting` protocol; no concrete presentation UI exists here.
Each `confirm(_:requestID:)` / `cancel(requestID:)` pair is scoped by a fresh UUID so a shared
presenter cannot cancel a different bridge's prompt. Cancellation must settle only that request.

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
  theme, inline/available modes, dimensions (width 240–1400, height 160–1600), locale/timeZone,
  BCP 47 locale (as with navigator.language), native userAgent, mobile platform and injected touch/hover capabilities. Environment/height
  changes send context notifications without rebuilding the host. Size bursts coalesce 16 ms.
- Only resources/read, tools/call, ui/open-link and ui/update-model-context forward. Native
  alone supplies confirmed; app-supplied confirmed is discarded. One consent at a time;
  others auto-decline. Tool preview ports web secret-key redaction, depth 4, 12 array items,
  16 fields, 240-unit strings, 120-unit keys and 2048 UTF-8 bytes. Native sorts preview keys
  for deterministic output and does not split UTF-8 scalars at the byte ceiling.
- Open-link requires confirmation, server allowed===true and opens the **returned** HTTP(S)
  URL in the system default browser, through an injected opener. A changed destination is
  not refused. Native rejects file/custom schemes and URL credentials rather than handing
  native app/file privileges to an HTML app. A refused open returns isError:true.
- Model context succeeds only on accepted===true; refusal exposes a control-cleaned reason
  bounded to 500 UTF-16 units, like the web's bounded text. Tool/resource result structure is
  checked before delivery. Initial tool-result fallback deliberately matches the web's
  content-array test, including its fixed error result; tool-input requires an object.
- App `ui/notifications/request-teardown` closes and requires Reopen. Host teardown sends
  `ui/resource-teardown` and closes on reply/error or 500 ms timeout. Retirement, Store session
  invalidation and close synchronously cancel native consent, pending effects and size work;
  late approval/results cannot deliver or open a URL. No automatic reopen or crash loop.

Intentional native divergences from the web: local-only isolated shell/opaque relay and
WebRTC defence described above; no clipboard-write; complete handshake before forwarding
an effect; safe finite integer IDs / ≤256-byte string IDs and depth ≤32; at most 4 in-flight
requests (extra requests get an error), a **sliding** 256-ID duplicate window (duplicate closes,
no lifetime 1024-ID quota), token bucket 20 messages/s with burst 40 (excess closes with Reopen).
Message ceiling remains 1 MiB + 64 KiB. Transport-invalid batches/oversize envelopes are discarded
by the isolation layer, not forwarded. Resource reads renew once; effects never replay.
On expiry, `renewAccessForRetry()` is an explicit native action that only refreshes access:
the app must issue a new request and obtain fresh native consent. The old operation is not
retained for replay. Unlike web fetch retry, native cannot silently repeat a confirmed effect.

`AppTests/Resources/mcp-protocol-vectors.json` contains minimal schema/default-handler
vectors from integrity-verified ext-apps 1.7.5, with the full original transition LICENSE
beside it. Both are test-bundle-only; no SDK code/dependency is installed. DEBUG-only
`McpGardenFixture` supplies an inline synthetic planner for real-WK semantic tests, not a
transcript/catalog route. Release checks reject its symbols/strings and test resources.
The tests inject consent and URL opening; they are not physical gesture, UIKit dialog or
actual external-browser launch proof. Those UI integrations remain PR2 work.


Protocol errors follow ext-apps' delegated SDK Protocol: unknown method **-32601**, invalid
parameters **-32602**, and a plain handler failure or declined tool/context request **-32603**.
The web throws plain Error for those declines; open-link decline instead returns isError:true.
Native messages remain bounded/safe rather than exposing transport/server error prose.
The native-only handshake/in-flight policy errors deliberately use **-32000**; rate/duplicate
violations close instead of replying. Access revision changes suppress only stale capability
adoption, never a completed same-session result or a confirmed effect's response.
All operations have independent UUID ownership, including repeated initialized notifications
and a slid-out request ID reused while earlier consent is pending. Teardown cancels every
operation, and only its own resource-teardown request may send while tearing down.


Early-message tests use real WK opaque-frame messages, including a synchronous script-start
SDK-style initialize. A DEBUG-only initial-load gate deterministically exercises pre-delivery
buffering, forged source/origin/isTrusted events and stale native identities, count/total-byte
caps, ordered flush and retirement/second-load discard. It does not alter the Release path.
The gate is completed only after the real initial iframe load; production always processes
that load immediately. Native send-attempt auditing and task completion counters make late
consent/result tests independent of a closed bridge's incoming debug observer. Integration
coverage also runs through the real Store gateway/APIClient and a per-instance scripted
HTTPTransport, never a console: Cancel 0 / Allow 1 POST, overlapping expiry reads, and a completed
confirmed tool overlapped by read renewal with exactly one tool POST and one native reply.


## Transcript presentation and lifetime

McpAppPartView now replaces the placeholder. A transcript-owned McpHostPool admits at most
two loading/live hosts, oldest offscreen first (then oldest visible when all slots are visible).
Visibility is measured on each part, not its message. Full mode opens only at the first
viewport arrival; Lean requires Show. Arrival metadata survives lazy row recreation and is
pruned with the held message list. Hide/offscreen/background/selection/identity change destroys
the document; Show/Reopen refetches, with no retained HTML cache. Memory warning, process
termination and a15s load/initialize deadline offer Reopen without automatic restart.
The loaded resource must also match the visible publication's core binding, so a delayed
UI projection cannot mount a different invocation under an old header.

Native McpNativeConsent implements token-scoped McpConsentPresenting with a system modal
sheet, redacted bounded preview, Cancel/Allow once and restored accessibility focus. The
transcript below the sheet is hit-test/AX-hidden, and the system sheet isolates the rest of
the scene. Parent message quote menus are removed from MCP-bearing rows; quoting stays on
the native message action strip, not over WK controls. Card typography uses shared reply
WebType roles,44pt actions, opaque WebColor surfaces and full accessible names. WK pageZoom
follows Dynamic Type; theme/BCP47 locale/width updates do not recreate the bridge. Requested
height keeps the160–1600 clamp and phones cap at70% of the measured transcript viewport.
Existing transcript measured-height/follow policy remains the scroll owner.

DEBUG conversation-mcp-app/unavailable/long-title scenarios use the Store/APIClient path
with a per-instance scripted transport and the synthetic garden document. Native test POST
counters are transport-derived, not app-supplied diagnostics. Release excludes those types,
scenario names and content. Automated UI/screenshot evidence is added separately.
