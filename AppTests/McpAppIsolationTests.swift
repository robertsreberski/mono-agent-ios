// SPDX-License-Identifier: GPL-3.0-only
import Foundation
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
    const deliver = payload => parent.postMessage({...session, payload}, "*");
    addEventListener("message", event => {
      if (event.source !== parent || event.data?.type !== "mono:mcp-session") return;
      session = event.data;
      deliver({marker: "ready"});
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
}
