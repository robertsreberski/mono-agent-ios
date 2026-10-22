// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct MergeAndSafetyTests {
  func tool(digest: String, truncated: Bool) throws -> WebMessagePart {
    try decode(
      """
      {"type":"tool-call","toolCallId":"tool-example","toolName":"example","status":"complete",
       "result":"\(truncated ? "preview" : "full body")","resultDigest":"\(digest)","resultTruncated":\(truncated)}
      """)
  }
  @Test func nonoverlappingWindowKeepsOlderHistoryBeforeServerWindow() throws {
    var older = try sampleMessage("older")
    older.createdAt = "2029-01-01T00:00:00Z"
    let newer = try sampleMessage("newer")
    let merged = TranscriptMerge.window(
      [newer], held: [older], paged: ["older"], repaired: [], complete: false)
    #expect(merged.map(\.id) == ["older", "newer"])
  }
  @Test func fullReadsPreserveOnlyDigestValidRepairedBodies() throws {
    var held = try sampleMessage()
    held.parts = [try tool(digest: "same-digest", truncated: false)]
    var incoming = try sampleMessage(seq: 2)
    incoming.parts = [try tool(digest: "same-digest", truncated: true)]
    let same = TranscriptMerge.message(incoming, held: held, repaired: ["tool-example"])
    guard case .toolCall(let valid) = same.parts[0] else {
      Issue.record("Expected tool")
      return
    }
    #expect(valid.result == .string("full body"))
    incoming.parts = [try tool(digest: "changed-digest", truncated: true)]
    let changed = TranscriptMerge.message(incoming, held: held, repaired: ["tool-example"])
    guard case .toolCall(let invalid) = changed.parts[0] else {
      Issue.record("Expected tool")
      return
    }
    #expect(invalid.result == .string("preview"))
    #expect(invalid.resultTruncated == true)
  }
  @Test func toolRepairRacingARewriteCannotInstallOldBody() async throws {
    let h = Harness()
    var message = try sampleMessage()
    message.parts = [try tool(digest: "old-digest", truncated: true)]
    try h.seed(messages: [message])
    await h.transport.set(
      "/api/v1/threads/thread-example/messages/message-example/tool-calls/tool-example", [.paused])
    let repair = Task {
      await h.store.repairToolOutput(
        threadID: "thread-example", messageID: "message-example", toolCallID: "tool-example")
    }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.conversations["thread-example"]?.record.messages[0].parts = [
      try tool(digest: "new-digest", truncated: true)
    ]
    await h.transport.release(
      try response(
        JSONValue.object([
          "part": try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(tool(digest: "old-digest", truncated: false))
          )
        ])))
    await repair.value
    let part = try #require(h.store.conversations["thread-example"]?.messages[0].parts[0])
    guard case .toolCall(let value) = part else {
      Issue.record("Expected tool")
      return
    }
    #expect(value.result == .string("preview"))
    #expect(value.resultDigest == "new-digest")
    await h.store.stop()
  }
  @Test func compactionBusyRefreshesDetailAndBootstrap() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.transport.set(
      "/api/v1/threads/thread-example/submissions",
      [
        .response(
          HTTPResponse(
            data: Data(
              #"{"error":{"code":"compaction_busy","message":"Fictional busy state"}}"#.utf8),
            status: 409))
      ])
    _ = try? await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example",
      input: .init(submissionId: "", text: "Example"))
    #expect(await h.transport.count("/api/v1/threads/thread-example") == 1)
    #expect(await h.transport.count("/api/v1/bootstrap") == 1)
    await h.store.stop()
  }
  @Test func deletedProfileCannotBeRecreatedByLateFlush() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", text: "Example")
    await h.store.flushAuthored()
    try await h.repository.delete(profileID: h.profile.id)
    await h.store.flushAuthored()
    #expect(h.store.authoredStorage == .writeFailed)
    #expect(
      !FileManager.default.fileExists(
        atPath: h.directory.appendingPathComponent(h.profile.id.uuidString).path))
    await h.store.stop()
  }
  @Test func oversizedCachePrunesHistoryVisiblyButLeavesAuthoredRecords() async throws {
    let h = Harness()
    var message = try sampleMessage()
    message.parts = [try decode(#"{"type":"text","text":"placeholder"}"#, as: WebMessagePart.self)]
    if case .text(var part) = message.parts[0] {
      part.text = String(repeating: "x", count: ConsoleBounds.conversationBytes + 1)
      message.parts = [.text(part)]
    }
    var cache = CacheRecord()
    cache.revision = 1
    cache.conversations = [.init(thread: try sampleThread(), messages: [message], savedAt: Date())]
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    let result = try await h.repository.loadCache(h.store.namespace)
    #expect(result.conversations.first?.truncated == true)
    #expect(result.conversations.first?.messages.isEmpty == true)
    #expect(result.conversations.first?.nextCursor == nil)
  }
}
