// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

struct ReplyFileCacheTests {
  @Test func boundsLeasesCleanupAndNoCredentialsOnDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReplyFileCache(
      directory: directory, maximumBytes: 6, maximumCount: 2, retention: 60)
    let now = Date()
    let one = try await cache.insert(
      Data("abc".utf8), key: "fictional-token", name: "../../sample.txt", now: now)
    #expect(one.url.path.hasPrefix(directory.path + "/"))
    #expect(one.url.lastPathComponent == "_.._sample.txt")
    #expect(!one.url.lastPathComponent.contains("fictional-token"))
    let two = try await cache.insert(Data("def".utf8), key: "two", name: "two.txt", now: now)
    await #expect(throws: ReplyFileCacheError.self) {
      try await cache.insert(Data("ghi".utf8), key: "three", name: "three.txt", now: now)
    }
    try await cache.release(one, now: now)
    let three = try await cache.insert(Data("ghi".utf8), key: "three", name: "three.txt", now: now)
    #expect(!FileManager.default.fileExists(atPath: one.url.path))
    #expect(try Data(contentsOf: two.url) == Data("def".utf8))
    try await cache.clear()
    #expect(FileManager.default.fileExists(atPath: two.url.path), "Active preview remains pinned")
    try await cache.release(two, now: now.addingTimeInterval(61))
    try await cache.release(three, now: now.addingTimeInterval(61))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
  @Test func restartPrunesExpiredDiskBytesAndOversizedWritesNeverLand() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let first = ReplyFileCache(directory: directory, maximumBytes: 3, retention: 1)
    let lease = try await first.insert(Data("abc".utf8), key: "one", name: "one.txt", now: now)
    try await first.release(lease, now: now)
    let reopened = ReplyFileCache(directory: directory, maximumBytes: 3, retention: 1)
    #expect(
      try await reopened.cached(key: "one", name: "one.txt", now: now.addingTimeInterval(2)) == nil)
    await #expect(throws: ReplyFileCacheError.self) {
      try await reopened.insert(Data("abcd".utf8), key: "large", name: "large.txt")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
}

@MainActor struct ReplyAttachmentTests {
  private let base =
    "/api/v1/threads/thread-example/messages/message-example/reply-attachments/file"
  private func part() throws -> ReplyAttachmentPart {
    try decode(
      #"{"type":"attachment","id":"file","artifactId":"artifact","name":"sample.txt","mediaType":"text/plain","sizeBytes":3,"integrityId":"digest"}"#
    )
  }
  private func live() async throws -> Harness {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    var message = try sampleMessage()
    message.parts = [.attachment(try part())]
    try h.seed(messages: [message])
    h.store.selectedThreadID = "thread-example"
    return h
  }
  private func download(_ h: Harness) async throws -> ReplyFileLease {
    try await h.store.downloadReplyAttachment(
      threadID: "thread-example", messageID: "message-example", partID: "file")
  }
  private func authorized() throws -> HTTPResponse {
    var value = try part()
    value.contentUrl = base + "/content?expires=1&token=fictional-secret"
    return try response(
      JSONValue.object([
        "part": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
      ]))
  }
  private var bytes: HTTPResponse {
    .init(
      data: Data("abc".utf8), contentType: "text/plain",
      headers: ["x-mono-agent-integrity-id": "digest"])
  }
  @Test func downloadUsesStoreAccessSeamAndReusesBytesWithoutPersistingCapabilities() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    await h.transport.set(base + "/access", [.response(try authorized())])
    await h.transport.set(base + "/content", [.response(bytes)])
    let lease = try await download(h)
    #expect(lease.url.isFileURL)
    #expect(lease.url.lastPathComponent == "sample.txt")
    #expect(try Data(contentsOf: lease.url) == Data("abc".utf8))
    await h.store.releaseReplyFile(lease)
    let again = try await download(h)
    #expect(again.url == lease.url)
    #expect(await h.transport.count(base + "/access", method: "POST") == 1)
    #expect(
      h.store.conversations["thread-example"]?.messages.first?.parts == [.attachment(try part())])
    await h.store.releaseReplyFile(again)
    await h.store.stop()
  }
  @Test func unavailableAndTooLargeAreHonestAndDoNotRetry() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    await h.transport.set(
      base + "/access",
      [
        .response(
          .init(
            data: Data(#"{"error":{"code":"reply_part_not_found","message":"Unavailable"}}"#.utf8),
            status: 404))
      ])
    await #expect(throws: ReplyDownloadFailure.unavailable) { try await download(h) }
    var message = try sampleMessage()
    var large = try part()
    large.sizeBytes = ReplyFileCache.maximumFileBytes + 1
    message.parts = [.attachment(large)]
    try h.seed(messages: [message])
    await #expect(throws: ReplyDownloadFailure.tooLarge) { try await download(h) }
    #expect(await h.transport.count(base + "/access") == 1)
    await h.store.stop()
  }
  @Test func lateAccessAfterStopSelectionChangeOrCancellationCannotPublishFile() async throws {
    for action in 0..<3 {
      let h = try await live()
      await h.transport.set(base + "/access", [.paused])
      let read = Task { try await download(h) }
      await eventually { await h.transport.pauseCount() == 1 }
      if action == 0 { await h.store.stop() }
      if action == 1 { h.store.selection += 1 }
      if action == 2 { read.cancel() }
      await h.transport.release(try authorized())
      await h.transport.set(base + "/content", [.response(bytes)])
      await #expect(throws: CancellationError.self) { try await read.value }
      await h.store.stop()
      try? FileManager.default.removeItem(at: h.directory)
    }
  }
}

