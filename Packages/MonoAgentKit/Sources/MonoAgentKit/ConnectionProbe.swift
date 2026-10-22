// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct HTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let contentType: String
  public init(data: Data, status: Int = 200, contentType: String = "application/json") {
    self.data = data
    self.status = status
    self.contentType = contentType
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Keep endpoint identity stable. In particular, never follow a downgrade or off-origin hop.
    completionHandler(nil)
  }
}

public actor URLSessionTransport: HTTPTransport {
  private let session: URLSession
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ProbeError.connectivity }
    return HTTPResponse(
      data: data, status: response.statusCode,
      contentType: response.value(forHTTPHeaderField: "Content-Type") ?? ""
    )
  }
}

// Provisional connection-only projections of API v1. C3 expands these, not a parallel client.
public struct HealthResponse: Codable, Sendable {
  public let status: String
  public let version: Int
}

public struct ConsoleIdentity: Codable, Sendable, Equatable {
  public let hostName: String
  public let displayName: String
  public let theme: String
  public init(hostName: String, displayName: String, theme: String) {
    self.hostName = hostName
    self.displayName = displayName
    self.theme = theme
  }
}

public struct BootstrapResponse: Codable, Sendable {
  public let version: Int
  public let console: ConsoleIdentity
}

public enum ProbeError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedVersion(Int)
  case unhealthy
  case nonJSON
  case invalidResponse
  case untrustedHost
  case http(Int)
  case redirect
  case timeout
  case tls
  case connectivity

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "This console uses API version \(version); this app supports version 1. Update the app or console."
    case .unhealthy: "The console is not healthy. Check it on the console host and retry."
    case .nonJSON:
      "The server returned a non-JSON page. Check the URL and reverse-proxy configuration; browser login pages are not supported."
    case .invalidResponse: "The JSON response is not a compatible console response."
    case .untrustedHost:
      "The console only accepts known hostnames. Add this name with MONO_AGENT_WEB_ALLOWED_HOSTS on the console host, or use its IP address or Tailscale Serve URL."
    case .http(let status): "The console returned HTTP \(status). Check the server and retry."
    case .redirect:
      "The URL redirects. Enter the console's final root URL directly; redirects are not followed."
    case .timeout: "The console timed out. Check its address and network, then retry."
    case .tls:
      "The TLS certificate could not be trusted. Fix the certificate or hostname; certificate checks cannot be disabled."
    case .connectivity:
      "Could not reach the console. Check the address and network. For LAN access, check Local Network permission in Settings and retry. Loopback on a phone refers to the phone, not your computer."
    }
  }
}

public struct ConnectionProbe: Sendable {
  private let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }

  public func probe(_ endpoint: ConsoleEndpoint) async throws -> ConsoleIdentity {
    do {
      let builder = RequestBuilder(endpoint: endpoint)
      let health: HealthResponse = try await read(builder.get(.health))
      guard health.version == 1 else { throw ProbeError.unsupportedVersion(health.version) }
      guard health.status == "ok" else { throw ProbeError.unhealthy }
      let bootstrap: BootstrapResponse = try await read(builder.get(.bootstrap))
      guard bootstrap.version == 1 else {
        throw ProbeError.unsupportedVersion(bootstrap.version)
      }
      guard !bootstrap.console.hostName.isEmpty, !bootstrap.console.displayName.isEmpty else {
        throw ProbeError.invalidResponse
      }
      return bootstrap.console
    } catch let error as ProbeError { throw error } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError {
      switch error.code {
      case .cancelled: throw CancellationError()
      case .timedOut: throw ProbeError.timeout
      case .secureConnectionFailed, .serverCertificateHasBadDate,
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired:
        throw ProbeError.tls
      default: throw ProbeError.connectivity
      }
    } catch { throw ProbeError.connectivity }
  }

  private func read<T: Decodable>(_ request: URLRequest) async throws -> T {
    let response = try await transport.send(request)
    if response.status == 421 { throw ProbeError.untrustedHost }
    if (300...399).contains(response.status) { throw ProbeError.redirect }
    guard (200...299).contains(response.status) else { throw ProbeError.http(response.status) }
    guard
      response.contentType.lowercased().split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces) == "application/json"
    else { throw ProbeError.nonJSON }
    do { return try JSONDecoder().decode(T.self, from: response.data) } catch {
      throw ProbeError.invalidResponse
    }
  }
}
