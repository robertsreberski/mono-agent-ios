// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import WebKit

/// Owns one disposable, credential-free WebKit session. Not yet wired to the transcript.
@MainActor
final class McpAppHost: NSObject, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  private let listener: McpAppBridgeListener
  weak var delegate: (any McpAppEnvelopeDelegate)?
  private(set) var isRetired = false
  private(set) var retirementReason: String?
  var innerLoaded = false
  private var allowedShell = false
  private var allowedSrcdoc = false
  private var allowedShellResponse = false
  private var allowedSrcdocResponse = false
  #if DEBUG
    private(set) var navigationDecisions: [String] = []
    private(set) var responseDecisions: [String] = []
  #endif

  static func make(html: String, delegate: (any McpAppEnvelopeDelegate)? = nil) async throws
    -> McpAppHost
  {
    let document = try McpSecureDocument(html: html)
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "mono-mcp-deny-network-v1",
      encodedContentRuleList:
        """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """)
    guard let rules else { throw URLError(.cannotLoadFromNetwork) }
    let host = try McpAppHost(document: document, rules: rules)
    host.delegate = delegate
    host.webView.load(URLRequest(url: McpAppShellSchemeHandler.url))
    return host
  }

  private init(document: McpSecureDocument, rules: WKContentRuleList) throws {
    listener = McpAppBridgeListener(nonce: UUID().uuidString, generation: UUID().uuidString)
    let controller = WKUserContentController()
    controller.add(rules)
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
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    listener.host = self
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.isInspectable = false
  }

  func retire(reason: String) {
    guard !isRetired else { return }
    isRetired = true
    retirementReason = reason
    webView.stopLoading()
    webView.evaluateJavaScript(
      "window.mcpRetire?.()", in: nil, in: McpAppBridgeListener.world,
      completionHandler: nil)
  }

  func close() {
    retire(reason: "Host closed")
    let controller = webView.configuration.userContentController
    controller.removeScriptMessageHandler(
      forName: McpAppBridgeListener.handlerName, contentWorld: McpAppBridgeListener.world)
    controller.removeAllUserScripts()
    delegate = nil
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url
    #if DEBUG
      navigationDecisions.append(
        "\(navigationAction.targetFrame?.isMainFrame == true ? "main" : "sub"):\(url?.absoluteString ?? "nil")"
      )
    #endif
    if !isRetired, navigationAction.targetFrame?.isMainFrame == true,
      !allowedShell, url == McpAppShellSchemeHandler.url,
      navigationAction.navigationType == .other
    {
      allowedShell = true
      decisionHandler(.allow)
    } else if !isRetired, navigationAction.targetFrame?.isMainFrame == false,
      allowedShell, !allowedSrcdoc, url?.absoluteString == "about:srcdoc"
    {
      allowedSrcdoc = true
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      retire(reason: "Navigation rejected")
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    let url = navigationResponse.response.url
    #if DEBUG
      responseDecisions.append(
        "\(navigationResponse.isForMainFrame ? "main" : "sub"):\(url?.absoluteString ?? "nil")")
    #endif
    guard !isRetired, navigationResponse.canShowMIMEType else {
      decisionHandler(.cancel)
      retire(reason: "Response rejected")
      return
    }
    if navigationResponse.isForMainFrame, !allowedShellResponse,
      url == McpAppShellSchemeHandler.url,
      navigationResponse.response.mimeType == "text/html"
    {
      allowedShellResponse = true
      decisionHandler(.allow)
    } else if !navigationResponse.isForMainFrame, !allowedSrcdocResponse,
      url?.absoluteString == "about:srcdoc"
    {
      allowedSrcdocResponse = true
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      retire(reason: "Response rejected")
    }
  }

  func webView(
    _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    retire(reason: "Redirect rejected")
  }

  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    retire(reason: "Web content process terminated")
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }

  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) { decisionHandler(.deny) }

  func webView(
    _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) { decisionHandler(.deny) }

  @available(iOS 27.0, *)
  func webView(
    _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) { decisionHandler(.deny) }
}
