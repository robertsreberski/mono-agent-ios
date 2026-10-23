// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct SearchTests {
  private func searchPage(_ threads: [WebThread], truncated: Bool = false) throws -> HTTPResponse {
    let hits: [JSONValue] = try threads.map { thread in
      .object([
        "thread": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(thread)),
        "snippet": .string("a \u{2}fictional\u{3} match"), "messageMatches": .number(2),
        "titleMatch": .bool(false),
      ])
    }
    return try response(JSONValue.object(["hits": .array(hits), "truncated": .bool(truncated)]))
  }

  private func started() async throws -> Harness {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    return h
  }

  @Test func shortQueriesNeverRequest() async throws {
    let h = try await started()
    for query in ["", " ", "a", " b \n"] {
      let result = try await h.store.searchThreads(sourceID: "agent-example", query: query)
      #expect(result == ThreadSearchResult())
    }
    #expect(await h.transport.count("/api/v1/threads/search") == 0)
    await h.store.stop()
  }

  @Test func searchUsesChatsScopeTrimmedQueryAndLeavesProjectionsAlone() async throws {
    let h = try await started()
    let bucketsBefore = h.store.buckets.mapValues(\.threads)
    var hit = try sampleThread("thread-hit", revision: 9)
    hit.title = "Fictional result"
    await h.transport.set(
      "/api/v1/threads/search", [.response(try searchPage([hit], truncated: true))])
    let result = try await h.store.searchThreads(sourceID: "agent-example", query: "  fictional ")
    #expect(result.hits.map(\.thread.id) == ["thread-hit"])
    #expect(result.hits.first?.messageMatches == 2)
    #expect(result.truncated)
    let request = try #require(
      await h.transport.requests.last { $0.url?.path == "/api/v1/threads/search" })
    let items =
      URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "q", value: "fictional")))
    #expect(items.contains(URLQueryItem(name: "scope", value: "chats")))
    #expect(items.contains(URLQueryItem(name: "sourceId", value: "agent-example")))
    #expect(h.store.buckets.mapValues(\.threads) == bucketsBefore)
    #expect(h.store.conversations["thread-hit"] == nil)
    #expect(!h.store.isRunningConfirmed(threadID: "thread-hit"))
    await h.store.stop()
  }

  @Test func offlineHydratedOrStoppedStoreRefusesWithoutNetwork() async throws {
    let h = Harness()
    await h.store.hydrate()
    await #expect(throws: ConsoleSearchError.unavailable) {
      try await h.store.searchThreads(sourceID: "agent-example", query: "fictional")
    }
    let live = try await started()
    await live.store.scenePhaseChanged(.background)
    await #expect(throws: ConsoleSearchError.unavailable) {
      try await live.store.searchThreads(sourceID: "agent-example", query: "fictional")
    }
    await live.store.stop()
    #expect(await h.transport.count("/api/v1/threads/search") == 0)
    #expect(await live.transport.count("/api/v1/threads/search") == 0)
  }

  @Test func lateResultAfterStopIsDiscarded() async throws {
    let h = try await started()
    await h.transport.set("/api/v1/threads/search", [.paused])
    let search = Task {
      try await h.store.searchThreads(sourceID: "agent-example", query: "fictional")
    }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.stop()
    await h.transport.release(try searchPage([try sampleThread("thread-late")]))
    await #expect(throws: CancellationError.self) { try await search.value }
  }

  @Test func tombstonedHitsStayHidden() async throws {
    let h = try await started()
    h.store.removeThread("thread-gone")
    await h.transport.set(
      "/api/v1/threads/search",
      [
        .response(
          try searchPage([try sampleThread("thread-gone"), try sampleThread("thread-kept")]))
      ])
    let result = try await h.store.searchThreads(sourceID: "agent-example", query: "fictional")
    #expect(result.hits.map(\.thread.id) == ["thread-kept"])
    await h.store.stop()
  }

  @Test func clearingTheErrorMessageKeepsPersistenceStates() async throws {
    let h = Harness()
    await h.store.hydrate()
    h.store.errorMessage = "Conversation list could not be refreshed."
    h.store.storage = .writeFailed
    h.store.clearErrorMessage()
    #expect(h.store.errorMessage == nil)
    #expect(h.store.storage == .writeFailed)
    await h.store.stop()
  }
}
