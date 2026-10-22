// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ReadResult<Value: Sendable>: Sendable {
  case modified(Value, etag: String?)
  case notModified
  public func valueRequired() throws -> Value {
    guard case .modified(let value, _) = self else {
      throw APIError(status: 304, code: "unexpected_not_modified")
    }
    return value
  }
}
public enum APIVersionError: Error, Sendable, Equatable { case unsupported(Int) }
public enum RetryClass: String, Sendable {
  case never, reconcile, transient, throttled, configuration
}
public struct APIError: Error, LocalizedError, Sendable, Equatable {
  public let status: Int
  public let code: String
  /// Allowlisted, locally generated details only. Server prose can contain secrets.
  public let safeDetails: String
  public let retryClass: RetryClass
  public let retryAfter: String?
  public init(status: Int, code: String, retryAfter: String? = nil) {
    self.status = status
    self.code =
      code.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) == nil
      ? "server_error" : code
    self.retryAfter = retryAfter
    safeDetails =
      status == 421 && code == "untrusted_host"
      ? "Console hostname is not allowed; configure MONO_AGENT_WEB_ALLOWED_HOSTS on the console host."
      : "Console request failed (HTTP \(status))."
    switch status {
    case 421, 401, 403: retryClass = .configuration
    case 409, 412, 428: retryClass = .reconcile
    case 429: retryClass = .throttled
    case 500...599: retryClass = .transient
    default: retryClass = .never
    }
  }
  public var errorDescription: String? { safeDetails }
  static func response(_ response: HTTPResponse) -> APIError {
    let body = try? JSONDecoder().decode(ApiErrorBody.self, from: response.data)
    var code = "http_error"
    if case .coded(let value, _) = body?.error { code = value }
    return .init(status: response.status, code: code, retryAfter: response.headers["retry-after"])
  }
}
public struct RouteDescriptor: Sendable {
  public let method: String
  public let path: String
  public let requestType: String
  public let responseType: String
  public let successStatus: [Int]
  public let resultStatuses: [Int]
  public let requiresClaimedOrigin: Bool
  public let originPolicy: String
}

extension RequestBuilder {
  public func request(
    route: RouteDescriptor, parameters: [String: String] = [:], query: [String: String] = [:]
  ) throws -> URLRequest {
    let components = try route.path.split(separator: "/").map { segment -> String in
      guard segment.hasPrefix(":") else { return String(segment) }
      guard let value = parameters[String(segment.dropFirst())], !value.isEmpty, value != ".",
        value != "..",
        let encoded = value.addingPercentEncoding(
          withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
      else { throw EndpointError.invalid }
      return encoded
    }
    var url = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
    url.percentEncodedPath = "/" + components.joined(separator: "/")
    if !query.isEmpty {
      url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
    }
    var request = get(.health)
    request.url = url.url!
    request.httpMethod = route.method
    return request
  }
}

public actor APIClient: ConsoleAPI {
  public let endpoint: ConsoleEndpoint
  let transport: any HTTPTransport
  let builder: RequestBuilder
  public init(endpoint: ConsoleEndpoint, transport: any HTTPTransport = URLSessionTransport()) {
    self.endpoint = endpoint
    self.transport = transport
    builder = RequestBuilder(endpoint: endpoint)
  }
  func request(
    _ route: APIRoute, parameters: [String: String], query: (any Encodable & Sendable)?,
    body: (any Encodable & Sendable)?
  ) throws -> URLRequest {
    var values: [String: String] = [:]
    if let query {
      let data = try JSONEncoder().encode(query)
      let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
      for (key, value) in object {
        switch value {
        case .string(let v): values[key] = v
        case .bool(let v): values[key] = v ? "true" : "false"
        case .number(let v): values[key] = v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: throw EndpointError.invalid
        }
      }
    }
    var request = try builder.request(
      route: route.descriptor, parameters: parameters, query: values)
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
  private func perform(_ request: URLRequest) async throws -> HTTPResponse {
    do { return try await transport.send(request) } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError { throw URLError(error.code) } catch {
      throw APIError(status: 0, code: "transport_failed")
    }
  }
  func read<T: Decodable & Sendable>(
    _ route: APIRoute, parameters: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
    etag: String? = nil
  ) async throws -> ReadResult<T> {
    var request = try request(route, parameters: parameters, query: query, body: nil)
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let response = try await perform(request)
    if response.status == 304 {
      guard etag != nil else { throw APIError(status: 304, code: "unexpected_not_modified") }
      return .notModified
    }
    return .modified(try decode(response, route: route), etag: response.headers["etag"])
  }
  func send<T: Decodable & Sendable>(
    _ route: APIRoute, parameters: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
    body: (any Encodable & Sendable)? = nil
  ) async throws -> T {
    let response = try await perform(
      request(route, parameters: parameters, query: query, body: body))
    return try decode(response, route: route)
  }
  func noContent(
    _ route: APIRoute, parameters: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
    body: (any Encodable & Sendable)? = nil
  ) async throws {
    let response = try await perform(
      request(route, parameters: parameters, query: query, body: body))
    guard route.descriptor.successStatus.contains(response.status), response.data.isEmpty else {
      throw APIError.response(response)
    }
  }
  func binary(
    _ route: APIRoute, parameters: [String: String] = [:], query: (any Encodable & Sendable)? = nil
  ) async throws -> Data {
    let response = try await perform(
      request(route, parameters: parameters, query: query, body: nil))
    guard route.descriptor.successStatus.contains(response.status) else {
      throw APIError.response(response)
    }
    return response.data
  }
  func decode<T: Decodable>(_ response: HTTPResponse, route: APIRoute) throws -> T {
    let d = route.descriptor
    guard (d.successStatus + d.resultStatuses).contains(response.status) else {
      throw APIError.response(response)
    }
    guard
      response.contentType.lowercased().split(separator: ";").first?.trimmingCharacters(
        in: .whitespaces) == "application/json"
    else { throw APIError(status: response.status, code: "non_json") }
    if route == .health || route == .bootstrap {
      if let version = try? JSONDecoder().decode(APIVersionHeader.self, from: response.data)
        .version, version != 1
      {
        throw APIVersionError.unsupported(version)
      }
    }
    do { return try JSONDecoder().decode(T.self, from: response.data) } catch {
      if !d.successStatus.contains(response.status) { throw APIError.response(response) }
      throw APIError(status: response.status, code: "invalid_response")
    }
  }
}

private struct APIVersionHeader: Decodable { let version: Int }
