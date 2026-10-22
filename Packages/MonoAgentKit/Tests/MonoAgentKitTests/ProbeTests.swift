// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@Test func healthyProbeUsesRootRoutes() async throws {
  let transport = ScriptedTransport(Scenario.consoleOnline.steps)
  let identity = try await ConnectionProbe(transport: transport).probe(Scenario.endpoint)
  #expect(identity.displayName == "Flockbox")
  let requests = await transport.requests
  #expect(requests.map { $0.url!.path } == ["/healthz", "/api/v1/bootstrap"])
  #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
}

@Test(arguments: [
  (URLError.Code.timedOut, ProbeError.timeout),
  (.serverCertificateUntrusted, .tls), (.secureConnectionFailed, .tls),
  (.cannotConnectToHost, .connectivity), (.notConnectedToInternet, .connectivity),
])
func networkFailures(example: (URLError.Code, ProbeError)) async {
  let probe = ConnectionProbe(transport: ScriptedTransport([.failure(example.0)]))
  await #expect(throws: example.1) { try await probe.probe(Scenario.endpoint) }
}

@Test func protocolFailures() async {
  let examples: [(HTTPResponse, ProbeError)] = [
    (
      HTTPResponse(data: Data(#"{"status":"ok","version":2,"push":"ok"}"#.utf8)),
      .unsupportedVersion(2)
    ),
    (
      HTTPResponse(data: Data(#"{"status":"failed","version":1,"push":"degraded"}"#.utf8)),
      .unhealthy
    ),
    (HTTPResponse(data: Data("<html>proxy</html>".utf8), contentType: "text/html"), .nonJSON),
    (HTTPResponse(data: Data("{}".utf8)), .invalidResponse),
    (
      HTTPResponse(
        data: Data(#"{"error":{"code":"untrusted_host","message":"Not allowed"}}"#.utf8),
        status: 421),
      .untrustedHost
    ),
    (HTTPResponse(data: Data(#"{"code":"untrusted_host"}"#.utf8), status: 421), .http(421)),
    (
      HTTPResponse(
        data: Data(#"{"error":{"code":"misdirected_request","message":"Misdirected"}}"#.utf8),
        status: 421),
      .http(421)
    ),
    (
      HTTPResponse(data: Data("Misdirected Request".utf8), status: 421, contentType: "text/html"),
      .http(421)
    ),
    (HTTPResponse(data: Data(), status: 503), .http(503)),
    (HTTPResponse(data: Data(), status: 302), .redirect),
  ]
  for (response, error) in examples {
    let transport = ScriptedTransport([.response(response)])
    await #expect(throws: error) {
      try await ConnectionProbe(transport: transport).probe(Scenario.endpoint)
    }
    #expect(await transport.requests.count == 1)
  }
}

@Test func bootstrapMustAlsoBeCompatible() async {
  let bad = HTTPResponse(
    data: Data(
      String(decoding: Scenario.bootstrap.data, as: UTF8.self).replacingOccurrences(
        of: "\"version\":1", with: "\"version\":9"
      ).utf8))
  let probe = ConnectionProbe(
    transport: ScriptedTransport([.response(Scenario.health), .response(bad)]))
  await #expect(throws: ProbeError.unsupportedVersion(9)) {
    try await probe.probe(Scenario.endpoint)
  }
}

@Test func independentScriptsFailClosed() async {
  let empty = ScriptedTransport([])
  let online = ScriptedTransport(Scenario.consoleOnline.steps)
  await #expect(throws: ProbeError.connectivity) {
    try await ConnectionProbe(transport: empty).probe(Scenario.endpoint)
  }
  _ = try? await ConnectionProbe(transport: online).probe(Scenario.endpoint)
  #expect(await online.requests.count == 2)
}
