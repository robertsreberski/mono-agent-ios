// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum McpAppAccessError: Error, Sendable, Equatable {
  case identityMismatch, unsupportedMethod
}

extension McpAppPart {
  /// Publication identity excludes only the renewable capability URLs.
  public func hasSameMcpIdentity(as other: McpAppPart) -> Bool {
    var left = self
    var right = other
    left.resourceUrl = nil
    left.bridgeUrl = nil
    right.resourceUrl = nil
    right.bridgeUrl = nil
    return left == right
  }
}

/// Memory-only load; callers must not persist either member or expose access to WebKit.
public struct McpAppLoad: Sendable {
  public let resource: ApiMcpAppResource
  public let access: McpAppPart
}
public struct McpAppReply: Sendable {
  public let result: ApiMcpAppResult
  public let access: McpAppPart
}

extension CapabilityService {
  public func renewMcpAppAccess(_ published: McpAppPart, reference: ReplyPartReference) async throws
    -> McpAppPart
  {
    try Task.checkCancellation()
    let access = try await api.mcpAppAccess(
      threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId
    ).part
    try Task.checkCancellation()
    _ = try validatedMcpAccess(access, published: published, reference: reference)
    return access
  }

  public func loadMcpApp(
    _ published: McpAppPart, currentAccess: McpAppPart? = nil, reference: ReplyPartReference
  ) async throws -> McpAppLoad {
    try Task.checkCancellation()
    var access: McpAppPart
    if let currentAccess {
      access = currentAccess
    } else if published.resourceUrl != nil && published.bridgeUrl != nil {
      access = published
    } else {
      access = try await renewMcpAppAccess(published, reference: reference)
    }
    var query = try validatedMcpAccess(access, published: published, reference: reference).resource
    let resource: ApiMcpAppResource
    do {
      resource = try await api.mcpAppResource(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query, etag: nil
      ).valueRequired()
    } catch let error as APIError where error.code == "reply_access_expired" {
      try Task.checkCancellation()
      access = try await renewMcpAppAccess(published, reference: reference)
      query = try validatedMcpAccess(access, published: published, reference: reference).resource
      resource = try await api.mcpAppResource(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query, etag: nil
      ).valueRequired()
    }
    try Task.checkCancellation()
    guard resource.app.hasSameMcpIdentity(as: published) else {
      throw McpAppAccessError.identityMismatch
    }
    return McpAppLoad(resource: resource, access: access)
  }

  public func requestMcpApp(
    _ body: ApiMcpAppRequest, published: McpAppPart, access: McpAppPart,
    reference: ReplyPartReference
  ) async throws -> McpAppReply {
    guard
      ["resources/read", "tools/call", "ui/open-link", "ui/update-model-context"].contains(
        body.method)
    else { throw McpAppAccessError.unsupportedMethod }
    try Task.checkCancellation()
    let query = try validatedMcpAccess(access, published: published, reference: reference).bridge
    do {
      let result = try await api.mcpAppRequest(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query, body: body)
      try Task.checkCancellation()
      return McpAppReply(result: result, access: access)
    } catch let error as APIError
      where body.method == "resources/read" && error.code == "reply_access_expired"
    {
      let renewed = try await renewMcpAppAccess(published, reference: reference)
      let query = try validatedMcpAccess(renewed, published: published, reference: reference).bridge
      let result = try await api.mcpAppRequest(
        threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId,
        query: query, body: body)
      try Task.checkCancellation()
      return McpAppReply(result: result, access: renewed)
    }
  }

  private func validatedMcpAccess(
    _ access: McpAppPart, published: McpAppPart, reference: ReplyPartReference
  ) throws -> (resource: ApiCapabilityQuery, bridge: ApiCapabilityQuery) {
    guard published.type == "mcp_app", published.id == reference.partId,
      access.hasSameMcpIdentity(as: published)
    else { throw McpAppAccessError.identityMismatch }
    guard let resource = access.resourceUrl, let bridge = access.bridgeUrl else {
      throw CapabilityError.missingURL
    }
    let resourceQuery = try builder.capabilityQuery(
      resource, route: .mcpAppResource, reference: reference)
    let bridgeQuery = try builder.capabilityQuery(
      bridge, route: .mcpAppRequest, reference: reference)
    guard resourceQuery.expires == bridgeQuery.expires, resourceQuery.token == bridgeQuery.token
    else {
      throw CapabilityError.invalidURL
    }
    return (resourceQuery, bridgeQuery)
  }
}
