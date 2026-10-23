// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import Testing
import UIKit
import WebKit

@testable import MonoAgent

@MainActor
private final class McpEnvelopeRecorder: McpAppEnvelopeDelegate {
  var deliveries: [[String: Any]] = []
  func mcpAppHost(_ host: McpAppHost, didReceiveEnvelope envelope: Data) {
    if let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any] {
      deliveries.append(object)
    }
  }
}

@Suite("MCP WebKit isolation", .serialized)
@MainActor
struct McpAppIsolationTests {
  private static let sessionScript = """
    let session;
    const documentMarker = Math.random().toString(36) + Math.random().toString(36);
    const deliver = payload => parent.postMessage({...session, payload}, "*");
    addEventListener("message", event => {
      if (event.source !== parent || event.data?.type !== "mono:mcp-session") return;
      session = event.data;
      deliver({marker: "ready", documentMarker, sessionNonce: session.nonce, sessionGeneration: session.generation});
    });
    """

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(condition())
  }

  private func attach(_ host: McpAppHost) {
    host.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    scene?.windows.first?.addSubview(host.webView)
  }

  @Test func customSchemeHeaderCspIsEnforced() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { !recorder.deliveries.isEmpty || host.isRetired }
    let observed = try await host.webView.callAsyncJavaScript(
      """
      return await new Promise(resolve => {
        document.addEventListener("securitypolicyviolation", event => {
          if (event.isTrusted && event.effectiveDirective === "object-src") resolve(event.originalPolicy);
        }, {once: true});
        const object = document.createElement("object");
        object.data = "data:text/html,header-probe";
        document.body.append(object);
        setTimeout(() => resolve("NO_HEADER_CSP_VIOLATION"), 1000);
      });
      """, arguments: [:], in: nil, contentWorld: .page)
    print("MCP header CSP observation: \(observed ?? "nil")")
    #expect(observed as? String == McpAppShellSchemeHandler.contentSecurityPolicy)
  }

  @Test func initialSrcdocAndIsolatedBridge() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { !recorder.deliveries.isEmpty || host.isRetired }
    print(
      "MCP actions: \(host.navigationDecisions); responses: \(host.responseDecisions); retired: \(host.retirementReason ?? "none")"
    )
    #expect(!host.isRetired)
    #expect(host.innerLoaded)
    #expect(recorder.deliveries.count == 1)
    #expect(recorder.deliveries.first?["marker"] as? String == "ready")
  }

  private func appHtml(probe: String) -> String {
    """
    <script>
    \(Self.sessionScript)
    addEventListener("message", event => {
      if (event.source === parent && event.data?.type === "probe") {
        \(probe)
      }
    });
    </script>
    """
  }

  private func probe(_ host: McpAppHost) async throws {
    _ = try await host.webView.evaluateJavaScript(
      "document.querySelector('iframe').contentWindow.postMessage({type:'probe'}, '*')")
  }

  private func sink() async throws -> McpLoopbackSink {
    let sink = try McpLoopbackSink()
    try await waitUntil { sink.ready }
    try sink.startUDP()
    try await waitUntil { sink.udpReady }
    return sink
  }

  @Test func networkCanariesRemainUntouched() async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let recorder = McpEnvelopeRecorder()
    let ports = [console.port, evil.port].map(String.init).joined(separator: ",")
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          for (const port of [\(ports)]) {
            const base = `http://127.0.0.1:${port}`;
            const attempt = fn => { try { fn(); } catch {} };
            attempt(() => fetch(base + '/fetch').catch(() => {}));
            attempt(() => { const x = new XMLHttpRequest(); x.open('GET', base + '/xhr'); x.send(); });
            attempt(() => new WebSocket(`ws://127.0.0.1:${port}/socket`));
            attempt(() => navigator.sendBeacon(base + '/beacon', 'canary'));
            attempt(() => { const img = new Image(); img.src = base + '/img'; document.body.append(img); });
            attempt(() => {
              const style = document.createElement('style');
              style.textContent = `body{background-image:url(${base}/css)}@font-face{font-family:canary;src:url(${base}/font)}p{font-family:canary}`;
              document.head.append(style); const p=document.createElement('p');p.textContent='font canary';document.body.append(p);
            });
            for (const tag of ['audio','video']) attempt(() => {
              const media = document.createElement(tag); media.src = base + '/' + tag;
              media.preload = 'auto'; document.body.append(media); media.load();
            });
            attempt(() => {
              const form = document.createElement('form'); form.action = base + '/form';
              document.body.append(form); form.submit();
            });
            for (const rel of ['prefetch','preconnect','dns-prefetch']) attempt(() => {
              const link = document.createElement('link'); link.rel = rel;
              link.href = base + '/' + rel; document.head.append(link);
            });

          }
          deliver({marker:'attempted-network'});
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil { recorder.deliveries.count == 2 }
    // A bounded observation window for asynchronous prefetch and ICE gathering, not a readiness sleep.
    try await Task.sleep(for: .seconds(4))
    print(
      "MCP sink counts console=\(console.inboundConnections)/\(console.requests)/\(console.datagrams) evil=\(evil.inboundConnections)/\(evil.requests)/\(evil.datagrams)"
    )
    #expect(console.inboundConnections == 0)
    #expect(console.requests == 0)
    #expect(console.datagrams == 0)
    #expect(evil.inboundConnections == 0)
    #expect(evil.requests == 0)
    #expect(evil.datagrams == 0)
    #expect(recorder.deliveries.last?["marker"] as? String == "attempted-network")
    // Positive controls prove the sinks were listening, independently of JS-reported failures.
    for sink in [console, evil] {
      let (_, response) = try await URLSession.shared.data(
        from: URL(string: sink.origin + "/control")!)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(sink.inboundConnections > 0)
      #expect(sink.requests == 1)
      #expect(sink.requestLines == ["GET /control HTTP/1.1"])
      try await sink.sendUDPControl()
      try await waitUntil { sink.datagrams == 1 }
    }
  }

  @Test(arguments: ["about:blank", "about:srcdoc", "data:", "blob:", "reload", "shell"])
  func innerNavigationRetires(_ destination: String) async throws {
    let command: String
    switch destination {
    case "data:": command = "location.href='data:text/html,<p>navigated</p>'"
    case "blob:":
      command =
        "location.href=URL.createObjectURL(new Blob(['<p>navigated</p>'],{type:'text/html'}))"
    case "reload": command = "location.reload()"
    case "shell": command = "location.href='mono-mcp-host://shell/'"
    default: command = "location.href='\(destination)'"
    }
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          deliver({marker:'navigation-attempted'});
          setTimeout(() => { \(command); }, 50);
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil { host.isRetired }
    print(
      "MCP navigation \(destination): actions=\(host.navigationDecisions), responses=\(host.responseDecisions), retired=\(host.retirementReason ?? "none")"
    )
    #expect(host.isRetired)
    #expect(host.webView.url == McpAppShellSchemeHandler.url)
    #expect(recorder.deliveries.count == 2)
  }

  @Test func topNavigationAndWindowOpenCannotEscape() async throws {
    let sink = try await sink()
    defer { sink.stop() }
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          try { top.location.href='\(sink.origin)/top'; } catch {}
          try { window.open('\(sink.origin)/window'); } catch {}
          deliver({marker:'top-attempted'});
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil { recorder.deliveries.count == 2 }
    try await Task.sleep(for: .milliseconds(500))
    #expect(host.webView.url == McpAppShellSchemeHandler.url)
    #expect(sink.inboundConnections == 0)
    #expect(sink.requests == 0)
  }

  @Test func srcdocInheritsEnvelopeHeaderCsp() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          document.addEventListener('securitypolicyviolation', event => {
            if (event.isTrusted && event.effectiveDirective === 'object-src') deliver({policy:event.originalPolicy});
          });
          const object = document.createElement('object'); object.data='data:text/html,inheritance-probe';
          document.body.append(object);
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil {
      recorder.deliveries.contains {
        $0["policy"] as? String == McpAppShellSchemeHandler.contentSecurityPolicy
      }
    }
    #expect(!host.isRetired)
  }

  @Test(arguments: ["location", "anchor", "meta"])
  func rejectedFileAttemptKeepsOriginalDocument(_ route: String) async throws {
    let sink = try await sink()
    defer { sink.stop() }
    let recorder = McpEnvelopeRecorder()
    let command: String
    switch route {
    case "anchor":
      command =
        "const a=document.createElement('a');a.href=file;a.target='_self';document.body.append(a);a.click();"
    case "meta":
      command =
        "const m=document.createElement('meta');m.httpEquiv='refresh';m.content='0;url='+file;document.head.append(m);"
    default: command = "location.href=file;"
    }
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          const file='file:///mcp-fictional-unreadable.html';
          \(command)
          setTimeout(() => deliver({marker:'same-document', documentMarker,
            sessionNonce:session.nonce, sessionGeneration:session.generation}), 300);
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    let original = try #require(recorder.deliveries.first)
    try await probe(host)
    try await waitUntil { recorder.deliveries.count == 2 || host.isRetired }
    print(
      "MCP file route \(route): actions=\(host.navigationDecisions), responses=\(host.responseDecisions), retired=\(host.retirementReason ?? "none")"
    )
    if host.isRetired {
      #expect(host.navigationDecisions.count > 2)
    } else {
      #expect(host.navigationDecisions == ["main:mono-mcp-host://shell/", "sub:about:srcdoc"])
      #expect(host.responseDecisions == ["main:mono-mcp-host://shell/"])
      let echo = try #require(recorder.deliveries.last)
      #expect(echo["marker"] as? String == "same-document")
      for key in ["documentMarker", "sessionNonce", "sessionGeneration"] {
        #expect(echo[key] as? String == original[key] as? String)
        #expect((echo[key] as? String)?.isEmpty == false)
      }
      #expect(
        Set(echo.keys) == Set(["marker", "documentMarker", "sessionNonce", "sessionGeneration"]))
      #expect(recorder.deliveries.count == 2)
    }
    #expect(sink.inboundConnections == 0)
    #expect(sink.requests == 0)
    #expect(host.webView.url == McpAppShellSchemeHandler.url)
  }

  @Test func nativeFileNavigationReachingPolicyIsRejected() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    host.webView.load(URLRequest(url: URL(fileURLWithPath: "/mcp-fictional-unreadable.html")))
    try await waitUntil { host.isRetired }
    print("MCP native file route: \(host.navigationDecisions)")
    #expect(host.navigationDecisions.contains("main:file:///mcp-fictional-unreadable.html"))
    #expect(host.retirementReason == "Navigation rejected")
    #expect(recorder.deliveries.count == 1)
  }

  @Test func webRtcHasDocumentedNetworkEscape() async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let recorder = McpEnvelopeRecorder()
    let ports = [console.port, evil.port].map(String.init).joined(separator: ",")
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          window.rtcCanaries=[];
          for (const port of [\(ports)]) {
            const rtc = new RTCPeerConnection({iceServers:[
              {urls:`stun:127.0.0.1:${port}`},
              {urls:`turn:127.0.0.1:${port}?transport=tcp`,username:'canary',credential:'fictional'}
            ]});
            window.rtcCanaries.push(rtc);
            rtc.createDataChannel('canary');
            rtc.createOffer().then(offer => rtc.setLocalDescription(offer))
              .then(() => deliver({marker:'rtc-started',port}));
          }
          """), delegate: recorder)
    attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil {
      recorder.deliveries.filter { $0["marker"] as? String == "rtc-started" }.count == 2
    }
    try await Task.sleep(for: .seconds(4))
    print(
      "MCP WebRTC ESCAPE console=\(console.inboundConnections) connections/\(console.datagrams) datagrams/\(console.nonHttpBytes) nonHTTP bytes; evil=\(evil.inboundConnections)/\(evil.datagrams)/\(evil.nonHttpBytes)"
    )
    // D4 residual risk: the public SDK exposes no WebRTC-disable preference. Keep the unmet
    // zero-network invariant visible as a known issue, NEVER a successful isolation proof.
    withKnownIssue(
      "WebRTC STUN/TURN bypasses canonical CSP and WKContentRuleList; no supported disable setting in Xcode 27.1"
    ) {
      #expect(console.inboundConnections == 0 && evil.inboundConnections == 0)
    }
    #expect(console.datagrams > 0)
    #expect(evil.datagrams > 0)
    #expect(console.nonHttpBytes > 0)
    #expect(evil.nonHttpBytes > 0)
    #expect(console.requests == 0 && evil.requests == 0)
  }

}
