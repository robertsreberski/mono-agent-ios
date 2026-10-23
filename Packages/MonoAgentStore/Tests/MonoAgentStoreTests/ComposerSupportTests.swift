// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

/// Upload transport double: routes like `RouteTransport`, and reports fixed progress steps.
actor UploadRouteTransport: FileUploadTransport {
  let routes: RouteTransport
  var uploads = 0
  init(_ routes: RouteTransport) { self.routes = routes }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    try await routes.send(request)
  }
  func upload(
    _ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> HTTPResponse {
    uploads += 1
    progress(0.5)
    return try await routes.send(request)
  }
}

@MainActor
struct ComposerSupportTests {
  func live(_ h: Harness) async throws {
    await h.store.hydrate()
    h.store.bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    h.store.started = true
    h.store.connection = .live
  }

  @Test func capabilitiesMirrorTheWebForThreadsAndNewConversations() async throws {
    let h = Harness()
    try await live(h)
    await h.store.select(sourceID: "agent-example")
    #expect(h.store.canSend && h.store.canUpload, "a new conversation follows its agent")
    try h.seed()
    h.store.selectedThreadID = "thread-example"
    #expect(h.store.canSend && h.store.canUpload)
    h.store.conversations["thread-example"]?.thread.archivedAt = "2030-01-02T12:00:00Z"
    #expect(!h.store.canSend && !h.store.canUpload)
    h.store.conversations["thread-example"]?.thread.archivedAt = nil
    h.store.connection = .waiting
    #expect(!h.store.canSend && !h.store.canUpload, "only a live console accepts input")
    h.store.connection = .live
    h.store.bootstrap?.agents[0].supportsAttachments = false
    #expect(h.store.canSend && !h.store.canUpload)
    h.store.bootstrap?.agents[0].status = "offline"
    #expect(!h.store.canSend)
    await h.store.stop()
  }

  @Test func stagingReportsProgressAndSingleChipRemovalDeletesOnlyThatFile() async throws {
    let routes = RouteTransport()
    let transport = UploadRouteTransport(routes)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    let profile = SavedConsole(name: "Flockbox", endpoint: Scenario.endpoint)
    let store = ConsoleStore(
      profile: profile, api: APIClient(endpoint: Scenario.endpoint, transport: transport),
      events: TestEvents(), repository: FileConsoleRepository(directory: directory),
      clock: ManualStoreClock())
    await store.hydrate()
    store.bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    store.started = true
    store.connection = .live
    await store.select(sourceID: "agent-example")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("sample.txt")
    try Data("note".utf8).write(to: file)
    let reserved = try decode(
      #"{"attachment":{"id":"upload-example","name":"sample.txt","contentType":"text/plain","sizeBytes":4,"kind":"file","status":"pending","uploaded":false,"createdAt":"2030-01-02T12:00:00Z"}}"#,
      as: JSONValue.self)
    var uploaded = reserved
    if case .object(var root) = uploaded, case .object(var attachment)? = root["attachment"] {
      attachment["uploaded"] = .bool(true)
      attachment["status"] = .string("ready")
      root["attachment"] = .object(attachment)
      uploaded = .object(root)
    }
    await routes.set("/api/v1/uploads", [.response(try response(reserved, status: 201))])
    await routes.set(
      "/api/v1/uploads/upload-example/content", [.response(try response(uploaded))])
    await routes.set(
      "/api/v1/uploads/upload-example",
      [.response(HTTPResponse(data: Data(), status: 204))])
    let staging = Task {
      try await store.stageUploads([
        UploadFile(url: file, name: "sample.txt", contentType: "text/plain", sizeBytes: 4)
      ])
    }
    await eventually { !store.uploadProgress.isEmpty }
    try await staging.value
    #expect(store.uploadProgress.isEmpty, "finished rows leave the progress list")
    #expect(store.stagedAttachments.map(\.id) == ["upload-example"])
    await store.discardStagedUpload("upload-example")
    #expect(store.stagedAttachments.isEmpty)
    #expect(await routes.count("/api/v1/uploads/upload-example", method: "DELETE") == 1)
    await store.stop()
  }

