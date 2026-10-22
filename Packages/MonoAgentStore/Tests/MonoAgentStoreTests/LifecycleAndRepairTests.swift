// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

actor WriteGate {
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func ready() -> Bool { continuation != nil }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
actor ReservationSpy: UploadReservations {
  var disposals = 0
  func disposeVisible() { disposals += 1 }
  func count() -> Int { disposals }
}
@MainActor
struct LifecycleAndRepairTests {
  @Test func unreadablePayloadTargetsMessageThreadOrMarksAllStale() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    await h.transport.set(
      "/api/v1/threads/thread-example/messages/message-example",
      [
        .response(
          try response(
            JSONValue.object([
              "message": try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(sampleMessage(seq: 2)))
            ])))
      ])
    func unreadable(_ name: String, thread: String?, payload: String) throws -> UnreadableEvent {
      let data = """
        {"id":"event-example","version":1,"type":"\(name)","at":"2030-01-02T12:00:00Z"\(thread.map { ",\"threadId\":\"\($0)\"" } ?? ""),"payload":\(payload)}
        """
      var parser = SSEParser()
      let items = try parser.feed(Data("event: \(name)\ndata: \(data)\n\n".utf8))
      guard
        let frame = items.compactMap({ item -> SSEFrame? in
          if case .frame(let frame) = item { return frame }
          return nil
        }).first
      else { throw ConsoleStorageError.invalidFormat }
      guard case .unreadable(let value) = try EventDecoder.decode(frame) else {
        throw ConsoleStorageError.invalidFormat
      }
      return value
    }
    await h.store.receive(
      .unreadable(
        generation: 1,
        try unreadable(
          "message.delta", thread: "thread-example", payload: #"{"messageId":"message-example"}"#)))
    await eventually { h.store.repairs.isEmpty }
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 2)
    await h.transport.set(
      "/api/v1/threads/thread-example",
      [.response(try detailResponse(messages: [sampleMessage(seq: 3)]))])
    await h.store.receive(
      .unreadable(
        generation: 1, try unreadable("turn.changed", thread: "thread-example", payload: "{}")))
    await eventually { h.store.repairs.isEmpty }
    #expect(await h.transport.count("/api/v1/threads/thread-example") == 1)
    await h.store.receive(
      .unreadable(generation: 1, try unreadable("turn.changed", thread: nil, payload: "{}")))
    #expect(h.store.freshness == .stale)
    await h.store.reconciliationTask?.value
    await h.store.stop()
  }
  @Test func selectionDebounceAndContextDisposalUseInjectedClock() async throws {
    let transport = RouteTransport()
    let clock = ManualStoreClock()
    let events = TestEvents()
    let reservations = ReservationSpy()
    let store = ConsoleStore(
      profile: SavedConsole(name: "Flockbox", endpoint: Scenario.endpoint),
      api: APIClient(endpoint: Scenario.endpoint, transport: transport), events: events,
      repository: FileConsoleRepository(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
      clock: clock, uploads: reservations)
    store.started = true
    await store.select(sourceID: "agent-example", threadID: "one")
    await store.select(sourceID: "agent-example", threadID: "two")
    await eventually { await clock.pending() >= 1 }
    await clock.advance(0.24)
    #expect(await events.count() == 0)
    await clock.advance(0.01)
    await eventually { await events.count() == 1 }
    #expect(await events.subscriptions.last == "two")
    #expect(await reservations.count() == 2)
    await store.scenePhaseChanged(.background)
    #expect(await events.cancellations == 1)
    await store.scenePhaseChanged(.inactive)
    #expect(await events.count() == 1)
    await store.stop()
  }
  @Test func writesSettleBeforePostAndJournalAlreadyExists() async throws {
    let h = Harness()
    await h.store.hydrate()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
    }
    await eventually { !h.store.pendingSubmissions.isEmpty }
    let persisted = try await h.repository.loadJournal(h.store.namespace)
    #expect(persisted.pending.count == 1)
    #expect(
      await h.transport.count("/api/v1/threads/thread-example/submissions", method: "POST") == 0)
    await gate.release()
    _ = try? await send.value
    #expect(
      await h.transport.count("/api/v1/threads/thread-example/submissions", method: "POST") == 1)
    await h.store.stop()
  }
  @Test func writeFailuresAreVisibleAndDoNotDispatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not a directory".utf8).write(to: directory)
    let h = Harness(directory: directory)
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", text: "Keep in memory")
    await h.store.flushAuthored()
    #expect(h.store.authoredStorage == .writeFailed)
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example",
        input: .init(submissionId: "", text: "Example"))
      Issue.record("Must fail before POST")
    } catch {}
    #expect(h.store.journalStorage == .writeFailed)
    #expect(
      await h.transport.count("/api/v1/threads/thread-example/submissions", method: "POST") == 0)
    await h.store.stop()
  }
  @Test func budgetedReconciliationIsHeadlessAndDoesNotSubmit() async throws {
    let h = Harness()
    var cache = CacheRecord()
    cache.revision = 1
    cache.bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    var newer = cache.bootstrap!
    newer.threads[0].revision += 1
    await h.transport.set("/api/v1/bootstrap", [.response(try response(newer))])
    let api = APIClient(endpoint: Scenario.endpoint, transport: h.transport)
    let service = ReconciliationService(
      repository: h.repository, clock: h.clock, client: { _ in api })
    let skipped = try await service.refresh(profile: h.profile, budget: .init(maximumReads: 0))
    #expect(skipped.budgetExhausted && skipped.reads == 0)
    let changes = try await service.refresh(profile: h.profile, budget: .init(maximumReads: 1))
    #expect(changes.persisted && changes.reads == 1)
    #expect(changes.changedThreadIDs == ["thread-example"])
    #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
  }
}
