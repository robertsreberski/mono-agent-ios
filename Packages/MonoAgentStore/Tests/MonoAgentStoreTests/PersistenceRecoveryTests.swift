// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct PersistenceRecoveryTests {
  @Test func hydrateSanitizesCapabilitiesSilentCronCompactionAndRunningConfirmation() async throws {
    let h = Harness()
    var thread = try sampleThread()
    thread.runState.status = "running"
    thread.compaction = try decode(
      #"{"status":"running","trigger":"manual","startedAt":"2030-01-02T12:00:00Z"}"#)
    var message = try sampleMessage()
    message.parts += [
      try decode(
        #"{"type":"attachment","id":"part-example","artifactId":"artifact-example","name":"sample.txt","mediaType":"text/plain","sizeBytes":4,"integrityId":"digest-example","contentUrl":"/api/v1/threads/thread-example/files?token=fictional&expires=1"}"#,
        as: WebMessagePart.self)
    ]
    var silent = try sampleMessage("silent")
    silent.status = "complete"
    silent.parts = [
      try decode(
        #"{"type":"telemetry","event":"cron_run","data":{"status":"succeeded","silent":true}}"#,
        as: WebMessagePart.self)
    ]
    var cache = CacheRecord()
    cache.revision = 1
    cache.conversations = [.init(thread: thread, messages: [message, silent], savedAt: Date())]
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    await h.store.hydrate()
    let state = try #require(h.store.conversations[thread.id])
    #expect(!state.runningConfirmed)
    #expect(state.freshness == .stale)
    #expect(state.thread.compaction == nil)
    #expect(state.messages.count == 1)
    #expect(state.thread.messageCount == thread.messageCount - 1)
    #expect(state.etag == nil)
    guard case .attachment(let part) = state.messages[0].parts[1] else {
      Issue.record("Expected attachment")
      return
    }
    #expect(part.contentUrl == nil)
    let data = try Data(
      contentsOf: h.directory.appendingPathComponent(h.profile.id.uuidString)
        .appendingPathComponent(h.store.namespace.identity).appendingPathComponent("cache-v1.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("token="))
    await h.store.stop()
  }
  @Test(arguments: [false, true]) func corruptOrNewerFilesDegradeWithoutOverwriting(newer: Bool)
    async throws
  {
    let h = Harness()
    let directory = h.directory.appendingPathComponent(h.profile.id.uuidString)
      .appendingPathComponent(h.store.namespace.identity)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let corrupt = Data(
      (newer
        ? #"{"version":999,"revision":1,"buckets":[],"conversations":[],"tombstones":[]}"#
        : "broken").utf8)
    let file = directory.appendingPathComponent("cache-v1.json")
    try corrupt.write(to: file)
    await h.store.hydrate()
    #expect(h.store.storage == .memoryOnly)
    await h.store.flushCache()
    #expect(try Data(contentsOf: file) == corrupt)
    await h.store.setDraft(sourceID: "agent-example", text: "Still editable")
    await h.store.flushAuthored()
    #expect(h.store.authoredStorage == .durable)
    await h.store.stop()
  }
  @Test func diskBoundsRetainTwentyFourWhileMemoryRetainsEightAndAuthoredSurvivesPruning()
    async throws
  {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", text: "Keep this draft")
    await h.store.flushAuthored()
    for index in 0..<26 {
      h.store.hold(
        .init(
          thread: try sampleThread("thread-\(index)"), messages: [],
          savedAt: Date().addingTimeInterval(Double(index))))
      await h.store.flushCache()
    }
    #expect(h.store.conversations.count == 8)
    let cached = try await h.repository.loadCache(h.store.namespace)
    #expect(cached.conversations.count == 24)
    await h.store.select(sourceID: "agent-example", threadID: "thread-2")
    #expect(h.store.selectedConversation?.thread.id == "thread-2")
    #expect(h.store.selectedConversation?.runningConfirmed == false)
    #expect(await h.transport.requests.isEmpty)
    #expect(try await h.repository.loadAuthored(h.store.namespace).drafts.count == 1)
    await h.store.stop()
  }
  @Test func failedJournalPreventsPostAndDraftFailureIsVisible() async throws {
    let h = Harness()
    let directory = h.directory.appendingPathComponent(h.profile.id.uuidString)
      .appendingPathComponent(h.store.namespace.identity)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: directory.appendingPathComponent("journal-v1.json"))
    try Data("broken".utf8).write(to: directory.appendingPathComponent("authored-v1.json"))
    await h.store.hydrate()
    #expect(h.store.journalStorage == .memoryOnly)
    #expect(h.store.authoredStorage == .memoryOnly)
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
      Issue.record("Must not dispatch without a durable journal")
    } catch {}
    #expect(
      await h.transport.count("/api/v1/threads/thread-example/submissions", method: "POST") == 0)
    await h.store.stop()
  }
  @Test func ambiguousSubmissionRelaunchRecoversByGetOnlyAndClearsMatchingDraft() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Hello")
    await h.store.flushAuthored()
    await h.transport.set("/api/v1/threads/thread-example/submissions", [.failure])
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "ignored", text: "Hello"))
      Issue.record("Expected uncertainty")
    } catch {}
    let reference = try #require(h.store.pendingSubmissions.first)
    #expect(h.store.drafts.count == 1)
    let again = Harness(profile: h.profile, directory: h.directory)
    await again.store.hydrate()
    #expect(again.store.pendingSubmissions.first?.submissionID == reference.submissionID)
    await again.transport.set(
      "/api/v1/threads/thread-example/submissions/\(reference.submissionID)",
      [
        .response(
          try response(
            JSONValue.object([
              "submissionId": .string(reference.submissionID),
              "threadId": .string("thread-example"), "outcome": .string("turn"),
            ])))
      ])
    await again.store.recoverSubmissions()
    #expect(
      await again.transport.count("/api/v1/threads/thread-example/submissions", method: "POST") == 0
    )
    #expect(again.store.pendingSubmissions.isEmpty)
    #expect(again.store.drafts.isEmpty)
    await h.store.stop()
    await again.store.stop()
  }
  @Test func explicitUnchangedRetryReusesUUIDChangedPayloadGetsNewUUID() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.transport.set(
      "/api/v1/threads/thread-example/submissions", [.failure, .failure, .failure])
    for text in ["Hello", "Hello", "Changed"] {
      do {
        _ = try await h.store.submit(
          sourceID: "agent-example", threadID: "thread-example",
          input: .init(submissionId: "ignored", text: text))
      } catch {}
    }
    let requests = await h.transport.requests.filter { $0.httpMethod == "POST" }
    let ids = try requests.map {
      try JSONDecoder().decode(ApiStartSubmission.self, from: $0.httpBody!).submissionId
    }
    #expect(ids.count == 3)
    #expect(ids[0] == ids[1])
    #expect(ids[1] != ids[2])
    await h.store.stop()
  }
  @Test func editingDraftDuringSubmissionDoesNotClearNewVersion() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Hello")
    await h.transport.set("/api/v1/threads/thread-example/submissions", [.paused])
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Hello"))
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(h.store.pendingSubmissions.first)
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "Next thought")
    await h.transport.release(
      try response(
        JSONValue.object([
          "submissionId": .string(reference.submissionID), "threadId": .string("thread-example"),
          "outcome": .string("turn"),
        ]), status: 202))
    _ = try await send.value
    #expect(h.store.drafts.first?.text == "Next thought")
    await h.store.stop()
  }
}
