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
  var rawDeliveries: [[String: Any]] = []
  func mcpAppHost(_ host: McpAppHost, didReceiveEnvelope envelope: Data) {
    if let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any] {
      rawDeliveries.append(object)
      deliveries.append(object["params"] as? [String: Any] ?? object)
    }
  }
}

/// Test-only timing observations; isolation outcomes still come from TCP/UDP sinks and
/// the production delegate. This handler is never installed by production configuration.
@MainActor
private final class McpRtcTimingObserver: NSObject, WKScriptMessageHandler {
  var observations: [[String: Any]] = []
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    if let body = message.body as? [String: Any] { observations.append(body) }
  }
}

@Suite("MCP WebKit isolation", .serialized)
@MainActor
struct McpAppIsolationTests {
  private static let sessionScript = """
    const documentMarker = Math.random().toString(36) + Math.random().toString(36);
    const deliver = params => parent.postMessage({jsonrpc:"2.0",method:"test/probe",params}, "*");
    addEventListener("message", event => {
      if (event.source !== parent || event.data?.method !== "test/bootstrap") return;
      deliver({marker:"ready",documentMarker});
    });
    """

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(condition())
  }

  private func attach(_ host: McpAppHost) async throws {
    host.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    scene?.windows.first?.addSubview(host.webView)
    try await waitUntil { host.innerLoaded || host.isRetired }
    try await host.sendEnvelope(Data(#"{"jsonrpc":"2.0","method":"test/bootstrap"}"#.utf8))
  }

  @Test func customSchemeHeaderCspIsEnforced() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    try await attach(host)
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
    try await attach(host)
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
            attempt(() => {const source=new EventSource(base+'/events');setTimeout(()=>source.close(),1000);});
            if(typeof WebTransport==='function')attempt(()=>{const transport=new WebTransport(`https://127.0.0.1:${port}/transport`);transport.ready.catch(()=>{});});
            attempt(() => { const x = new XMLHttpRequest(); x.open('GET', base + '/xhr'); x.send(); });
            attempt(() => new WebSocket(`ws://127.0.0.1:${port}/socket`));
            attempt(() => navigator.sendBeacon(base + '/beacon', 'canary'));
            attempt(() => { const img = new Image(); img.src = base + '/img'; document.body.append(img); });
            attempt(() => {
              const style = document.createElement('style');
              style.textContent = `@import url(${base}/import);body{background-image:url(${base}/css)}@font-face{font-family:canary;src:url(${base}/font)}p{font-family:canary}`;
              document.head.append(style); const p=document.createElement('p');p.textContent='font canary';document.body.append(p);
            });
            attempt(()=>{const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
              const image=document.createElementNS('http://www.w3.org/2000/svg','image');image.setAttribute('href',base+'/svg-image');svg.append(image);document.body.append(svg);});
            for (const tag of ['audio','video']) attempt(() => {
              const media = document.createElement(tag); media.src = base + '/' + tag;
              media.preload = 'auto'; document.body.append(media); media.load();
            });
            attempt(() => {
              // Sandbox lacks allow-forms: this is a sandbox-blocked probe, not CSP attribution.
              const form = document.createElement('form'); form.action = base + '/form';
              document.body.append(form); form.submit();
            });
            for (const rel of ['prefetch','preconnect','dns-prefetch']) attempt(() => {
              const link = document.createElement('link'); link.rel = rel;
              link.href = base + '/' + rel; document.head.append(link);
            });

          }
          deliver({marker:'attempted-network',webTransportPresent:typeof WebTransport==='function'});
          """), delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil { recorder.deliveries.count == 2 }
    // A bounded observation window for asynchronous prefetch and ICE gathering, not a readiness sleep.
    try await Task.sleep(for: .seconds(4))
    print(
      "MCP sink counts console=\(console.inboundConnections)/\(console.requests)/\(console.datagrams) evil=\(evil.inboundConnections)/\(evil.requests)/\(evil.datagrams)"
    )
    print(
      "MCP optional WebTransport present: \(recorder.deliveries.last?["webTransportPresent"] ?? "unknown")"
    )
    #expect(!host.isRetired)
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
    try await attach(host)
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
    try await attach(host)
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
    try await attach(host)
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
          setTimeout(() => deliver({marker:'same-document', documentMarker}), 300);
          """), delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    let original = try #require(recorder.deliveries.first)
    let originalIdentity = host.debugTransportIdentity
    try await probe(host)
    try await waitUntil { recorder.deliveries.count == 2 || host.isRetired }
    #expect(host.debugTransportIdentity == originalIdentity)
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
      for key in ["documentMarker"] {
        #expect(echo[key] as? String == original[key] as? String)
        #expect((echo[key] as? String)?.isEmpty == false)
      }
      #expect(
        Set(echo.keys) == Set(["marker", "documentMarker"]))
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
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    host.webView.load(URLRequest(url: URL(fileURLWithPath: "/mcp-fictional-unreadable.html")))
    try await waitUntil { host.isRetired }
    print("MCP native file route: \(host.navigationDecisions)")
    #expect(host.navigationDecisions.contains("main:file:///mcp-fictional-unreadable.html"))
    #expect(host.retirementReason == "Navigation rejected")
    #expect(recorder.deliveries.count == 1)
  }

  @Test(arguments: [
    "direct", "cached", "prototype", "nested-immediate", "nested-after-load", "document-write",
  ])
  func webRtcMitigationVariants(_ variant: String) async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let recorder = McpEnvelopeRecorder()
    let ports = [console.port, evil.port].map(String.init).joined(separator: ",")
    let timing = McpRtcTimingObserver()
    let script = """
      const observe = value => window.webkit.messageHandlers.rtcProbe.postMessage(value);
      addEventListener('error', event => observe({marker:'script-error',name:event.error?.name,message:event.message}));
      const cachedRtcAtFirstAppScript = window.RTCPeerConnection;
      \(Self.sessionScript)
      const start = (Constructor, label) => {
        observe({marker:'constructor-observed',label,available:typeof Constructor==='function'});
        if(typeof Constructor!=='function') return;
        for(const port of [\(ports)]) {
          try {
            const rtc=new Constructor({iceServers:[{urls:`stun:127.0.0.1:${port}`},
              {urls:`turn:127.0.0.1:${port}?transport=tcp`,username:'canary',credential:'fictional'}]});
            window.rtcCanaries=[...(window.rtcCanaries||[]),rtc];
            rtc.createDataChannel('canary');
            rtc.createOffer().then(offer=>rtc.setLocalDescription(offer))
              .then(()=>deliver({marker:'rtc-started',label,port})).catch(()=>{});
          } catch {}
        }
      };
      addEventListener('message', event=>{
        if(event.source!==parent || event.data?.type!=='probe') return;
        observe({marker:'descriptors',values:['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel',
          'RTCIceCandidate','RTCSessionDescription','RTCRtpSender','RTCRtpReceiver','RTCRtpTransceiver']
          .map(name=>({name,available:typeof window[name]==='function',configurable:Object.getOwnPropertyDescriptor(window,name)?.configurable,writable:Object.getOwnPropertyDescriptor(window,name)?.writable}))});
        document.addEventListener('securitypolicyviolation',event=>observe({marker:'csp',directive:event.effectiveDirective,trusted:event.isTrusted}));
        deliver({marker:'variant-starting',variant:'\(variant)'});
        setTimeout(()=>{
          const variant='\(variant)';
          if(variant==='direct') {start(window.RTCPeerConnection,variant);return;}
          if(variant==='cached') {start(cachedRtcAtFirstAppScript,variant);return;}
          if(variant==='prototype') {
            let target=window;
            while(target) {
              const descriptor=Object.getOwnPropertyDescriptor(target,'RTCPeerConnection');
              start(descriptor?.value,'prototype-descriptor');
              target=Object.getPrototypeOf(target);
            }
            start(window.constructor.prototype.RTCPeerConnection,'window-constructor-prototype');
            try { start(Function('return RTCPeerConnection')(),'function-global'); } catch {observe({marker:'unsafe-eval-blocked'});}
            try {Object.defineProperty(window,'RTCPeerConnection',{value:function restored(){}});} catch {}
            observe({marker:'descriptor',configurable:Object.getOwnPropertyDescriptor(window,'RTCPeerConnection')?.configurable});
            return;
          }
          const frame=document.createElement('iframe');
          if(variant==='nested-after-load') frame.onload=()=>start(frame.contentWindow.RTCPeerConnection,variant);
          document.body.append(frame);
          try { observe({marker:'nested-created',available:typeof frame.contentWindow.RTCPeerConnection==='function',configurable:Object.getOwnPropertyDescriptor(frame.contentWindow,'RTCPeerConnection')?.configurable}); }
          catch(error) { observe({marker:'nested-access-denied',name:error.name,message:error.message}); }
          if(variant==='nested-immediate') start(frame.contentWindow.RTCPeerConnection,variant);
          if(variant==='document-write') {
            frame.contentDocument.open();
            frame.contentDocument.write('<script>window.webkit.messageHandlers.rtcProbe.postMessage({marker:"written-frame",available:typeof RTCPeerConnection==="function"})<'+'/script>');
            frame.contentDocument.close();
            start(frame.contentWindow.RTCPeerConnection,variant);
          }
        },50);
      });
      """
    let host = try await McpAppHost.make(html: "<script>\(script)</script>", delegate: recorder)
    host.webView.configuration.userContentController.add(timing, name: "rtcProbe")
    try await attach(host)
    defer {
      host.webView.configuration.userContentController.removeScriptMessageHandler(
        forName: "rtcProbe")
      host.close()
    }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil {
      recorder.deliveries.contains { $0["marker"] as? String == "variant-starting" }
    }
    try await Task.sleep(for: .seconds(4))
    print(
      "MCP WebRTC variant \(variant): console=\(console.inboundConnections)/\(console.datagrams)/\(console.nonHttpBytes), evil=\(evil.inboundConnections)/\(evil.datagrams)/\(evil.nonHttpBytes), retired=\(host.retirementReason ?? "none"); observations=\(recorder.deliveries)"
    )
    print("MCP RTC timing \(variant): \(timing.observations)")
    #expect(console.inboundConnections == 0 && evil.inboundConnections == 0)
    #expect(console.datagrams == 0 && evil.datagrams == 0)
    #expect(console.nonHttpBytes == 0 && evil.nonHttpBytes == 0)
    let descriptors = try #require(
      timing.observations.first { $0["marker"] as? String == "descriptors" }?["values"]
        as? [[String: Any]])
    #expect(descriptors.count == 8)
    for descriptor in descriptors {
      #expect(descriptor["available"] as? Bool == false)
      #expect(descriptor["configurable"] as? Bool == false)
      #expect(descriptor["writable"] as? Bool == false)
    }
    if ["direct", "cached", "prototype"].contains(variant) {
      #expect(!host.isRetired)
      #expect(timing.observations.contains { $0["marker"] as? String == "constructor-observed" })
    } else {
      #expect(host.isRetired)
      #expect(host.navigationDecisions.contains("sub:about:blank"))
    }
    #expect(console.requests == 0 && evil.requests == 0)
    for sink in [console, evil] {
      _ = try await URLSession.shared.data(from: URL(string: sink.origin + "/control")!)
      try await sink.sendUDPControl()
      try await waitUntil { sink.requests == 1 && sink.datagrams > 0 }
    }
    if !host.isRetired {
      let isolated = try await host.webView.callAsyncJavaScript(
        "return typeof RTCPeerConnection", arguments: [:], in: nil,
        contentWorld: McpAppBridgeListener.world)
      #expect(isolated as? String == "function")
    }
  }

  @Test func forgedEventsAndStaleSessionsNeverDeliver() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(probe: "deliver({marker:'valid-after-forgeries'});"), delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    _ = try await host.webView.callAsyncJavaScript(
      """
      const frame=document.querySelector('iframe');
      const data={jsonrpc:'2.0',method:'test/probe',params:{marker:'forged-main-world'}};
      window.dispatchEvent(new MessageEvent('message',{source:frame.contentWindow,origin:'null',data}));
      window.dispatchEvent(new MessageEvent('message',{source:frame.contentWindow,origin:'https://wrong.example',data}));
      window.postMessage(data,'*');
      """, arguments: [:], in: nil, contentWorld: .page)
    try await probe(host)
    try await waitUntil { recorder.deliveries.count >= 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(recorder.deliveries.count == 2)
    #expect(recorder.deliveries.last?["marker"] as? String == "valid-after-forgeries")
    let identity = host.debugTransportIdentity
    let base: [String: Any] = [
      "nonce": identity["nonce"]!, "generation": identity["generation"]!, "kind": "envelope",
      "payload": ["jsonrpc": "2.0", "method": "test/probe", "params": ["marker": "stale"]],
    ]
    for key in ["nonce", "generation"] {
      var stale = base
      stale[key] = "previous-session"
      #expect(try await postNativeTransport(host, body: stale) == "rejected")
    }
    #expect(recorder.deliveries.count == 2)
    #expect(!host.isRetired)
    let handler = try await host.webView.evaluateJavaScript(
      "typeof window.webkit?.messageHandlers?.mcpEnvelope")
    #expect(handler as? String == "undefined")
  }

  @Test func wrongFrameNeverDeliversAfterNavigationRejection() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    _ = try await host.webView.callAsyncJavaScript(
      """
      const other=document.createElement('iframe');other.sandbox='allow-scripts';
      other.srcdoc=`<script>parent.postMessage({jsonrpc:'2.0',method:'test/probe',params:{marker:'wrong-frame'}},'*')</script>`;
      document.body.append(other);
      """, arguments: [:], in: nil, contentWorld: .page)
    try await waitUntil { host.isRetired }
    #expect(recorder.deliveries.count == 1)
    #expect(host.retirementReason == "Navigation rejected")
  }

  @Test func secondFrameLoadEventRetiresListener() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    // Synthetic DOM load explicitly exercises the counter independently of navigation policy.
    _ = try await host.webView.evaluateJavaScript(
      "document.querySelector('iframe').dispatchEvent(new Event('load'))")
    try await waitUntil { host.isRetired }
    #expect(host.retirementReason == "Inner frame loaded more than once")
    #expect(recorder.deliveries.count == 1)
  }

  @Test(arguments: ["x", "/"])
  func oversizedMessagesRejectedInJavascriptAndNatively(_ character: String) async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          deliver({marker:'oversized',text:'\(character)'.repeat(\(McpAppBridgeListener.maximumEnvelopeBytes))});
          deliver({marker:'after-oversized'});
          deliver({marker:'large-valid',text:'\(character)'.repeat(\(McpAppBridgeListener.maximumEnvelopeBytes)-512)});
          """), delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(host)
    try await waitUntil { recorder.deliveries.count >= 3 }
    #expect(recorder.deliveries.count == 3)
    #expect(recorder.deliveries[1]["marker"] as? String == "after-oversized")
    #expect(recorder.deliveries[2]["marker"] as? String == "large-valid")
    let identity = host.debugTransportIdentity
    let base: [String: Any] = [
      "nonce": identity["nonce"]!, "generation": identity["generation"]!, "kind": "envelope",
      "payload": ["jsonrpc": "2.0", "method": "test/probe", "params": ["text": ""]],
    ]
    let options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    let overhead = try JSONSerialization.data(withJSONObject: base, options: options).count
    var exact = base
    exact["payload"] = [
      "jsonrpc": "2.0", "method": "test/probe",
      "params": [
        "text": String(
          repeating: character, count: McpAppBridgeListener.maximumEnvelopeBytes - overhead)
      ],
    ]
    #expect(
      try JSONSerialization.data(withJSONObject: exact, options: options).count
        == McpAppBridgeListener.maximumEnvelopeBytes)
    #expect(try await postNativeTransport(host, body: exact) == "accepted")
    #expect(recorder.deliveries.count == 4)
    exact["payload"] = [
      "jsonrpc": "2.0", "method": "test/probe",
      "params": [
        "text": String(
          repeating: character, count: McpAppBridgeListener.maximumEnvelopeBytes - overhead + 1)
      ],
    ]
    #expect(try await postNativeTransport(host, body: exact) == "rejected")
    #expect(recorder.deliveries.count == 4)
    var stale = base
    stale["generation"] = "previous-generation"
    #expect(try await postNativeTransport(host, body: stale) == "rejected")
    #expect(recorder.deliveries.count == 4)
  }

  private func postNativeTransport(_ host: McpAppHost, body: [String: Any]) async throws -> String?
  {
    let value = try await host.webView.callAsyncJavaScript(
      """
      try { return await window.webkit.messageHandlers.mcpEnvelope.postMessage(body); }
      catch { return 'rejected'; }
      """, arguments: ["body": body], in: nil, contentWorld: McpAppBridgeListener.world)
    return value as? String
  }

  @Test func perHostCookiesStorageAndParentDomAreIsolated() async throws {
    let firstRecorder = McpEnvelopeRecorder()
    let first = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: firstRecorder)
    try await attach(first)
    defer { first.close() }
    try await waitUntil { firstRecorder.deliveries.count == 1 }
    let cookie = try #require(
      HTTPCookie(properties: [
        .domain: "fixture.example", .path: "/", .name: "canary", .value: "fictional-cookie",
      ]))
    await first.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    let firstCookies = await first.webView.configuration.websiteDataStore.httpCookieStore
      .allCookies()
    #expect(firstCookies.contains { $0.name == "canary" && $0.value == "fictional-cookie" })
    let storageSeed = try await first.webView.callAsyncJavaScript(
      """
      document.body.dataset.canary='fictional-parent';
      const result={};
      try { localStorage.setItem('canary','fictional-local'); result.local=true; } catch { result.local=false; }
      result.indexed=await new Promise(resolve => {
        try {
          const request=indexedDB.open('mcp-canary',1);
          request.onupgradeneeded=()=>request.result.createObjectStore('values').put('fictional-indexed','canary');
          request.onsuccess=()=>{request.result.close();resolve(true);};request.onerror=()=>resolve(false);
        } catch {resolve(false);}
      });
      return result;
      """, arguments: [:], in: nil, contentWorld: .page)
    print("MCP shell storage seed: \(storageSeed ?? "nil")")
    let seeded = try #require(storageSeed as? [String: Any])
    #expect(seeded["local"] as? Bool == true)
    #expect(seeded["indexed"] as? Bool == true)
    let recorder = McpEnvelopeRecorder()
    let second = try await McpAppHost.make(
      html: appHtml(
        probe: """
          try { deliver({leak:'parent',value:parent.document.body.dataset.canary}); } catch {}
          try { const value=document.cookie; if(value) deliver({leak:'cookie',value}); } catch {}
          try { deliver({leak:'local',value:localStorage.getItem('canary')}); } catch {}
          try {
            const r=indexedDB.open('mcp-canary',1);
            r.onsuccess=()=>{deliver({leak:'indexed'});r.result.close();};
          } catch {}
          setTimeout(()=>deliver({marker:'storage-probed'}),300);
          """), delegate: recorder)
    try await attach(second)
    defer { second.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    #expect(
      first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore
    )
    #expect(
      first.webView.configuration.userContentController
        !== second.webView.configuration.userContentController)
    #expect(!first.webView.configuration.websiteDataStore.isPersistent)
    #expect(!second.webView.configuration.websiteDataStore.isPersistent)
    let secondCookies = await second.webView.configuration.websiteDataStore.httpCookieStore
      .allCookies()
    #expect(secondCookies.isEmpty)
    let secondStorage =
      try await second.webView.callAsyncJavaScript(
        """
        const result={};
        try { result.local=localStorage.getItem('canary'); } catch { result.local='unavailable'; }
        result.indexed=await new Promise(resolve => {
          try { const r=indexedDB.open('mcp-canary',1);
            r.onupgradeneeded=()=>{};
            r.onsuccess=()=>{const exists=r.result.objectStoreNames.contains('values');r.result.close();resolve(exists);};
            r.onerror=()=>resolve(false);
          } catch {resolve(false);}
        });return result;
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    #expect(secondStorage?["local"] is NSNull)
    #expect(secondStorage?["indexed"] as? Bool == false)
    _ = try await second.webView.evaluateJavaScript(
      "document.body.dataset.canary='fictional-second-parent'")
    try await probe(second)
    try await waitUntil {
      recorder.deliveries.contains { $0["marker"] as? String == "storage-probed" }
    }
    print("MCP storage deliveries: \(recorder.deliveries)")
    #expect(recorder.deliveries.count == 2)
    #expect(recorder.deliveries.last?["marker"] as? String == "storage-probed")
  }

  @Test func releasedHostLeavesRetainedWebViewFailClosed() async throws {
    let sink = try await sink()
    defer { sink.stop() }
    let recorder = McpEnvelopeRecorder()
    var host: McpAppHost? = try await McpAppHost.make(
      html: appHtml(
        probe: """
          deliver({marker:'navigation-scheduled'});
          setTimeout(()=>{location.href='\(sink.origin)/released-host';},150);
          """), delegate: recorder)
    weak let weakHost = host
    let retained = try #require(host?.webView)
    try await attach(try #require(host))
    try await waitUntil { recorder.deliveries.count == 1 }
    try await probe(try #require(host))
    try await waitUntil { recorder.deliveries.count == 2 }
    host = nil
    try await waitUntil { weakHost == nil }
    #expect(retained.navigationDelegate === retained.policy)
    #expect(retained.uiDelegate === retained.policy)
    #expect(retained.policy.isClosed)
    retained.load(URLRequest(url: URL(string: "data:text/html,fail-closed-canary")!))
    try await waitUntil {
      retained.policy.navigationDecisions.contains("main:data:text/html,fail-closed-canary")
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(retained.url == McpAppShellSchemeHandler.url)
    #expect(sink.inboundConnections == 0)
    #expect(recorder.deliveries.count == 2)
    #expect(retained.configuration.userContentController.userScripts.isEmpty)
    retained.removeFromSuperview()
  }

  @Test func nativeLinkPreviewContextMenuAndDraggingAreDenied() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html:
        "<a href='https://fixture.example/link'><img src='data:image/svg+xml,%3Csvg/%3E'>link</a><script>\(Self.sessionScript)</script>",
      delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    #expect(!host.webView.allowsLinkPreview)
    #expect(host.webView.policy.contextMenuConfiguration() == nil)
    #expect(
      host.webView.uiDelegate?.responds(
        to: NSSelectorFromString("webView:contextMenuConfigurationForElement:completionHandler:"))
        == true)
    host.webView.setNeedsLayout()
    host.webView.layoutIfNeeded()
    func dragCount(_ view: UIView) -> Int {
      view.interactions.filter { $0 is UIDragInteraction }.count
        + view.subviews.reduce(0) { $0 + dragCount($1) }
    }
    #expect(dragCount(host.webView) == 0)
  }
  @Test func rawJsonRpcRoundTripKeepsSessionPrivate() async throws {
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: """
        <script>
        \(Self.sessionScript)
        let received=[];
        addEventListener('message',event=>{
          if(event.source!==parent)return;
          received.push(event.data);
          if(event.data?.id===7)parent.postMessage({jsonrpc:'2.0',id:7,result:{reply:event.data,received}},'*');
        });
        </script>
        """, delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await waitUntil { recorder.deliveries.count == 1 }
    #expect(recorder.rawDeliveries.first?["jsonrpc"] as? String == "2.0")
    #expect(recorder.rawDeliveries.first?["method"] as? String == "test/probe")
    try await host.sendEnvelope(
      Data(#"{"jsonrpc":"2.0","id":7,"result":{"value":"fictional-reply"}}"#.utf8))
    try await waitUntil { recorder.rawDeliveries.count == 2 }
    let result = try #require(recorder.rawDeliveries.last?["result"] as? [String: Any])
    let received = try #require(result["received"] as? [[String: Any]])
    #expect(received.count == 2)
    #expect(
      received.allSatisfy {
        $0["jsonrpc"] as? String == "2.0" && $0["nonce"] == nil && $0["generation"] == nil
      })
    #expect(result["reply"] as? [String: Any] != nil)
  }

  @Test func isolatedWorldWebRtcPositiveControlReachesSinks() async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    try await attach(host)
    defer { host.close() }
    let ports = [console.port, evil.port].map(String.init).joined(separator: ",")
    let started = try await host.webView.callAsyncJavaScript(
      """
      window.rtcPositiveControls=[];
      for(const port of [\(ports)]){
        const rtc=new RTCPeerConnection({iceServers:[{urls:`stun:127.0.0.1:${port}`},
          {urls:`turn:127.0.0.1:${port}?transport=tcp`,username:'canary',credential:'fictional'}]});
        window.rtcPositiveControls.push(rtc);rtc.createDataChannel('control');
        await rtc.setLocalDescription(await rtc.createOffer());
      }
      return 'started';
      """, arguments: [:], in: nil, contentWorld: McpAppBridgeListener.world)
    #expect(started as? String == "started")
    for sink in [console, evil] {
      try await waitUntil { sink.datagrams > 0 || sink.nonHttpBytes > 0 }
      #expect(sink.datagrams > 0 || sink.nonHttpBytes > 0)
      #expect(sink.requests == 0)
    }
    #expect(!host.isRetired)
    print(
      "MCP WebKit RTC positive control console=\(console.inboundConnections)/\(console.datagrams)/\(console.nonHttpBytes), evil=\(evil.inboundConnections)/\(evil.datagrams)/\(evil.nonHttpBytes)"
    )
  }

  @Test func contentRulesAloneBlockWebSockets() async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: "<script>\(Self.sessionScript)</script>", delegate: recorder)
    try await attach(host)
    defer { host.close() }
    let ports = [console.port, evil.port].map(String.init).joined(separator: ",")
    // The outer shell has no connect-src/default-src restriction: CSP cannot block this probe.
    #expect(!McpAppShellSchemeHandler.contentSecurityPolicy.contains("connect-src"))
    #expect(!McpAppShellSchemeHandler.contentSecurityPolicy.contains("default-src"))
    let script = """
      await Promise.all([\(ports)].map(port=>new Promise(resolve=>{
        const socket=new WebSocket(`ws://127.0.0.1:${port}/socket-control`);
        socket.onerror=()=>resolve();socket.onopen=()=>{socket.close();resolve();};
        setTimeout(resolve,1000);
      })));return 'attempted';
      """
    _ = try await host.webView.callAsyncJavaScript(
      script, arguments: [:], in: nil, contentWorld: .page)
    #expect(console.inboundConnections == 0 && evil.inboundConnections == 0)
    #expect(!host.isRetired)
    // Test-only positive control removes ONLY the rule list, keeping identical shell/CSP/runtime.
    host.webView.configuration.userContentController.removeAllContentRuleLists()
    _ = try await host.webView.callAsyncJavaScript(
      script, arguments: [:], in: nil, contentWorld: .page)
    try await waitUntil { console.requests > 0 && evil.requests > 0 }
    #expect(console.inboundConnections > 0 && evil.inboundConnections > 0)
    #expect(console.requestLines.contains("GET /socket-control HTTP/1.1"))
    #expect(evil.requestLines.contains("GET /socket-control HTTP/1.1"))
    #expect(!host.isRetired)
  }

  @Test(arguments: ["anchor-ping", "meta-refresh"])
  func additionalNavigationProbesRetireWithoutSinkHits(_ route: String) async throws {
    let console = try await sink()
    let evil = try await sink()
    defer {
      console.stop()
      evil.stop()
    }
    let command: String
    if route == "anchor-ping" {
      command =
        "const a=document.createElement('a');a.href='\(console.origin)/navigation';a.ping='\(evil.origin)/ping';document.body.append(a);a.click();"
    } else {
      command =
        "const meta=document.createElement('meta');meta.httpEquiv='refresh';meta.content='0;url=\(console.origin)/refresh';document.head.append(meta);"
    }
    let recorder = McpEnvelopeRecorder()
    let host = try await McpAppHost.make(
      html: appHtml(
        probe: """
          deliver({marker:'navigation-probe-starting'});setTimeout(()=>{\(command)},50);
          """), delegate: recorder)
    try await attach(host)
    defer { host.close() }
    try await probe(host)
    try await waitUntil { host.isRetired }
    try await Task.sleep(for: .milliseconds(300))
    #expect(console.inboundConnections == 0 && evil.inboundConnections == 0)
    #expect(console.requests == 0 && evil.requests == 0)
    #expect(recorder.deliveries.count == 2)
    #expect(host.retirementReason == "Navigation rejected")
  }

}
