// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgent
@testable import MonoAgentStore

private actor CompositionRepository: ConsoleRepository {
  let base = FileConsoleRepository(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  var pauseCache = false
  var pauseAuthored = false
  var cacheWaiter: CheckedContinuation<Void, Never>?
  var authoredWaiter: CheckedContinuation<Void, Never>?
  var hydratedDuringFinalSave = false
  func pauseNextCacheLoad() { pauseCache = true }
  func pauseNextAuthoredSave() { pauseAuthored = true }
  func cacheIsPaused() -> Bool { cacheWaiter != nil }
  func authoredIsPaused() -> Bool { authoredWaiter != nil }
  func releaseCache() {
    cacheWaiter?.resume()
    cacheWaiter = nil
  }
  func releaseAuthored() {
    authoredWaiter?.resume()
    authoredWaiter = nil
  }
  func loadCache(_ namespace: ConsoleNamespace) async throws -> CacheRecord {
    if authoredWaiter != nil { hydratedDuringFinalSave = true }
    if pauseCache {
      pauseCache = false
      await withCheckedContinuation { cacheWaiter = $0 }
    }
    return try await base.loadCache(namespace)
  }
  func loadAuthored(_ namespace: ConsoleNamespace) async throws -> AuthoredRecord {
    try await base.loadAuthored(namespace)
  }
  func loadJournal(_ namespace: ConsoleNamespace) async throws -> JournalRecord {
    try await base.loadJournal(namespace)
  }
  func saveCache(_ record: CacheRecord, namespace: ConsoleNamespace) async throws
    -> RepositorySaveResult
  { try await base.saveCache(record, namespace: namespace) }
  func saveAuthored(_ record: AuthoredRecord, namespace: ConsoleNamespace) async throws
    -> RepositorySaveResult
  {
    if pauseAuthored {
      pauseAuthored = false
      await withCheckedContinuation { authoredWaiter = $0 }
    }
    return try await base.saveAuthored(record, namespace: namespace)
  }
  func saveJournal(_ record: JournalRecord, namespace: ConsoleNamespace) async throws
    -> RepositorySaveResult
  { try await base.saveJournal(record, namespace: namespace) }
  func delete(profileID: UUID) async throws { try await base.delete(profileID: profileID) }
}
@MainActor
private func waitForComposition(_ condition: () async -> Bool) async {
  for _ in 0..<10_000 {
    if await condition() { return }
    await Task.yield()
  }
  Issue.record("Composition never reached the controlled checkpoint")
}
#if DEBUG
  @MainActor
  struct CompositionSerializationTests {
    @Test func rapidSynchronizationsAwaitFinalFlushBeforeSameNamespaceHydration() async throws {
      let repository = CompositionRepository()
      let model = AppModel(scenario: .consoleOnline, consoleRepository: repository)
      await model.start()
      let old = try #require(model.store)
      let id = try #require(model.registry.selectedID)
      await old.setDraft(
        sourceID: "agent-example", threadID: "thread-example", text: "Draft to clear")
      await old.flushAuthored()
      await old.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "")
      old.draftTask?.cancel()
      await repository.pauseNextAuthoredSave()
      _ = try await model.registry.add(
        name: "Other fixture", endpoint: Scenario.endpoint, httpAcknowledged: false)
      let first = Task { await model.synchronizeStore() }
      await waitForComposition { await repository.authoredIsPaused() }
      #expect(model.store == nil)
      await model.registry.select(id)
      var entered = false
      let second = Task {
        entered = true
        await model.synchronizeStore()
      }
      await waitForComposition { entered }
      #expect(
        model.store == nil, "A second call must wait for the old store's final authored checkpoint")
      await repository.releaseAuthored()
      await first.value
      await second.value
      let next = try #require(model.store)
      #expect(next !== old)
      #expect(next.namespace == old.namespace)
      #expect(next.hydrated)
      #expect(next.draft(sourceID: "agent-example", threadID: "thread-example") == nil)
      #expect(await repository.hydratedDuringFinalSave == false)
      await next.stop()
    }

    @Test(arguments: [false, true])
    func connectionShellReadinessDoesNotWaitForStoreIOButStoreFixtureReadinessDoes(
      waitForStoreFixture: Bool
    ) async throws {
      let repository = CompositionRepository()
      await repository.pauseNextCacheLoad()
      let model = AppModel(
        scenario: .consoleOnline, storeScenario: waitForStoreFixture ? .offline : nil,
        consoleRepository: repository)
      let start = Task { await model.start() }
      await waitForComposition { await repository.cacheIsPaused() }
      #expect(model.connectedProfile != nil)
      #expect(model.store?.hydrated == false)
      #expect(model.isReady == !waitForStoreFixture)
      await repository.releaseCache()
      await start.value
      #expect(model.isReady)
      #expect(model.store?.hydrated == true)
      await model.store?.stop()
    }
  }
#endif
