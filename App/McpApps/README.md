# MCP app isolation core

This core is not connected to the transcript. It delivers bounded transport envelopes,
not JSON-RPC method semantics or native effects. The transcript placeholder remains.

Each host owns a nonpersistent website data store, content controller, fixed custom-scheme
shell, and scripts-only sandboxed srcdoc. The shell's response-header envelope CSP and
the inner document's canonical meta CSP apply together. No console URL, headers,
capability, or credential enters WebKit. HTTP/HTTPS content rules are compiled before load.
Only the initial shell/srcdoc navigation is allowed. A rejected navigation or second iframe
load retires the session. File attempts rejected internally by WebKit before any load leave
the original document/session intact; tests verify its per-document marker. Native file
requests reaching navigation policy are rejected. All future loads still retire.

The isolated-world listener requires a trusted MessageEvent from the current inner window,
an opaque origin, and the current nonce/generation. Swift independently checks the main
WKFrameInfo, shell URL/origin, session identity and serialized envelope byte cap. HTML's
2 MiB cap counts secured UTF-8 bytes, not JSON-escaped transport bytes. The bridge cap is
1 MiB + 64 KiB including its native transport envelope. Host owners must call `close()`
when disposing a host. Fresh hosts never reuse a session identity.

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

Ordinary fetch/XHR/WebSocket/beacon/resource/form and numeric-loopback prefetch/preconnect/
DNS-prefetch probes also record zero inbound connections with the full policy stack. Tests
use TCP/UDP positive controls and no live console. These bounded runtime tests do not prove
DNS-name privacy, eliminate unknown JavaScript-realm bypasses, or attribute every result to
CSP versus content rules versus navigation policy. Keep the sandbox and navigation gate;
do not rely on global removal alone or advertise a general network firewall.

Public WKWebView APIs also provide no hard per-host CPU or memory quota. The bridge's
method allowlist, effects, consent, request/rate limits and lifecycle presentation are not
implemented here.
