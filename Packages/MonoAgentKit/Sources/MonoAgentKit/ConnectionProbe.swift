// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct HTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let contentType: String
  public let headers: [String: String]
  public init(
    data: Data, status: Int = 200, contentType: String = "application/json",
    headers: [String: String] = [:]
  ) {
    self.data = data
    self.status = status
    self.contentType = contentType
    self.headers = Dictionary(
      headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Keep endpoint identity stable. In particular, never follow a downgrade or off-origin hop.
    completionHandler(nil)
  }
}

public actor URLSessionTransport: FileUploadTransport {
  private let session: URLSession
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    let config = configuration
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }

  public func upload(
    _ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> HTTPResponse {
    let (data, response) = try await session.upload(
      for: request, fromFile: file, delegate: UploadProgressDelegate(progress: progress))
    guard let response = response as? HTTPURLResponse else { throw ProbeError.connectivity }
    return HTTPResponse(
      data: data, status: response.statusCode,
      contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
      headers: response.allHeaderFields.reduce(into: [:]) {
        if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
      })
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ProbeError.connectivity }
    return HTTPResponse(
      data: data, status: response.statusCode,
      contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
      headers: response.allHeaderFields.reduce(into: [:]) {
        if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
      }
    )
  }
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
      "The console only accepts known hostnames. Add this name with MONO_AGENT_WEB_ALLOWED_HOSTS on the console host, or use its LAN or Tailscale IP address or Tailscale Serve URL."
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
      let client = APIClient(endpoint: endpoint, transport: transport)
      let health = try await client.health().valueRequired()
      guard health.version == 1 else { throw ProbeError.unsupportedVersion(health.version) }
      guard health.status == "ok" else { throw ProbeError.unhealthy }
      let bootstrap = try await client.bootstrap(query: .init()).valueRequired()
      guard bootstrap.version == 1 else {
        throw ProbeError.unsupportedVersion(bootstrap.version)
      }
      guard !bootstrap.console.hostName.isEmpty, !bootstrap.console.displayName.isEmpty else {
        throw ProbeError.invalidResponse
      }
      return bootstrap.console
    } catch APIVersionError.unsupported(let version) {
      throw ProbeError.unsupportedVersion(version)
    } catch let error as APIError {
      if error.status == 421 && error.code == "untrusted_host" { throw ProbeError.untrustedHost }
      if error.code == "non_json" { throw ProbeError.nonJSON }
      if error.code == "invalid_response" { throw ProbeError.invalidResponse }
      if (300...399).contains(error.status) { throw ProbeError.redirect }
      throw ProbeError.http(error.status)
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

}
