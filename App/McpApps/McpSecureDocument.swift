// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Port of the web secured-document producer. Grants must already be intersected by the host.
/// PR0 hosts grant no domains; server metadata is never passed to this builder directly.
struct McpSecureDocument: Sendable {
  static let maximumBytes = 2 * 1024 * 1024

  struct Grants: Sendable {
    var connectDomains: [String] = []
    var resourceDomains: [String] = []
    var frameDomains: [String] = []
    var baseUriDomains: [String] = []
  }

  enum Rejection: Error { case tooLarge, noncanonical }

  let html: String

  static func contentSecurityPolicy(_ grants: Grants = Grants()) -> String {
    func sources(_ domains: [String], extras: [String] = []) -> String {
      let values = extras + domains
      return values.isEmpty ? "'none'" : values.joined(separator: " ")
    }
    let resources = grants.resourceDomains
    return [
      "default-src 'none'", "script-src 'unsafe-inline'",
      "style-src " + sources(resources, extras: ["'unsafe-inline'"]),
      "img-src " + sources(resources, extras: ["data:", "blob:"]),
      "font-src " + sources(resources, extras: ["data:"]),
      "media-src " + sources(resources, extras: ["blob:"]),
      "connect-src " + sources(grants.connectDomains),
      "frame-src " + sources(grants.frameDomains),
      "base-uri " + sources(grants.baseUriDomains),
      "form-action 'none'", "object-src 'none'", "child-src 'none'",
      "worker-src 'none'", "manifest-src 'none'", "navigate-to 'none'", "webrtc 'block'",
    ].joined(separator: "; ")
  }

  static func escapedAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
  }

  private static func prefix(_ grants: Grants) -> String {
    "<!doctype html><head><meta http-equiv=\"Content-Security-Policy\" content=\""
      + escapedAttribute(contentSecurityPolicy(grants))
      + "\"><meta name=\"referrer\" content=\"no-referrer\"></head>"
  }

  init(html: String, grants: Grants = Grants()) throws {
    let secured = Self.prefix(grants) + html
    guard secured.utf8.count <= Self.maximumBytes else { throw Rejection.tooLarge }
    self.html = secured
  }

  /// The host accepts only the canonical *no-grants* policy, not an HTML approximation.
  init(validatingNoGrants html: String) throws {
    guard html.utf8.count <= Self.maximumBytes else { throw Rejection.tooLarge }
    guard html.hasPrefix(Self.prefix(Grants())) else { throw Rejection.noncanonical }
    self.html = html
  }
}
