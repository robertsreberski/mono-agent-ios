// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import WebKit

/// Owns one disposable, credential-free WebKit session. Not yet wired to the transcript.
@MainActor
final class McpAppHost: NSObject {
  let webView: McpAppWebView
  private let listener: McpAppBridgeListener
  weak var delegate: (any McpAppEnvelopeDelegate)?
  private(set) var isRetired = false
  private(set) var retirementReason: String?
  private(set) var innerLoaded = false
  #if DEBUG
    var navigationDecisions: [String] { webView.policy.navigationDecisions }
    var responseDecisions: [String] { webView.policy.responseDecisions }
  #endif

  static func make(html: String, delegate: (any McpAppEnvelopeDelegate)? = nil) async throws
    -> McpAppHost
  {
    let document = try McpSecureDocument(html: html)
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "mono-mcp-allow-local-documents-v2",
      encodedContentRuleList:
        """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^mono-mcp-host:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
        """)
    guard let rules else { throw URLError(.cannotLoadFromNetwork) }
    let host = try McpAppHost(document: document, rules: rules)
    host.delegate = delegate
    host.webView.load(URLRequest(url: McpAppShellSchemeHandler.url))
    return host
  }

  /// Defense in depth only: every accessible realm must be tested, not just the app global.
  private static let webRtcDefenseScript = """
    (() => {
      const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
        'RTCIceCandidate', 'RTCSessionDescription', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver'];
      for (const name of names) {
        let target = window;
        while (target) {
          if (target === window || Object.prototype.hasOwnProperty.call(target, name)) {
            try { Object.defineProperty(target, name, {value: undefined, writable: false, configurable: false}); }
            catch {}
          }
          target = Object.getPrototypeOf(target);
        }
      }
    })();
    """

  private init(document: McpSecureDocument, rules: WKContentRuleList) throws {
    listener = McpAppBridgeListener(nonce: UUID().uuidString, generation: UUID().uuidString)
    let controller = WKUserContentController()
    controller.add(rules)
    controller.addUserScript(
      WKUserScript(
        source: Self.webRtcDefenseScript, injectionTime: .atDocumentStart,
        forMainFrameOnly: false, in: .page))
    controller.addScriptMessageHandler(
      listener, contentWorld: McpAppBridgeListener.world, name: McpAppBridgeListener.handlerName)
    controller.addUserScript(
      WKUserScript(
        source: try listener.bootstrap(document: document), injectionTime: .atDocumentEnd,
        forMainFrameOnly: true, in: McpAppBridgeListener.world))
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = controller
    configuration.setURLSchemeHandler(
      McpAppShellSchemeHandler(), forURLScheme: McpAppShellSchemeHandler.scheme)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsInlineMediaPlayback = false
    configuration.allowsAirPlayForMediaPlayback = false
    webView = McpAppWebView(configuration: configuration)
    super.init()
    listener.host = self
    webView.policy.host = self
    webView.navigationDelegate = webView.policy
    webView.uiDelegate = webView.policy
    webView.allowsBackForwardNavigationGestures = false
    webView.isInspectable = false
    webView.allowsLinkPreview = false
  }

  func didLoadInnerDocument() {
    guard !isRetired else { return }
    innerLoaded = true
  }

  /// Mirrors the web proxy's raw JSON-RPC relay. Session secrets stay in the isolated world.
  func sendEnvelope(_ envelope: Data) async throws {
    guard !isRetired, innerLoaded,
      envelope.count <= McpAppBridgeListener.maximumEnvelopeBytes,
      let payload = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
      payload["jsonrpc"] as? String == "2.0",
      payload["method"] is String || payload.keys.contains("id")
    else { throw URLError(.cannotParseResponse) }
    let delivered = try await webView.callAsyncJavaScript(
      "return window.mcpRelay(payload)", arguments: ["payload": payload], in: nil,
      contentWorld: McpAppBridgeListener.world)
    guard delivered as? Bool == true, !isRetired else { throw URLError(.cancelled) }
  }

  #if DEBUG
    var debugTransportIdentity: [String: String] {
      ["nonce": listener.nonce, "generation": listener.generation]
    }
  #endif

  func retire(reason: String) {
    guard !isRetired else { return }
    isRetired = true
    webView.policy.isClosed = true
    retirementReason = reason
    delegate?.mcpAppHostDidRetire(self)
    webView.stopLoading()
    webView.evaluateJavaScript(
      "window.mcpRetire?.()", in: nil, in: McpAppBridgeListener.world,
      completionHandler: nil)
  }

  isolated deinit {
    webView.policy.isClosed = true
    webView.stopLoading()
    webView.evaluateJavaScript(
      "window.mcpRetire?.()", in: nil, in: McpAppBridgeListener.world, completionHandler: nil)
    Self.removeHandlers(from: webView)
  }

  private static func removeHandlers(from webView: WKWebView) {
    let controller = webView.configuration.userContentController
    controller.removeScriptMessageHandler(
      forName: McpAppBridgeListener.handlerName, contentWorld: McpAppBridgeListener.world)
    controller.removeAllUserScripts()
  }

  func close() {
    retire(reason: "Host closed")
    Self.removeHandlers(from: webView)
    delegate = nil
    webView.removeFromSuperview()
  }

}
