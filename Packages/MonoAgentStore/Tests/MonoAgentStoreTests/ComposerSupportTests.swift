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

  @Test func sameContextReselectionDoesNotAbandonTheDraft() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    await h.store.select(sourceID: "agent-example", threadID: "thread-example")
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "Sample draft")
    h.store.stagedAttachments = [try exampleAttachment()]
    let selection = h.store.selection
    await h.store.select(sourceID: "agent-example", threadID: "thread-example")
    #expect(h.store.selection == selection, "reappearing in the same context is not abandonment")
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(
      h.store.draft(sourceID: "agent-example", threadID: "thread-example")?.text == "Sample draft")
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await h.store.stop()
  }

  @Test func backgroundDoesNotAbandonStagedAttachments() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    await h.store.select(sourceID: "agent-example", threadID: "thread-example")
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example", text: "Sample draft")
    h.store.stagedAttachments = [try exampleAttachment()]
    await h.store.scenePhaseChanged(.background)
    #expect(h.store.stagedAttachments.map(\.id) == ["upload-example"])
    #expect(
      h.store.draft(sourceID: "agent-example", threadID: "thread-example")?.text == "Sample draft")
    #expect(await h.transport.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    await h.store.stop()
  }

  @Test(arguments: [0, 1, 2, 3, 4])
  func stagingReportsProgressAndSingleChipRemovalDeletesOnlyThatFile(transition: Int) async throws {
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
      "/api/v1/uploads/upload-example/content", [.paused])
    await routes.set(
      "/api/v1/uploads/upload-example",
      [.response(HTTPResponse(data: Data(), status: 204))])
    let staging = Task {
      try await store.stageUploads([
        UploadFile(url: file, name: "sample.txt", contentType: "text/plain", sizeBytes: 4)
      ])
    }
    await eventually { await routes.pauseCount() == 1 }
    await eventually { store.uploadProgress.contains { $0.fraction == 0.5 } }
    #expect(
      store.uploadProgress.contains { $0.fraction == 0.5 },
      "intermediate progress is held until acceptance")
    switch transition {
    case 0: await store.select(sourceID: "agent-example")
    case 1: await store.scenePhaseChanged(.background)
    case 2: await store.stopEffects()  // A stream epoch change is not upload abandonment.
    case 3: await store.discardStagedUploads()
    default: await store.select(sourceID: "other-agent")
    }
    await routes.release(try response(uploaded))
    if transition >= 3 {
      do {
        try await staging.value
        Issue.record("Abandoned uploads must reject late completion")
      } catch is CancellationError {}
      #expect(store.stagedAttachments.isEmpty && store.uploadProgress.isEmpty)
      #expect(await routes.count("/api/v1/uploads/upload-example", method: "DELETE") == 1)
      await store.stop()
      try FileManager.default.removeItem(at: directory)
      return
    }
    try await staging.value
    #expect(await routes.count("/api/v1/uploads", method: "POST") == 1)
    #expect(await routes.count("/api/v1/uploads/upload-example/content", method: "PUT") == 1)
    #expect(await routes.count("/api/v1/uploads/upload-example", method: "DELETE") == 0)
    // Resume connectivity without creating another upload.
    store.backgrounded = false
    store.connection = .live
    #expect(store.uploadProgress.isEmpty, "finished rows leave the progress list")
    #expect(store.stagedAttachments.map(\.id) == ["upload-example"])
    var second = reserved
    if case .object(var root) = second, case .object(var attachment)? = root["attachment"] {
      attachment["id"] = .string("upload-other")
      attachment["name"] = .string("other.txt")
      attachment["uploaded"] = .bool(true)
      attachment["status"] = .string("ready")
      root["attachment"] = .object(attachment)
      second = .object(root)
    }
    await routes.set("/api/v1/uploads", [.response(try response(second, status: 201))])
    await routes.set("/api/v1/uploads/upload-other/content", [.response(try response(second))])
    try await store.stageUploads([
      UploadFile(url: file, name: "other.txt", contentType: "text/plain", sizeBytes: 4)
    ])
    #expect(store.stagedAttachments.map(\.id) == ["upload-example", "upload-other"])
    await store.discardStagedUpload("upload-example")
    #expect(store.stagedAttachments.map(\.id) == ["upload-other"])
    #expect(await routes.count("/api/v1/uploads/upload-other", method: "DELETE") == 0)
    #expect(await routes.count("/api/v1/uploads/upload-example", method: "DELETE") == 1)
    await store.stop()
    try FileManager.default.removeItem(at: directory)
  }

  @Test(arguments: [false, true])
  func overlappingOverridesNeverClobberTheNewestChoice(bothFail: Bool) async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    let baseline = h.store.conversations["thread-example"]?.thread.runModel
    let path = "/api/v1/threads/thread-example"
    await h.transport.set(path, [.paused, .paused])
    h.store.setRunOverride(threadID: "thread-example", model: "sample:a", effort: nil)
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.setRunOverride(threadID: "thread-example", model: "sample:b", effort: nil)
    var saved = try sampleThread(revision: 2)
    saved.runModel = "sample:a"
    let failed = HTTPResponse(data: Data(), status: 500)
    await h.transport.release(bothFail ? failed : try response(["thread": saved]))
    await eventually { await h.transport.count(path, method: "PATCH") == 2 }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.conversations["thread-example"]?.thread.runModel == "sample:b")
    await h.transport.release(failed)
    do { try await h.store.settleThreadWrites("thread-example") } catch {}
    #expect(
      h.store.conversations["thread-example"]?.thread.runModel == (bothFail ? baseline : "sample:a")
    )
    await h.store.stop()
  }

  @Test func overridesRefuseStoppedStoppingAndBackgroundedStoresAndRecheckQueue() async throws {
    let h = Harness()
    try await live(h)
    try h.seed()
    let baseline = h.store.conversations["thread-example"]?.thread.runModel
    for flag in 0..<3 {
      h.store.stopped = flag == 0
      h.store.stopping = flag == 1
      h.store.backgrounded = flag == 2
      h.store.setRunOverride(threadID: "thread-example", model: "sample:blocked", effort: nil)
      #expect(h.store.conversations["thread-example"]?.thread.runModel == baseline)
      #expect(h.store.writeTasks.isEmpty)
    }
    h.store.stopped = false
    h.store.stopping = false
    h.store.backgrounded = false
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    h.store.setRunOverride(threadID: "thread-example", model: "sample:queued", effort: nil)
    h.store.backgrounded = true
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    #expect(await h.transport.count("/api/v1/threads/thread-example", method: "PATCH") == 0)
    #expect(h.store.conversations["thread-example"]?.thread.runModel == baseline)
    await h.store.stop()
  }

  @Test(arguments: [0, 1, 2, 3, 4])
  func askCommandsDiscardLateResultsAfterLifetimeChanges(change: Int) async throws {
    for answering in [false, true] {
      let h = Harness()
      try await live(h)
      try h.seed()
      let path = "/api/v1/threads/thread-example/ask"
      await h.transport.set(path, [.paused])
      let request = Task {
        if answering {
          return try await h.store.answerAsk(
            threadID: "thread-example", interactionID: "ask-example", answers: [])
        }
        return try await h.store.askSnapshot(threadID: "thread-example", interactionID: nil)
      }
      await eventually { await h.transport.pauseCount() == 1 }
      switch change {
      case 0: await h.store.stop()
      case 1: h.store.backgrounded = true
      case 2: h.store.selection += 1
      case 3: h.store.epoch += 1
      default:
        h.store.conversations["thread-example"] = nil
        try h.seed()
      }
      let result: JSONValue =
        answering
        ? .object(["accepted": .bool(true), "snapshot": .null]) : .object(["ask": .null])
      await h.transport.release(try response(result))
      do {
        _ = try await request.value
        Issue.record("Late ask result must be cancelled")
      } catch is CancellationError {}
      await h.store.stop()
    }
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
