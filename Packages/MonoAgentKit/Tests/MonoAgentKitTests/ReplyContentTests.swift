// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgentKit

private actor ReplyScript: HTTPTransport {
  var replies: [HTTPResponse]
  var requests: [URLRequest] = []
  init(_ replies: [HTTPResponse]) { self.replies = replies }
  func send(_ request: URLRequest) throws -> HTTPResponse {
    try Task.checkCancellation()
    requests.append(request)
    guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
    return replies.removeFirst()
  }
}
private let replyReference = ReplyPartReference(
  threadId: "thread", messageId: "message", partId: "file")
private func filePart() throws -> ReplyAttachmentPart {
  try JSONDecoder().decode(
    ReplyAttachmentPart.self,
    from: Data(
      #"{"type":"attachment","id":"file","artifactId":"artifact","name":"report.txt","mediaType":"text/plain","sizeBytes":3,"integrityId":"digest"}"#
        .utf8))
}
private func access(_ part: ReplyAttachmentPart) throws -> HTTPResponse {
  .init(data: try JSONEncoder().encode(ApiAttachmentAccess(part: part)))
}
private func authorizedPart() throws -> ReplyAttachmentPart {
  var part = try filePart()
  part.contentUrl =
    "/api/v1/threads/thread/messages/message/reply-attachments/file/content?expires=1&token=fictional"
  return part
}
private func bytes(_ value: String = "abc", integrity: String = "digest") -> HTTPResponse {
  .init(
    data: Data(value.utf8), contentType: "text/plain",
    headers: ["x-mono-agent-integrity-id": integrity])
}
@Test func restoredFileMintsAccessAndExpiredReadRenewsOnlyOnce() async throws {
  let expired = HTTPResponse(
    data: Data(#"{"error":{"code":"reply_access_expired","message":"Expired"}}"#.utf8), status: 401)
  let script = ReplyScript([
    try access(authorizedPart()), expired, try access(authorizedPart()), bytes(),
  ])
  let service = CapabilityService(
    endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: script))
  #expect(
    try await service.downloadAttachment(filePart(), reference: replyReference) == Data("abc".utf8))
  #expect(await script.requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET"])
  let twice = ReplyScript([expired, try access(authorizedPart()), expired])
  await #expect(throws: APIError.self) {
    try await CapabilityService(
      endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: twice)
    )
    .downloadAttachment(authorizedPart(), reference: replyReference)
  }
  #expect(await twice.requests.count == 3)
}
@Test func replyContentRefusesChangedIdentityInvalidCapabilitySizeAndIntegrity() async throws {
  var changed = try authorizedPart()
  changed.artifactId = "different"
  let mismatch = ReplyScript([try access(changed)])
  await #expect(throws: ReplyContentError.integrity) {
    try await CapabilityService(
      endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: mismatch)
    )
    .downloadAttachment(filePart(), reference: replyReference)
  }
  let script = ReplyScript([bytes("abc", integrity: "wrong"), bytes("abcd"), bytes("ab")])
  let service = CapabilityService(
    endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: script))
  for _ in 0..<3 {
    await #expect(throws: ReplyContentError.integrity) {
      try await service.downloadAttachment(authorizedPart(), reference: replyReference)
    }
  }
  var invalid = try authorizedPart()
  invalid.contentUrl = "https://untrusted.example/content?token=fictional"
  await #expect(throws: CapabilityError.invalidURL) {
    try await service.downloadAttachment(invalid, reference: replyReference)
  }
  await #expect(throws: ReplyContentError.tooLarge) {
    try await service.downloadAttachment(filePart(), reference: replyReference, maximumBytes: 2)
  }
  #expect(await script.requests.count == 3)
}
@Test func replyDownloadHonorsCancellationAndRasterAllowlist() async throws {
  let script = ReplyScript([])
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await CapabilityService(
      endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: script)
    )
    .downloadAttachment(filePart(), reference: replyReference)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await script.requests.isEmpty)
  var part = try filePart()
  for type in ["image/png", "IMAGE/JPEG", "image/gif", "image/webp"] {
    part.mediaType = type
    #expect(part.isReplyImage)
  }
  part.mediaType = "image/svg+xml"
  #expect(!part.isReplyImage)
}

private func sentUpload() throws -> WebAttachment {
  try JSONDecoder().decode(
    WebAttachment.self,
    from: Data(
      #"{"id":"upload","name":"notes.txt","contentType":"text/plain","sizeBytes":3,"kind":"document","status":"committed","uploaded":true,"createdAt":"2030-01-02T12:00:00Z","contentUrl":"https://untrusted.example/ignored?token=fictional"}"#
        .utf8))
}
@Test func sentUploadsUseBoundedDurableRouteWithoutFollowingDTOURL() async throws {
  let script = ReplyScript([bytes()])
  let api = APIClient(endpoint: Scenario.endpoint, transport: script)
  #expect(try await api.downloadUpload(sentUpload()) == Data("abc".utf8))
  #expect(await script.requests.first?.url?.path == "/api/v1/uploads/upload/content")
  #expect(await script.requests.first?.url?.query == nil)
  #expect(await script.requests.first?.httpMethod == "GET")
  var invalid = try sentUpload()
  invalid.uploaded = false
  await #expect(throws: ReplyContentError.unavailable) { try await api.downloadUpload(invalid) }
  await #expect(throws: ReplyContentError.tooLarge) {
    try await api.downloadUpload(sentUpload(), maximumBytes: 2)
  }
  #expect(await script.requests.count == 1)
}
@Test func sentUploadsRejectInvalidLengthsAndMissingOrDeletedUploadsWithoutRetry() async throws {
  let script = ReplyScript([
    bytes("ab"), bytes("abcd"), .init(data: Data("abc".utf8), headers: ["content-length": "2"]),
    .init(
      data: Data(#"{"error":{"code":"upload_not_found","message":"Unavailable"}}"#.utf8),
      status: 404),
  ])
  let api = APIClient(endpoint: Scenario.endpoint, transport: script)
  for _ in 0..<3 {
    await #expect(throws: ReplyContentError.integrity) {
      try await api.downloadUpload(sentUpload())
    }
  }
  await #expect(throws: APIError.self) { try await api.downloadUpload(sentUpload()) }
  #expect(await script.requests.count == 4)
}
@Test func sentUploadBinaryTransferHonorsCallerCeiling() async throws {
  let script = ReplyScript([bytes("abcd")])
  let api = APIClient(endpoint: Scenario.endpoint, transport: script)
  await #expect(throws: ReplyContentError.tooLarge) {
    try await api.downloadUpload(sentUpload(), maximumBytes: 3)
  }
  #expect(await script.requests.count == 1)
}
