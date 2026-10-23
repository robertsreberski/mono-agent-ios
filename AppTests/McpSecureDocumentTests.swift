// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

@Suite("MCP secure-document goldens")
struct McpSecureDocumentTests {
  // Web mcp-app-document.ts:24–41,50–52; mcp-app-proxy.test.ts:259–282.
  @Test func canonicalNoGrantsGolden() throws {
    let expected =
      "<!doctype html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src blob:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; child-src 'none'; worker-src 'none'; manifest-src 'none'; navigate-to 'none'\"><meta name=\"referrer\" content=\"no-referrer\"></head><p>producer contract</p>"
    #expect(try McpSecureDocument(html: "<p>producer contract</p>").html == expected)
    #expect(try McpSecureDocument(validatingNoGrants: expected).html == expected)
  }

  // Web mcp-app-proxy.test.ts:259–282,333–340. Grants are producer-only in PR0.
  @Test func capabilityProducerGolden() throws {
    let origin = "http://127.0.0.1:6060"
    let grants = McpSecureDocument.Grants(
      connectDomains: [origin], resourceDomains: [origin], frameDomains: [origin],
      baseUriDomains: [origin])
    #expect(
      McpSecureDocument.contentSecurityPolicy(grants)
        == "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' http://127.0.0.1:6060; img-src data: blob: http://127.0.0.1:6060; font-src data: http://127.0.0.1:6060; media-src blob: http://127.0.0.1:6060; connect-src http://127.0.0.1:6060; frame-src http://127.0.0.1:6060; base-uri http://127.0.0.1:6060; form-action 'none'; object-src 'none'; child-src 'none'; worker-src 'none'; manifest-src 'none'; navigate-to 'none'"
    )
    let secured = try McpSecureDocument(html: "<p>producer contract</p>", grants: grants)
    #expect(throws: McpSecureDocument.Rejection.self) {
      try McpSecureDocument(validatingNoGrants: secured.html)
    }
  }

  // Web mcp-app-document.ts:44–47: replacements are ordered, body is not escaped.
  @Test func attributeEscapingGolden() throws {
    #expect(McpSecureDocument.escapedAttribute("&\"<>&amp;") == "&amp;&quot;&lt;>&amp;amp;")
    #expect(try McpSecureDocument(html: "<p>&\"</p>").html.hasSuffix("<p>&\"</p>"))
  }

  // Web mcp-app-proxy.test.ts:284–318: cap is secured UTF-8, not JSON-escaped bytes.
  @Test func escapingHeavyExactByteCap() throws {
    let prefix = try McpSecureDocument(html: "").html
    let remaining = McpSecureDocument.maximumBytes - prefix.utf8.count
    let pattern = "\"\\\n\t"
    let body =
      String(repeating: pattern, count: remaining / 4)
      + String(repeating: "x", count: remaining % 4)
    let secured = try McpSecureDocument(html: body)
    #expect(secured.html.utf8.count == McpSecureDocument.maximumBytes)
    #expect(try JSONEncoder().encode(secured.html).count > McpSecureDocument.maximumBytes + 65536)
    #expect(try McpSecureDocument(validatingNoGrants: secured.html).html == secured.html)
    #expect(throws: McpSecureDocument.Rejection.self) { try McpSecureDocument(html: body + "x") }
    let unicode =
      String(repeating: "🌱", count: remaining / 4)
      + String(repeating: "x", count: remaining % 4)
    #expect(try McpSecureDocument(html: unicode).html.utf8.count == McpSecureDocument.maximumBytes)
    #expect(throws: McpSecureDocument.Rejection.self) { try McpSecureDocument(html: unicode + "x") }
  }

  // Web mcp-app-proxy.test.ts:398–430: all eight rejection vectors.
  @Test func rejectsNoncanonicalPrefixes() throws {
    let canonical = try McpSecureDocument(html: "<p>safe</p>").html
    let invalid = [
      "<p>raw app HTML</p>",
      canonical.replacingOccurrences(
        of: "<meta http-equiv=\"Content-Security-Policy\"", with: "<meta name=\"not-csp\""),
      canonical.replacingOccurrences(
        of: "<!doctype html><head>", with: "<!doctype html><head><title>before policy</title>"),
      canonical.replacingOccurrences(
        of: "<meta http-equiv=\"Content-Security-Policy\"",
        with: "<META  HTTP-EQUIV = \"Content-Security-Policy\""),
      canonical.replacingOccurrences(of: "default-src 'none'", with: "default-src *"),
      canonical.replacingOccurrences(
        of: "connect-src 'none'", with: "connect-src https://example.com/path"),
      "\n" + canonical,
      try McpSecureDocument(html: "").html
        + String(repeating: "x", count: McpSecureDocument.maximumBytes),
    ]
    for html in invalid {
      #expect(throws: McpSecureDocument.Rejection.self) {
        try McpSecureDocument(validatingNoGrants: html)
      }
    }
  }
}
