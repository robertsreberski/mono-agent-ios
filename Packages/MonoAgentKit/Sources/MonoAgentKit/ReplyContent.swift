// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ReplyContentError: Error, Sendable, Equatable {
  case tooLarge, integrity, unavailable
}

/// Supplemental binary seam: retain headers for validation without exposing capability URLs to UI.
public protocol ReplyContentReading: Sendable {
  func uploadContent(id: String, maximumBytes: Int) async throws -> HTTPResponse
  func replyContent(
    reference: ReplyPartReference, query: ApiCapabilityQuery?, storedID: String?, maximumBytes: Int
  ) async throws -> HTTPResponse
}

extension APIClient {
  public func uploadContent(id: String, maximumBytes: Int) async throws -> HTTPResponse {
    let request = try request(.stagedContent, parameters: ["id": id], query: nil, body: nil)
    let response: HTTPResponse
    do {
      response = try await transport.send(request, maximumBytes: maximumBytes)
    } catch is CancellationError { throw CancellationError() } catch let error as ReplyContentError
    { throw error } catch { throw APIError(status: 0, code: "transport_failed") }
    guard APIRoute.stagedContent.descriptor.successStatus.contains(response.status) else {
      throw APIError.response(response)
    }
    return response
  }
  public func replyContent(
    reference: ReplyPartReference, query: ApiCapabilityQuery?, storedID: String?, maximumBytes: Int
  ) async throws -> HTTPResponse {
    let route: APIRoute = storedID == nil ? .attachmentContent : .stagedContent
    let parameters = storedID.map { ["id": $0] } ?? reference.parameters
    let request = try request(route, parameters: parameters, query: query, body: nil)
    let response: HTTPResponse
    do {
      response = try await transport.send(request, maximumBytes: maximumBytes)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ReplyContentError {
      throw error
    } catch {
      throw APIError(status: 0, code: "transport_failed")
    }
    guard route.descriptor.successStatus.contains(response.status) else {
      throw APIError.response(response)
    }
    return response
  }
}

extension ReplyAttachmentPart {
  /// Credentials are deliberately excluded: re-projection must not invalidate the bytes.
  public func hasSameFile(as other: Self) -> Bool {
    id == other.id && artifactId == other.artifactId && name == other.name
      && mediaType == other.mediaType && sizeBytes == other.sizeBytes
      && integrityId == other.integrityId && expiresAt == other.expiresAt
  }
  public var isReplyImage: Bool {
    ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mediaType.lowercased())
  }
}

extension CapabilityService {
  /// Fresh access for restored transcripts; renew at most once, only for access expiry.
  /// All returned metadata must still describe the exact file the user requested.
  public func downloadAttachment(
    _ part: ReplyAttachmentPart, reference: ReplyPartReference, maximumBytes: Int = 32 * 1024 * 1024
  ) async throws -> Data {
    guard part.sizeBytes >= 0, part.sizeBytes <= maximumBytes else {
      throw ReplyContentError.tooLarge
    }
    try Task.checkCancellation()
    if let stored = part.storedUrl {
      let id = try storedAttachmentID(stored)
      let response = try await api.replyContent(
        reference: reference, query: nil, storedID: id, maximumBytes: maximumBytes)
      try Task.checkCancellation()
      return try validate(response, part: part, capability: false)
    }
    var current = part
    if current.contentUrl == nil { current = try await renew(part, reference: reference) }
    for attempt in 0...1 {
      guard let url = current.contentUrl else { throw ReplyContentError.unavailable }
      let query = try builder.capabilityQuery(url, route: .attachmentContent, reference: reference)
      do {
        let response = try await api.replyContent(
          reference: reference, query: query, storedID: nil, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return try validate(response, part: part, capability: true)
      } catch let error as APIError where error.code == "reply_access_expired" && attempt == 0 {
        current = try await renew(part, reference: reference)
      }
    }
    throw ReplyContentError.unavailable
  }

  private func renew(_ part: ReplyAttachmentPart, reference: ReplyPartReference) async throws
    -> ReplyAttachmentPart
  {
    try Task.checkCancellation()
    let renewed = try await api.attachmentAccess(
      threadId: reference.threadId, messageId: reference.messageId, partId: reference.partId
    ).part
    try Task.checkCancellation()
    guard part.hasSameFile(as: renewed) else { throw ReplyContentError.integrity }
    return renewed
  }
  private func validate(_ response: HTTPResponse, part: ReplyAttachmentPart, capability: Bool)
    throws
    -> Data
  {
    guard response.data.count == part.sizeBytes,
      response.headers["content-length"].map({ Int($0) == part.sizeBytes }) ?? true,
      !capability || response.headers["x-mono-agent-integrity-id"] == part.integrityId
    else { throw ReplyContentError.integrity }
    return response.data
  }
  private func storedAttachmentID(_ value: String) throws -> String {
    guard let components = URLComponents(string: value), components.scheme == nil,
      components.host == nil, components.query == nil, components.fragment == nil,
      !value.contains("\\"), value.hasPrefix("/api/v1/uploads/"), value.hasSuffix("/content")
    else { throw CapabilityError.invalidURL }
    let segments = components.percentEncodedPath.split(separator: "/")
    guard segments.count == 5, let id = String(segments[3]).removingPercentEncoding,
      id != ".", id != "..", !id.contains("/"), !id.isEmpty
    else { throw CapabilityError.invalidURL }
    return id
  }
}

/// Sent uploads use the authenticated durable upload route, never a DTO-provided URL.
extension ReplyContentReading {
  public func downloadUpload(_ attachment: WebAttachment, maximumBytes: Int = 32 * 1024 * 1024)
    async throws -> Data
  {
    guard attachment.uploaded, attachment.status == "committed", !attachment.id.isEmpty else {
      throw ReplyContentError.unavailable
    }
    guard attachment.sizeBytes >= 0, attachment.sizeBytes <= maximumBytes else {
      throw ReplyContentError.tooLarge
    }
    try Task.checkCancellation()
    let response = try await uploadContent(id: attachment.id, maximumBytes: maximumBytes)
    try Task.checkCancellation()
    guard response.data.count == attachment.sizeBytes,
      response.headers["content-length"].map({ Int($0) == attachment.sizeBytes }) ?? true
    else { throw ReplyContentError.integrity }
    return response.data
  }
}
extension WebAttachment {
  public var isUploadedImage: Bool {
    kind == "image"
      && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(contentType.lowercased())
  }
  public func hasSameFile(as other: Self) -> Bool {
    id == other.id && name == other.name && contentType == other.contentType
      && sizeBytes == other.sizeBytes
      && kind == other.kind && status == other.status && uploaded == other.uploaded
      && createdAt == other.createdAt
  }
}
