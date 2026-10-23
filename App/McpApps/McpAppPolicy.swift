// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UIKit
import WebKit

/// Retained by the web view, never by its weak delegate slots alone. No host means deny.
@MainActor
final class McpAppPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
  weak var host: McpAppHost?
  var isClosed = false
  private var allowedShell = false
  private var allowedSrcdoc = false
  private var allowedShellResponse = false
  private var allowedSrcdocResponse = false
  #if DEBUG
    private(set) var navigationDecisions: [String] = []
    private(set) var responseDecisions: [String] = []
  #endif

  func contextMenuConfiguration() -> UIContextMenuConfiguration? { nil }

  func webView(
    _ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
    completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
  ) { completionHandler(contextMenuConfiguration()) }

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
    if !isClosed, host?.isRetired == false, navigationAction.targetFrame?.isMainFrame == true,
      !allowedShell, url == McpAppShellSchemeHandler.url,
      navigationAction.navigationType == .other
    {
      allowedShell = true
      decisionHandler(.allow)
    } else if !isClosed, host?.isRetired == false,
      navigationAction.targetFrame?.isMainFrame == false,
      allowedShell, !allowedSrcdoc, url?.absoluteString == "about:srcdoc"
    {
      allowedSrcdoc = true
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      host?.retire(reason: "Navigation rejected")
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
    guard !isClosed, host?.isRetired == false, navigationResponse.canShowMIMEType else {
      decisionHandler(.cancel)
      host?.retire(reason: "Response rejected")
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
      host?.retire(reason: "Response rejected")
    }
  }

  func webView(
    _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    host?.retire(reason: "Redirect rejected")
  }

  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    host?.retire(reason: "Web content process terminated")
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