@MainActor struct SentUploadAttachmentTests {
  private func attachment() throws -> WebAttachment {
    try decode(
      #"{"id":"sent-upload","name":"notes.txt","contentType":"text/plain","sizeBytes":3,"kind":"document","status":"committed","uploaded":true,"createdAt":"2030-01-02T12:00:00Z"}"#
    )
  }
  private func live() async throws -> Harness {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    var message = try sampleMessage()
    message.role = "user"
    message.attachments = [try attachment()]
    try h.seed(messages: [message])
    h.store.selectedThreadID = "thread-example"
    return h
  }
  private func download(_ h: Harness) async throws -> ReplyFileLease {
    try await h.store.downloadMessageAttachment(
      threadID: "thread-example", messageID: "message-example", attachmentID: "sent-upload")
  }
  @Test func restoredUploadUsesDurableIDAndSharedBoundedCache() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    await h.transport.set(
      "/api/v1/uploads/sent-upload/content", [.response(.init(data: Data("abc".utf8)))])
    let lease = try await download(h)
    #expect(lease.url.lastPathComponent == "notes.txt")
    #expect(try Data(contentsOf: lease.url) == Data("abc".utf8))
    await h.store.releaseReplyFile(lease)
    let again = try await download(h)
    #expect(again.url == lease.url)
    #expect(await h.transport.count("/api/v1/uploads/sent-upload/content") == 1)
    #expect(
      h.store.conversations["thread-example"]?.messages.first?.attachments.first?.contentUrl == nil)
    await h.store.releaseReplyFile(again)
    try await h.store.clearReplyFileCache()
    #expect(!FileManager.default.fileExists(atPath: lease.url.path))
    await h.store.stop()
  }
  @Test func deletedUploadIsUnavailableAndNeverReplayed() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    await h.transport.set(
      "/api/v1/uploads/sent-upload/content", [.response(.init(data: Data(), status: 404))])
    await #expect(throws: ReplyDownloadFailure.unavailable) { try await download(h) }
    #expect(await h.transport.count("/api/v1/uploads/sent-upload/content") == 1)
    await h.store.stop()
  }
  @Test func uploadLateResultsAfterStopSelectionCancellationOrReplacementAreDiscarded() async throws
  {
    for action in 0..<4 {
      let h = try await live()
      await h.transport.set("/api/v1/uploads/sent-upload/content", [.paused])
      let read = Task { try await download(h) }
      await eventually { await h.transport.pauseCount() == 1 }
      if action == 0 { await h.store.stop() }
      if action == 1 { h.store.selection += 1 }
      if action == 2 { read.cancel() }
      if action == 3 {
        var message = try sampleMessage()
        var changed = try attachment()
        changed.name = "replacement.txt"
        message.attachments = [changed]
        try h.seed(messages: [message])
      }
      await h.transport.release(.init(data: Data("abc".utf8)))
      await #expect(throws: CancellationError.self) { try await read.value }
      await h.store.stop()
      try? FileManager.default.removeItem(at: h.directory)
    }
  }
}

extension SentUploadAttachmentTests {
  @Test func unknownUnuploadedAndOversizedUploadsAreRefusedBeforeIO() async throws {
    let h = try await live()
    defer { try? FileManager.default.removeItem(at: h.directory) }
    for mode in 0..<4 {
      var message = try sampleMessage()
      var file = try attachment()
      if mode == 0 { file.uploaded = false }
      if mode == 1 { file.status = "staged" }
      if mode == 2 { file.sizeBytes = ReplyFileCache.maximumFileBytes + 1 }
      message.attachments = mode == 3 ? [] : [file]
      try h.seed(messages: [message])
      await #expect(throws: mode == 2 ? ReplyDownloadFailure.tooLarge : .unavailable) {
        try await download(h)
      }
    }
    #expect(await h.transport.count("/api/v1/uploads/sent-upload/content") == 0)
    await h.store.stop()
  }
}