  @Test func oversizedOrWrongTypeFilesFailBeforeAnyProgressRow() async throws {
    let h = Harness()
    try await live(h)
    await h.store.select(sourceID: "agent-example")
    let url = URL(fileURLWithPath: "/dev/null")
    await #expect(throws: UploadValidationError.type) {
      try await h.store.stageUploads([
        UploadFile(url: url, name: "photo.png", contentType: "image/png", sizeBytes: 10)
      ])
    }
    await #expect(throws: UploadValidationError.size) {
      try await h.store.stageUploads([
        UploadFile(url: url, name: "big.txt", contentType: "text/plain", sizeBytes: 30_000_000)
      ])
    }
    #expect(h.store.uploadProgress.isEmpty)
    await h.store.stop()
  }

  @Test func createConversationRetainsOnlyTheClaimedStagedFiles() async throws {
    let h = Harness()
    try await live(h)
    await h.store.select(sourceID: "agent-example")
    var other = try exampleAttachment()
    other.id = "upload-other"
    h.store.stagedAttachments = [try exampleAttachment(), other]
    var created = try sampleThread("thread-created")
    created.title = "New"
    await h.transport.set(
      "/api/v1/threads",
      [.response(try response(JSONValue.object(["thread": try json(created)]), status: 201))])
    await h.transport.set(
      "/api/v1/uploads/upload-other", [.response(HTTPResponse(data: Data(), status: 204))])
    let id = try await h.store.createConversation(
      .init(sourceId: "agent-example"), retainingAttachments: ["upload-example"])
    #expect(id == "thread-created")
    #expect(h.store.selectedThreadID == "thread-created")
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    #expect(await h.transport.count("/api/v1/uploads/upload-other", method: "DELETE") == 1)
    await h.store.stop()
  }

  @Test func runOverrideIsOptimisticQueuedAndRevertedOnFailure() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    var saved = try sampleThread(revision: 2)
    saved.runModel = "sample:small"
    saved.runEffort = "low"
    await h.transport.set(
      "/api/v1/threads/thread-example",
      [.response(try response(JSONValue.object(["thread": try json(saved)]))), .failure])
    h.store.setRunOverride(threadID: "thread-example", model: "sample:small", effort: "low")
    #expect(h.store.conversations["thread-example"]?.thread.runModel == "sample:small")
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.conversations["thread-example"]?.thread.revision == 2)
    let body = try #require(await h.transport.requests.last?.httpBody)
    let sent = try JSONDecoder().decode(JSONValue.self, from: body)
    #expect(sent == .object(["model": .string("sample:small"), "effort": .string("low")]))
    h.store.setRunOverride(threadID: "thread-example", model: "", effort: nil)
    #expect(h.store.conversations["thread-example"]?.thread.runModel == nil)
    do {
      try await h.store.settleThreadWrites("thread-example")
      Issue.record("A refused override must be reported")
    } catch SubmissionError.threadWriteFailed {}
    #expect(h.store.conversations["thread-example"]?.thread.runModel == "sample:small")
    #expect(h.store.errorMessage?.contains("not saved") == true)
    await h.store.stop()
  }

  @Test func askReadsPreferExactInteractionAndAnswersMapRejections() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    let snapshot: JSONValue = try decode(
      #"{"interactionId":"ask-example","message":"Choose an example","questions":[{"id":"question-example","header":"Example","question":"Which size?","multiSelect":false,"options":[{"id":"small","label":"Small","description":"A short example"}]}],"answers":[],"activeQuestionIndex":0,"status":"pending","createdAt":"2030-01-02T12:00:00.000Z","expiresAt":null}"#
    )
    await h.transport.set(
      "/api/v1/threads/thread-example/ask/ask-example",
      [.response(try response(JSONValue.object(["ask": snapshot])))])
    await h.transport.set(
      "/api/v1/threads/thread-example/ask",
      [
        .response(try response(JSONValue.object(["ask": snapshot]))),
        .response(
          try response(
            JSONValue.object(["accepted": .bool(false), "code": .string("invalid_answer")]))),
        .response(
          try response(JSONValue.object(["accepted": .bool(true), "snapshot": snapshot]))),
      ])
    let exact = try await h.store.askSnapshot(
      threadID: "thread-example", interactionID: "ask-example")
    #expect(exact?.interactionId == "ask-example")
    let pending = try await h.store.askSnapshot(threadID: "thread-example", interactionID: nil)
    #expect(pending?.questions.count == 1)
    let answer = ChannelAskAnswer(questionId: "question-example", selectedOptionIds: ["small"])
    await #expect(throws: AskAnswerError.incomplete) {
      _ = try await h.store.answerAsk(
        threadID: "thread-example", interactionID: "ask-example", answers: [answer])
    }
    let accepted = try await h.store.answerAsk(
      threadID: "thread-example", interactionID: "ask-example", answers: [answer])
    #expect(accepted?.interactionId == "ask-example")
    await h.store.stop()
  }

  @Test func stopUsesTheContractOriginAndAdoptsTheCancelledThread() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    var cancelled = try sampleThread(revision: 2)
    cancelled.runState = try decode(#"{"status":"cancelled","cancelOrigin":"user-stop"}"#)
    await h.transport.set(
      "/api/v1/threads/thread-example/cancel",
      [
        .response(
          try response(
            JSONValue.object(["cancelled": .bool(true), "thread": try json(cancelled)]),
            status: 202))
      ])
    try await h.store.cancel(threadID: "thread-example")
    let body = try #require(
      await h.transport.requests.first { $0.url?.path.hasSuffix("/cancel") == true }?.httpBody)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: body)
        == .object(["origin": .string("user-stop")]))
    #expect(h.store.conversations["thread-example"]?.thread.runState.status == "cancelled")
    await h.store.stop()
  }

  @Test func skillRegistryLoadsAndKeepsStaleItemsAfterAFailedRefresh() async throws {
    let h = Harness()
    try await live(h)
    let registry: JSONValue = try decode(
      #"{"status":"ready","items":[{"name":"release-notes","description":"Draft notes","availability":"on-demand","reference":"$release-notes"}],"total":1}"#
    )
    await h.transport.set(
      "/api/v1/agents/agent-example/skills", [.response(try response(registry)), .failure])
    await h.store.loadSkills(sourceID: "agent-example")
    #expect(h.store.skillRegistries["agent-example"]?.canInsert == true)
    #expect(h.store.skillRegistries["agent-example"]?.items.first?.name == "release-notes")
    await h.store.loadSkills(sourceID: "agent-example")
    #expect(h.store.skillRegistries["agent-example"]?.canInsert == false)
    #expect(h.store.skillRegistries["agent-example"]?.items.count == 1)
    await h.store.stop()
  }
}

func json<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
