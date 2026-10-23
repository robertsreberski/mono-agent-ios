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

## Known network-isolation gap

**WebRTC is not blocked by this core.** On iOS 27.0 with Xcode 27.1, real WKWebViews send
STUN UDP and TURN TCP to loopback sinks despite canonical CSP and content rules. The
public WebKit SDK exposes no supported disable-WebRTC preference. The isolation suite
records the unmet zero-network assertion as an explicit **known issue**, while separately
asserting that its escape probes really reach both sinks. Do not interpret a green test
command with that known issue as complete network isolation. This core must not be
advertised as a general network firewall or wired to UI without considering that risk.

Ordinary fetch/XHR/WebSocket/beacon/resource/form and numeric-loopback prefetch/preconnect/
DNS-prefetch probes record zero inbound connections with the full policy stack. This does
not prove that DNS-name prefetch cannot leak, or attribute each result to content rules
rather than CSP/WebKit. Tests use TCP/UDP positive controls and no live console.

Public WKWebView APIs also provide no hard per-host CPU or memory quota. The bridge's
method allowlist, effects, consent, request/rate limits and lifecycle presentation are not
implemented here.
