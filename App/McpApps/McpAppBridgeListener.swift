// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import WebKit

@MainActor
protocol McpAppEnvelopeDelegate: AnyObject {
  /// Validated transport only. JSON-RPC method semantics and effects belong to the next layer.
  func mcpAppHost(_ host: McpAppHost, didReceiveEnvelope envelope: Data)
  func mcpAppHostDidRetire(_ host: McpAppHost)
}

extension McpAppEnvelopeDelegate {
  func mcpAppHostDidRetire(_ host: McpAppHost) {}
}

@MainActor
final class McpAppBridgeListener: NSObject, WKScriptMessageHandlerWithReply {
  static let maximumEnvelopeBytes = 1024 * 1024 + 64 * 1024
  static let handlerName = "mcpEnvelope"
  static let world = WKContentWorld.world(name: "mono.mcp.isolation")
  weak var host: McpAppHost?
  let nonce: String
  let generation: String
  #if DEBUG
    var debugDefersInitialLoad = false
  #endif

  init(nonce: String, generation: String) {
    self.nonce = nonce
    self.generation = generation
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor (Any?, String?) -> Void
  ) {
    guard let host, !host.isRetired,
      message.webView === host.webView,
      message.name == Self.handlerName,
      message.frameInfo.isMainFrame,
      message.frameInfo.request.url == McpAppShellSchemeHandler.url,
      message.frameInfo.securityOrigin.protocol == McpAppShellSchemeHandler.scheme,
      message.frameInfo.securityOrigin.host == "shell",
      let body = message.body as? [String: Any],
      body["nonce"] as? String == nonce,
      body["generation"] as? String == generation,
      JSONSerialization.isValidJSONObject(body),
      let encoded = try? JSONSerialization.data(
        withJSONObject: body, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
      encoded.count <= Self.maximumEnvelopeBytes
    else {
      replyHandler(nil, "Rejected MCP envelope")
      return
    }
    switch body["kind"] as? String {
    case "loaded":
      host.didLoadInnerDocument()
    case "retired":
      host.retire(reason: "Inner frame loaded more than once")
    case "envelope":
      guard host.innerLoaded, let payload = body["payload"] as? [String: Any],
        payload["jsonrpc"] as? String == "2.0",
        payload["method"] is String || payload.keys.contains("id"),
        JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(
          withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
        data.count <= Self.maximumEnvelopeBytes
      else {
        replyHandler(nil, "Rejected MCP payload")
        return
      }
      host.delegate?.mcpAppHost(host, didReceiveEnvelope: data)
    default:
      replyHandler(nil, "Unknown MCP transport message")
      return
    }
    replyHandler("accepted", nil)
  }

  func bootstrap(document: McpSecureDocument) throws -> String {
    // JSON encoding, not string interpolation into a JS literal, preserves escaping-heavy HTML.
    func literal(_ value: String) throws -> String {
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    #if DEBUG
      let bufferDiagnostics = """
        let peakCount = 0, peakBytes = 0, flushed = 0, earlyRejected = 0, overflow = 0;
        window.mcpBufferState = () => ({loads, retired, count: early.length, bytes: earlyBytes,
          peakCount, peakBytes, flushed, earlyRejected, overflow});
        """
      let deferredLoadSetup =
        debugDefersInitialLoad
        ? """
        let firstLoadPending = false;
        window.mcpCompleteInitialLoad = () => {
          if (firstLoadPending && frame && !retired) { firstLoadPending = false; didLoad(); }
        };
        """ : ""
      let deferredLoadGate =
        debugDefersInitialLoad
        ? """
        if (loads === 0) {
          if (firstLoadPending) retire(); else firstLoadPending = true;
          return;
        }
        """ : ""
      let rejectedDiagnostics = "if (loads === 0) earlyRejected++;"
      let queuedDiagnostics =
        "peakCount = Math.max(peakCount, early.length); peakBytes = Math.max(peakBytes, earlyBytes);"
      let flushedDiagnostics = "flushed++;"
      let overflowDiagnostics = "overflow++;"
    #else
      let bufferDiagnostics = ""
      let deferredLoadSetup = ""
      let deferredLoadGate = ""
      let rejectedDiagnostics = ""
      let queuedDiagnostics = ""
      let flushedDiagnostics = ""
      let overflowDiagnostics = ""
    #endif
    return """
      (() => {
        "use strict";
        const nonce = \(try literal(nonce));
        const generation = \(try literal(generation));
        const root = document.getElementById("root");
        if (!root || window !== window.top) return;
        let frame = document.createElement("iframe");
        let loads = 0, retired = false, early = [], earlyBytes = 0;
        \(bufferDiagnostics)
        const send = (kind, payload) => {
          const body = {nonce, generation, kind, ...(payload ? {payload} : {})};
          try {
            if (new TextEncoder().encode(JSON.stringify(body)).byteLength > \(Self.maximumEnvelopeBytes)) return;
            window.webkit.messageHandlers.\(Self.handlerName).postMessage(body).catch(() => {});
          } catch {}
        };
        const retire = () => {
          retired = true;
          early = [];
          earlyBytes = 0;
          if (!frame) return;
          frame.remove();
          frame = null;
          root.textContent = "App navigation was blocked.";
          send("retired");
        };
        // Kept in the isolated world only; native retirement also cuts off delivery immediately.
        window.mcpRetire = retire;
        const isRpc = data => data && typeof data === "object" && !Array.isArray(data)
          && data.jsonrpc === "2.0" && (typeof data.method === "string" || "id" in data);
        window.mcpRelay = payload => {
          if (!frame || loads !== 1 || !isRpc(payload)) return false;
          try {
            if (new TextEncoder().encode(JSON.stringify(payload)).byteLength > \(Self.maximumEnvelopeBytes)) return false;
            frame.contentWindow.postMessage(payload, "*");
            return true;
          } catch { return false; }
        };
        window.addEventListener("message", event => {
          if (!event.isTrusted || !frame || retired || loads > 1
              || event.source !== frame.contentWindow || event.origin !== "null") {
            \(rejectedDiagnostics)
            return;
          }
          const data = event.data;
          if (!isRpc(data)) return;
          if (loads === 0) {
            try {
              const body = JSON.stringify({nonce, generation, kind: "envelope", payload: data});
              const bytes = new TextEncoder().encode(body).byteLength;
              if (early.length >= 16 || bytes > \(Self.maximumEnvelopeBytes) - earlyBytes) {
                \(overflowDiagnostics)
                return;
              }
              // Immutable snapshot; no messages reach native semantics before the first load.
              early.push(JSON.stringify(data));
              earlyBytes += bytes;
              \(queuedDiagnostics)
            } catch {}
            return;
          }
          if (loads === 1) send("envelope", data);
        });
        frame.title = "MCP App content";
        frame.setAttribute("sandbox", "allow-scripts");
        frame.setAttribute("allow", "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-write 'none'");
        frame.referrerPolicy = "no-referrer";
        frame.srcdoc = \(try literal(document.html));
        const didLoad = () => {
          if (!frame) return;
          if (++loads > 1) { retire(); return; }
          send("loaded");
          const pending = early;
          early = [];
          earlyBytes = 0;
          for (const encoded of pending) {
            if (!frame || retired || loads !== 1) break;
            send("envelope", JSON.parse(encoded));
            \(flushedDiagnostics)
          }
        };
        \(deferredLoadSetup)
        frame.addEventListener("load", () => {
          if (!frame || retired) return;
          \(deferredLoadGate)
          didLoad();
        });
        root.replaceChildren(frame);
      })();
      """
  }
}
