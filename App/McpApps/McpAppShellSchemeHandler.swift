// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import WebKit

/// Fixed trusted outer document. The web proxy's main-world bootstrap is replaced by
/// a main-frame-only isolated-world bootstrap; invocation values never enter this response.
@MainActor
final class McpAppShellSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "mono-mcp-host"
  static let url = URL(string: "mono-mcp-host://shell/")!
  static let contentSecurityPolicy = [
    "script-src 'unsafe-inline'", "form-action 'none'", "object-src 'none'",
    "worker-src 'none'", "manifest-src 'none'", "navigate-to 'none'", "frame-ancestors 'self'",
    "webrtc 'block'",
  ].joined(separator: "; ")

  // Layout and metadata from MCP_APP_PROXY_DOCUMENT. No main-world executable code.
  static let document = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="referrer" content="no-referrer">
    <meta name="color-scheme" content="light">
    <style>html,body,#root{width:100%;height:100%;margin:0;overflow:hidden}iframe{width:100%;height:100%;display:block;border:0}</style>
    </head>
    <body>
    <div id="root" aria-live="polite"></div>
    </body>
    </html>
    """

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard urlSchemeTask.request.url == Self.url,
      urlSchemeTask.request.httpMethod == "GET",
      let response = HTTPURLResponse(
        url: Self.url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "private, no-store, max-age=0",
          "X-Frame-Options": "SAMEORIGIN",
          "Content-Security-Policy": Self.contentSecurityPolicy,
          "Cross-Origin-Resource-Policy": "same-origin",
          "X-Content-Type-Options": "nosniff",
        ])
    else {
      urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
      return
    }
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(Data(Self.document.utf8))
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
