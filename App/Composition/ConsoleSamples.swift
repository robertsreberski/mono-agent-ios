// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore
  import MonoAgentTestSupport

  enum StoreScenario: String, CaseIterable {
    case offline = "store-offline"
    case streaming = "store-streaming"
    case unread = "store-unread"
    case uncertain = "store-uncertain"

    /// Scenario.bootstrap is the fictional composition derived from the pinned C1 golden.
    @MainActor func prepare(_ store: ConsoleStore, repository: any ConsoleRepository) async throws {
      let bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
      var cache = CacheRecord()
      cache.revision = 1
      cache.bootstrap = bootstrap
      var thread = bootstrap.threads[0]
      if self == .streaming { thread.runState.status = "running" }
      let message = try JSONDecoder().decode(
        WebMessage.self,
        from: Data(
          #"{"id":"message-example","threadId":"thread-example","turnId":"turn-example","role":"assistant","parts":[{"type":"text","text":"A fictional streamed answer"}],"attachments":[],"createdAt":"2030-01-02T12:00:00Z","updatedAt":"2030-01-02T12:00:00Z","status":"running","seq":1}"#
            .utf8))
      cache.conversations = [.init(thread: thread, messages: [message], savedAt: Date())]
      cache.buckets = [
        .init(key: .init(sourceID: thread.sourceId), threads: [thread], savedAt: Date())
      ]
      try await repository.saveCache(cache, namespace: store.namespace)
      var authored = AuthoredRecord()
      authored.revision = 1
      authored.seen = [.init(id: thread.id, revision: self == .unread ? 0 : thread.revision)]
      try await repository.saveAuthored(authored, namespace: store.namespace)
      if self == .uncertain {
        var journal = JournalRecord()
        journal.revision = 1
        journal.pending = [
          .init(
            threadID: thread.id, submissionID: "00000000-0000-0000-0000-000000000001",
            payloadDigest: "fictional-digest",
            draftKey: .init(profileID: store.profile.id, sourceID: thread.sourceId),
            draftVersion: nil, dispatched: true)
        ]
        try await repository.saveJournal(journal, namespace: store.namespace)
      }
    }
  }

  actor ScenarioConsoleTransport: HTTPTransport {
    let scenario: StoreScenario?
    init(_ scenario: StoreScenario?) { self.scenario = scenario }
    func send(_ request: URLRequest) throws -> HTTPResponse {
      guard scenario != .offline else { throw URLError(.notConnectedToInternet) }
      if request.url?.path == "/api/v1/bootstrap" {
        var value = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
        if scenario == .streaming { value.threads[0].runState.status = "running" }
        return HTTPResponse(data: try JSONEncoder().encode(value))
      }
      if request.url?.path == "/api/v1/threads/thread-example" {
        var thread = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
          .threads[0]
        if scenario == .streaming { thread.runState.status = "running" }
        let json: JSONValue = .object([
          "thread": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(thread)),
          "messages": .array([]), "messagesNextCursor": .null,
        ])
        return HTTPResponse(data: try JSONEncoder().encode(json))
      }
      // Exhaustion never falls through to a live session, including receipt recovery.
      throw URLError(.resourceUnavailable)
    }
  }
  actor ScenarioEventSource: ConsoleEventSource {
    let scenario: StoreScenario?
    var continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation?
    init(_ scenario: StoreScenario?) { self.scenario = scenario }
    func subscribe(thread: String?, capacity: Int) -> AsyncThrowingStream<StreamUpdate, any Error> {
      continuation?.finish()
      let pair = AsyncThrowingStream<StreamUpdate, any Error>.makeStream()
      continuation = pair.continuation
      if scenario != .offline {
        pair.continuation.yield(.connecting(generation: 1, gap: .initial))
        if let ready = try? JSONDecoder().decode(
          ApiEvent.self,
          from: Data(
            #"{"id":"ready-example","version":1,"type":"ready","at":"2030-01-02T12:00:00Z","payload":{"version":1}}"#
              .utf8))
        {
          pair.continuation.yield(.event(generation: 1, gap: .initial, ready))
        }
      }
      return pair.stream
    }
    func cancel() {
      continuation?.finish()
      continuation = nil
    }
  }
#endif
