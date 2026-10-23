// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ReplyPartReference: Sendable, Hashable {
  public let threadId: String
  public let messageId: String
  public let partId: String
  public init(threadId: String, messageId: String, partId: String) {
    self.threadId = threadId
    self.messageId = messageId
    self.partId = partId
  }
  var parameters: [String: String] {
    ["threadId": threadId, "messageId": messageId, "partId": partId]
  }
}
public enum CapabilityError: Error, Sendable, Equatable { case invalidURL, missingURL }
extension RequestBuilder {
  /// Server capabilities are root-relative and bound to this exact part/namespace.
  /// No capability is ever resolved relative to an arbitrary URL or proxy prefix.
  public func capabilityQuery(_ value: String, route: APIRoute, reference: ReplyPartReference)
    throws -> ApiCapabilityQuery
  {
    guard value.hasPrefix("/api/v1/threads/"), !value.hasPrefix("//"), !value.contains("\\"),
      let components = URLComponents(string: value), components.scheme == nil,
      components.host == nil,
      components.fragment == nil,
      let expected = try request(route: route.descriptor, parameters: reference.parameters).url,
      let actual = URL(string: value, relativeTo: endpoint.url)?.absoluteURL,
      actual.scheme == endpoint.url.scheme, actual.host == endpoint.url.host,
      actual.port == endpoint.url.port,
      components.percentEncodedPath.split(separator: "/").map({ String($0).removingPercentEncoding }
      )
        == URLComponents(url: expected, resolvingAgainstBaseURL: false)?.percentEncodedPath.split(
          separator: "/"
        ).map({ String($0).removingPercentEncoding })
    else { throw CapabilityError.invalidURL }
    let items = components.queryItems ?? []
    guard items.count == 2, items.filter({ $0.name == "expires" }).count == 1,
      items.filter({ $0.name == "token" }).count == 1,
      let expires = items.first(where: { $0.name == "expires" })?.value, !expires.isEmpty,
      let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
    else { throw CapabilityError.invalidURL }
    return .init(expires: expires, token: token)
  }
}
public actor CapabilityService {
  let api: any ConsoleAPI
  let builder: RequestBuilder
  public init(endpoint: ConsoleEndpoint, api: any ConsoleAPI) {
    self.api = api
    builder = RequestBuilder(endpoint: endpoint)
  }
  public func attachment(_ part: ReplyAttachmentPart, reference: ReplyPartReference) async throws
    -> Data
  {
    if let stored = part.storedUrl {
      guard let components = URLComponents(string: stored), components.scheme == nil,
        components.host == nil, components.query == nil, components.fragment == nil,
        !stored.contains("\\"), stored.hasPrefix("/api/v1/uploads/"), stored.hasSuffix("/content")
      else { throw CapabilityError.invalidURL }
      let segments = components.percentEncodedPath.split(separator: "/")
      guard segments.count == 5, let id = String(segments[3]).removingPercentEncoding,
        id != ".", id != "..", !id.contains("/"), !id.isEmpty
      else { throw CapabilityError.invalidURL }
      return try await api.stagedContent(id: id)
    }
    guard let url = part.contentUrl else { throw CapabilityError.missingURL }
    let query = try builder.capabilityQuery(url, route: .attachmentContent, reference: reference)
    do {
      return try await api.attachmentContent(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query)
    } catch let error as APIError where error.code == "reply_access_expired" {
      let renewed = try await api.attachmentAccess(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId)
      guard let url = renewed.part.contentUrl else { throw CapabilityError.missingURL }
      let query = try builder.capabilityQuery(url, route: .attachmentContent, reference: reference)
      return try await api.attachmentContent(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query)
    }
  }
  public func mcpResource(_ part: McpAppPart, reference: ReplyPartReference) async throws
    -> ApiMcpAppResource
  {
    try await loadMcpApp(part, reference: reference).resource
  }

  /// Compatibility entry point. Only resources/read is automatically renewed/retried.
  public func mcpRequest(_ body: ApiMcpAppRequest, part: McpAppPart, reference: ReplyPartReference)
    async throws -> ApiMcpAppResult
  {
    try await requestMcpApp(body, published: part, access: part, reference: reference).result
  }
}
