// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@Test(arguments: [
  ("http://localhost:8787/", "http://localhost:8787"),
  ("https://münich.example/", "https://xn--mnich-kva.example"),
  ("http://127.0.0.1", "http://127.0.0.1"),
  ("http://192.168.1.8:8080", "http://192.168.1.8:8080"),
  ("http://[::1]:8787/", "http://[::1]:8787"),
  ("http://[fd00::8]:8787", "http://[fd00::8]:8787"),
  ("https://Console.Example.ts.net:8443/", "https://console.example.ts.net:8443"),
  ("https://console.example.ts.net./", "https://console.example.ts.net"),
  ("HTTPS://console.example.ts.net:443", "https://console.example.ts.net"),
  ("http://example.com:80/", "http://example.com"),
])
func normalization(example: (String, String)) throws {
  let endpoint = try ConsoleEndpoint(example.0)
  #expect(endpoint.origin == example.1)
  let builder = RequestBuilder(endpoint: endpoint)
  let request = builder.get(.bootstrap, claimingOrigin: true)
  #expect(request.url?.absoluteString == example.1 + "/api/v1/bootstrap")
  #expect(request.value(forHTTPHeaderField: "X-Mono-Agent-Web-Origin") == example.1)
  #expect(request.value(forHTTPHeaderField: "Host") == nil)
}

@Test(arguments: [
  "localhost:8787", "ftp://example.com", "https://", "https://example.com/prefix",
  "https://user:pass@example.com", "https://user@example.com", "https://example.com?x=1",
  "https://example.com#x", "https://example.com?", "https://example.com#",
  "https://example.com/%2F", "http://example.com:0", "http://example.com:65536",
  "http://example.com:bad", "http://[fe80::1%25en0]", "https://example.com//", "http://::1",
  "https://example.com/./", "http://[fdinvalid::1]", "http://[fe80:garbage]",
])
func invalidEndpoints(input: String) {
  #expect(throws: EndpointError.self) { try ConsoleEndpoint(input) }
}

@Test(arguments: [
  "http://127.0.0.1", "http://10.0.0.2", "http://172.16.0.1", "http://192.168.0.1", "http://[::1]",
  "http://[fd00::1]", "http://100.64.0.1", "http://flockbox.local",
  "http://[fc00::1]", "http://[fe90::1]", "http://[0:0:0:0:0:0:0:1]",
])
func localHTTP(input: String) throws {
  let endpoint = try ConsoleEndpoint(input)
  #expect(endpoint.isLocalHost)
  #expect(endpoint.isInsecure)
}

@Test func publicHTTPAndRoundTrip() throws {
  let endpoint = try ConsoleEndpoint("http://example.com")
  #expect(!endpoint.isLocalHost)
  #expect(
    try JSONDecoder().decode(ConsoleEndpoint.self, from: JSONEncoder().encode(endpoint)) == endpoint
  )
}

@Test(arguments: [
  "http://10.0.0.1.evil.example", "http://127.0.0.1.attacker.example",
  "http://0127.0.0.1", "http://1.2.3", "http://256.1.1.1", "http://0x7f.0.0.1",
  "http://10.00.0.1", "http://127.0.0.1.extra", "http://fd00.evil.example",
  "http://[2001:db8::1]", "http://[fec0::1]", "http://[::ffff:127.0.0.1]",
])
func nonLocalHTTPRequiresConfirmation(input: String) throws {
  #expect(try !ConsoleEndpoint(input).isLocalHost)
}

@Test func trailingDotDoesNotCreateAnotherEndpoint() throws {
  #expect(
    try ConsoleEndpoint("https://console.example.ts.net.")
      == ConsoleEndpoint("https://console.example.ts.net"))
}
