// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct SyncPersistenceCorrectionTests {
  @Test func offlineHydrationAndTerminalParkingCannotStartNetworkOnForeground() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.scenePhaseChanged(.background)
    await h.store.scenePhaseChanged(.active)
    #expect(await h.events.count() == 0)
    #expect(await h.transport.requests.isEmpty)
    await h.store.start()
    let subscriptions = await h.events.count()
    let reads = await h.transport.requests.count
    await h.store.stop()
    await h.store.scenePhaseChanged(.active)
    await h.store.networkChanged(reachable: true, constrained: false)
    #expect(await h.events.count() == subscriptions)
    #expect(await h.transport.requests.count == reads)
  }
  @Test func backgroundDuringInitialHydrationResumesHydrationAndRecovery() async throws {
    let h = CorrectionHarness()
    let reference = prepared(profileID: h.profile.id, createdAt: Date(), dispatched: true)
    var journal = JournalRecord()
    journal.revision = 1
    journal.pending = [reference]
    try await h.repository.saveJournal(journal, namespace: h.store.namespace)
    await h.repository.pauseNextCacheLoad()
    let start = Task { await h.store.start() }
    await eventually { await h.repository.isPaused() }
    await h.store.scenePhaseChanged(.background)
    await h.repository.releaseCache()
    await start.value
    #expect(!h.store.hydrated)
    await h.store.scenePhaseChanged(.active)
    #expect(h.store.hydrated)
    #expect(await h.events.count() == 1)
    #expect(await h.transport.count(submissionPath + "/" + reference.submissionID) == 1)
    await h.store.setDraft(sourceID: "agent-example", text: "Restored drafting")
    await h.store.flushAuthored()
    #expect(try await h.repository.loadAuthored(h.store.namespace).drafts.count == 1)
    await h.store.stop()
  }
  @Test func selectionChangeDuringGapBootstrapKeepsGlobalRefreshButRejectsOldBucket() async throws {
    let h = Harness()
    h.store.selectedBucket = BucketKey(sourceID: "agent-example")
    h.store.needsBootstrap = true
    await h.transport.set("/api/v1/bootstrap", [.paused])
    let pass = Task { await h.store.reconcile() }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    h.store.selectedBucket = BucketKey(sourceID: "other-agent")
    await h.store.receive(.connecting(generation: 1, gap: .subscriptionChanged))
    var bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    bootstrap.agents[0].label = "Refreshed fictional agent"
    await h.transport.release(try response(bootstrap))
    await pass.value
    #expect(h.store.agents.first?.label == "Refreshed fictional agent")
    #expect(h.store.freshness == .fresh)
    #expect(h.store.buckets[BucketKey(sourceID: "agent-example")] == nil)
    await h.store.stop()
  }
  @Test func single404IsNotPermanentAndNewerAuthoritativeSummaryLiftsConfirmedDeletion()
    async throws
  {
    let h = Harness()
    try h.seed(revision: 5)
    await h.transport.set(
      "/api/v1/threads/thread-example",
      [
        .response(notFound()), .response(notFound()),
        .response(try detailResponse(thread: sampleThread(revision: 6))),
      ])
    await h.store.refreshDetail("thread-example")
    #expect(h.store.conversations["thread-example"] != nil)
    #expect(h.store.tombstones.isEmpty)
    await h.store.refreshDetail("thread-example")
    #expect(h.store.conversations.isEmpty)
    #expect(h.store.tombstones["thread-example"]?.revision == 5)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 5)], cursor: nil,
      older: false, fresh: true)
    #expect(h.store.tombstones["thread-example"] != nil)
    h.store.mergeBucket(
      .init(sourceID: "agent-example"), rows: [try sampleThread(revision: 6)], cursor: nil,
      older: false, fresh: true)
    #expect(h.store.tombstones.isEmpty)
    await h.store.refreshDetail("thread-example")
    #expect(h.store.conversations["thread-example"]?.thread.revision == 6)
    await h.store.stop()
  }
  @Test func tombstonesAreBoundedInMemoryAndOnDiskByCountAndAge() async throws {
    let h = Harness()
    await h.store.hydrate()
    for index in 0..<300 { h.store.removeThread("thread-\(index)") }
    #expect(h.store.tombstones.count == ConsoleBounds.tombstoneCount)
    h.store.tombstones["expired"] = .init(
      revision: 1, removedAt: Date().addingTimeInterval(-ConsoleBounds.tombstoneAge - 1))
    await h.store.flushCache()
    let cache = try await h.repository.loadCache(h.store.namespace)
    #expect(cache.tombstones.count == ConsoleBounds.tombstoneCount)
    #expect(cache.tombstones["expired"] == nil)
    await h.store.stop()
  }
  @Test func staleAndEqualSavesReturnSupersededAndSeparateRepositoryInstancesObserveDisk()
    async throws
  {
    let h = Harness()
    var cache = CacheRecord()
    cache.revision = 1
    #expect(try await h.repository.saveCache(cache, namespace: h.store.namespace) == .saved)
    #expect(
      try await h.repository.saveCache(cache, namespace: h.store.namespace)
        == .superseded(revision: 1))
    let second = FileConsoleRepository(directory: h.directory)
    var authored = AuthoredRecord()
    authored.revision = 2
    var journal = JournalRecord()
    journal.revision = 2
    #expect(try await second.saveAuthored(authored, namespace: h.store.namespace) == .saved)
    #expect(try await second.saveJournal(journal, namespace: h.store.namespace) == .saved)
    authored.revision = 1
    journal.revision = 1
    #expect(
      try await h.repository.saveAuthored(authored, namespace: h.store.namespace)
        == .superseded(revision: 2))
    #expect(
      try await h.repository.saveJournal(journal, namespace: h.store.namespace)
        == .superseded(revision: 2))
  }
  @Test func recreatedStoreAndHeadlessRefreshRebaseOnceWithoutLosingNewerTranscript() async throws {
    let h = Harness()
    await h.store.hydrate()
    let api = APIClient(endpoint: Scenario.endpoint, transport: h.transport)
    let service = ReconciliationService(
      repository: h.repository, clock: h.clock, client: { _ in api })
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap), .paused])
    let first = try await service.refresh(profile: h.profile, budget: .init())
    #expect(first.persisted)
    try h.seed(messages: [sampleMessage(seq: 10)], revision: 10)
    await h.store.flushCache()
    #expect(h.store.storage == .durable)
    #expect(try await h.repository.loadCache(h.store.namespace).bootstrap != nil)
    let refresh = Task { try await service.refresh(profile: h.profile, budget: .init()) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.conversations["thread-example"]?.record.messages[0].seq = 11
    await h.store.flushCache()
    await h.transport.release(Scenario.bootstrap)
    let changed = try await refresh.value
    #expect(changed.persisted && changed.saveResult == .saved)
    let final = try await h.repository.loadCache(h.store.namespace)
    #expect(final.conversations.first?.messages.first?.seq == 11)
    #expect(final.bootstrap?.agents.isEmpty == false)
    await h.store.stop()
  }
  @Test func authoredRetryFailureCannotKeepEarlierDurableState() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    var disk = AuthoredRecord()
    disk.revision = 10
    try await h.repository.base.saveAuthored(disk, namespace: h.store.namespace)
    await h.repository.failAuthored([2])
    await h.store.setDraft(sourceID: "agent-example", text: "New draft")
    await h.store.flushAuthored()
    #expect(h.store.authoredStorage == .writeFailed)
    await h.store.stop()
  }
  @Test func repeatedSupersedingDoesNotClaimDurabilityOrPersistedSuccess() async throws {
    let h = CorrectionHarness()
    await h.store.hydrate()
    await h.repository.supersedeCache(2)
    await h.store.flushCache()
    #expect(h.store.storage == .superseded)
    await h.repository.supersedeCache(2)
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    let api = APIClient(endpoint: Scenario.endpoint, transport: h.transport)
    let service = ReconciliationService(
      repository: h.repository, clock: h.clock, client: { _ in api })
    let summary = try await service.refresh(profile: h.profile, budget: .init())
    #expect(!summary.persisted)
    #expect(summary.saveResult == .superseded(revision: 99))
    await h.store.stop()
  }
  @Test func sanitizerKeepsDurableStoredURLAndOpaqueToolTokenFields() async throws {
    let h = Harness()
    var message = try sampleMessage()
    message.parts = [
      try decode(
        #"{"type":"attachment","id":"part-example","artifactId":"artifact-example","name":"sample.png","mediaType":"image/png","sizeBytes":4,"integrityId":"example","storedUrl":"/api/v1/uploads/upload-example/content","contentUrl":"/api/v1/threads/thread-example/files?token=fictional&expires=1","expiresAt":"2030-01-02T12:00:00Z"}"#,
        as: WebMessagePart.self),
      try decode(
        #"{"type":"tool-call","toolCallId":"tool-example","toolName":"example","status":"complete","result":{"token":"fictional business data","expiresAt":"2030-01-02T12:00:00Z","contentUrl":"opaque-output"}}"#,
        as: WebMessagePart.self),
    ]
    var cache = CacheRecord()
    cache.revision = 1
    cache.conversations = [.init(thread: try sampleThread(), messages: [message], savedAt: Date())]
    try await h.repository.saveCache(cache, namespace: h.store.namespace)
    let restored = try await h.repository.loadCache(h.store.namespace)
    let parts = try #require(restored.conversations.first?.messages.first?.parts)
    guard case .attachment(let attachment) = parts[0], case .toolCall(let tool) = parts[1] else {
      Issue.record("Expected typed parts")
      return
    }
    #expect(attachment.storedUrl == "/api/v1/uploads/upload-example/content")
    #expect(attachment.contentUrl == nil)
    #expect(attachment.expiresAt == "2030-01-02T12:00:00Z")
    #expect(
      tool.result
        == .object([
          "token": .string("fictional business data"), "expiresAt": .string("2030-01-02T12:00:00Z"),
          "contentUrl": .string("opaque-output"),
        ]))
  }
  @Test func namespaceAndReplacedFilesRemainExcludedFromBackup() async throws {
    let h = Harness()
    for revision in 1...2 {
      var cache = CacheRecord()
      cache.revision = UInt64(revision)
      var authored = AuthoredRecord()
      authored.revision = UInt64(revision)
      var journal = JournalRecord()
      journal.revision = UInt64(revision)
      try await h.repository.saveCache(cache, namespace: h.store.namespace)
      try await h.repository.saveAuthored(authored, namespace: h.store.namespace)
      try await h.repository.saveJournal(journal, namespace: h.store.namespace)
      let directory = h.directory.appendingPathComponent(h.profile.id.uuidString)
        .appendingPathComponent(h.store.namespace.identity)
      for url in [directory]
        + ["cache", "authored", "journal"].map({ directory.appendingPathComponent($0 + "-v1.json") }
        )
      {
        #expect(
          try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // CoreSimulator exposes no Data Protection attribute; assert it on physical iOS.
        #if os(iOS) && !targetEnvironment(simulator)
          if url != directory {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(
              attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication)
          }
        #endif
      }
    }
  }
}
