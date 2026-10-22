// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network

public struct ConsoleEndpoint: Hashable, Sendable, Codable {
  public let origin: String
  public var url: URL { URL(string: origin)! }
  public var isInsecure: Bool { url.scheme == "http" }

  public init(_ input: String) throws {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var parts = URLComponents(string: text),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty,
      !host.contains("%"), !host.contains(where: { $0.isWhitespace }),
      parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else { throw EndpointError.invalid }
    var normalizedHost = host.lowercased()
    if normalizedHost.hasSuffix(".") { normalizedHost.removeLast() }
    guard !normalizedHost.isEmpty, !normalizedHost.hasSuffix(".") else {
      throw EndpointError.invalid
    }
    if normalizedHost.contains(":") {
      let address = normalizedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      guard IPv6Address(address) != nil else { throw EndpointError.invalid }
    }
    parts.scheme = scheme
    parts.host = normalizedHost
    parts.path = ""
    if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
      parts.port = nil
    }
    guard let url = parts.url, let normalized = parts.string,
      url.host != nil, !normalized.contains("\\")
    else { throw EndpointError.invalid }
    origin = url.absoluteString
  }

  /// Local here is only an HTTP-confirmation heuristic, never a trust assertion.
  public var isLocalHost: Bool {
    let host = (url.host ?? "").lowercased().trimmingCharacters(
      in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
      return true
    }
    if let address = IPv6Address(host) {
      let bytes = Array(address.rawValue)
      return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        || bytes[0] & 0xfe == 0xfc
        || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    }
    // Only canonical dotted decimal is an IPv4 literal. Never discard DNS labels or
    // interpret octal/hex/short forms as decimal when deciding to skip confirmation.
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count == 4 else { return false }
    var bytes: [UInt8] = []
    for label in labels {
      guard let byte = UInt8(label), String(byte) == label else { return false }
      bytes.append(byte)
    }
    return bytes[0] == 127 || bytes[0] == 10
      || (bytes[0] == 172 && (16...31).contains(bytes[1]))
      || (bytes[0] == 192 && bytes[1] == 168)
      || (bytes[0] == 169 && bytes[1] == 254)
      || (bytes[0] == 100 && (64...127).contains(bytes[1]))
  }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    try self.init(value)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(origin)
  }
}

public enum EndpointError: Error, LocalizedError {
  case invalid
  public var errorDescription: String? {
    "Enter an http:// or https:// URL with only a hostname or IP and optional port. A trailing slash is allowed; paths, credentials, queries and fragments are not."
  }
}

public struct RequestBuilder: Sendable {
  public let endpoint: ConsoleEndpoint
  public init(endpoint: ConsoleEndpoint) { self.endpoint = endpoint }

  public func get(_ route: ConsoleRoute, claimingOrigin: Bool = false) -> URLRequest {
    var request = URLRequest(url: endpoint.url.appendingPathComponent(route.rawValue))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // C3 enables this only for manifest-marked routes. The URL and claim share an authority.
    // Never accept an arbitrary off-origin request here and never override Host.
    if claimingOrigin {
      request.setValue(endpoint.origin, forHTTPHeaderField: "X-Mono-Agent-Web-Origin")
    }
    return request
  }
}

public enum ConsoleRoute: String, Sendable {
  case health = "healthz"
  case bootstrap = "api/v1/bootstrap"
}
