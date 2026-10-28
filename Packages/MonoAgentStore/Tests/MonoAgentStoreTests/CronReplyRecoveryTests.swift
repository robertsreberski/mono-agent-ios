// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentStore

@MainActor struct CronReplyRecoveryTests {
  func key(_ number: Int = 1) -> CronReplyKey {
    .init(sourceID: "agent-example", jobID: "sample-digest", runID: "run-\(number)")
  }
  @Test func pendingOptionalLoadDoesNotGateChatJournalHydration() async throws {
    let disk = PausedCronPersistence()
    let registry = CronReplyRecoveryStore(persistence: disk)
    let h = Harness(cronReplyRecovery: registry)
    await h.store.hydrate()
    await eventually { await disk.isPaused() }
    #expect(h.store.hydrated && h.store.journalStorage == .durable)
    #expect(h.store.authoredStorage == .durable && h.store.pendingSubmissions.isEmpty)
    await h.transport.set(submissionPath, [.paused])
    let input = h.store.prepareSubmission(.init(submissionId: "", text: "Fictional chat reply"))
    let send = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input,
        attemptID: input.submissionId)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    let reference = try #require(h.store.pendingSubmissions.first)
    await h.transport.release(try admission(reference))
    let receipt = try await send.value
    #expect(receipt.submissionId == reference.submissionID)
    #expect(await disk.isPaused())
    #expect(h.store.journalStorage == .durable && h.store.pendingSubmissions.isEmpty)
    await disk.release()
    await registry.hydrate(h.store.namespace)
  }
  @Test func refusedStorageDoesNotEvictMemoryOrChangeRetrySnapshot() async throws {
    let h = try await AutomationsTests().live()
    let disk = RefusedCronPersistence()
    let registry = CronReplyRecoveryStore(persistence: disk)
    await registry.hydrate(h.store.namespace)
    let first = try #require(
      registry.begin(key(), snapshotKind: "summary", namespace: h.store.namespace))
    #expect(registry.begin(key(), snapshotKind: "detail", namespace: h.store.namespace) == nil)
    registry.finish(key(), namespace: h.store.namespace)
    for number in 2...40 {
      _ = registry.begin(key(number), snapshotKind: "summary", namespace: h.store.namespace)
      registry.finish(key(number), namespace: h.store.namespace)
    }
    await registry.settlePersistence(h.store.namespace)
    let retry = registry.begin(key(), snapshotKind: "detail", namespace: h.store.namespace)
    #expect(retry == first)
    #expect(h.store.journalStorage == .durable && h.store.journal.pending.isEmpty)
    #expect(await disk.largestWrite() == 32)
  }
  @Test func optionalFileRestoresNewest32AndDeletionFencesLateWrites() async throws {
    let h = try await AutomationsTests().live()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = FileCronReplyPersistence(directory: directory)
    let registry = CronReplyRecoveryStore(persistence: disk)
    var newest: CronReplyReference?
    for number in 1...40 {
      newest = registry.begin(key(number), snapshotKind: "detail", namespace: h.store.namespace)
      registry.finish(key(number), namespace: h.store.namespace)
    }
    await registry.settlePersistence(h.store.namespace)
    let relaunched = CronReplyRecoveryStore(
      persistence: FileCronReplyPersistence(directory: directory))
    await relaunched.hydrate(h.store.namespace)
    #expect(relaunched.reference(key(40), namespace: h.store.namespace) == newest)
    #expect(relaunched.reference(key(1), namespace: h.store.namespace) == nil)
    let url = directory.appendingPathComponent(h.profile.id.uuidString)
      .appendingPathComponent(h.store.namespace.identity).appendingPathComponent(
        "cron-replies-v1.json")
    #expect(
      try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    // Queue an actual registry write immediately before deletion, without settling it.
    _ = registry.begin(key(41), snapshotKind: "summary", namespace: h.store.namespace)
    await registry.delete(profileID: h.profile.id)
    await registry.settlePersistence(h.store.namespace)
    try await disk.save([try #require(newest)], namespace: h.store.namespace, revision: 999)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(registry.begin(key(), snapshotKind: "summary", namespace: h.store.namespace) == nil)
  }
  @Test func forgottenIdentityCannotRehydrateFromPendingStaleLoad() async throws {
    let h = try await AutomationsTests().live()
    let old = CronReplyReference(key: key(), snapshotKind: "summary")
    let disk = PausedCronPersistence()
    let registry = CronReplyRecoveryStore(persistence: disk)
    let hydration = Task { await registry.hydrate(h.store.namespace) }
    await eventually { await disk.isPaused() }
    registry.forget(old, namespace: h.store.namespace)
    await registry.settlePersistence(h.store.namespace)
    await disk.release([old])
    await hydration.value
    #expect(registry.isHydrated(h.store.namespace))
    #expect(registry.reference(key(), namespace: h.store.namespace) == nil)
    let new = registry.begin(key(), snapshotKind: "detail", namespace: h.store.namespace)
    #expect(new?.operationID != old.operationID && new?.snapshotKind == "detail")
  }
  @Test func corruptOversizedAndUnavailableFilesAreOptional() async throws {
    let h = try await AutomationsTests().live()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent(h.profile.id.uuidString)
      .appendingPathComponent(h.store.namespace.identity)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let url = parent.appendingPathComponent("cron-replies-v1.json")
    for data in [Data("broken".utf8), Data(repeating: 32, count: 129 * 1024)] {
      try data.write(to: url)
      let registry = CronReplyRecoveryStore(
        persistence: FileCronReplyPersistence(directory: directory))
      await registry.hydrate(h.store.namespace)
      #expect(registry.begin(key(), snapshotKind: "summary", namespace: h.store.namespace) != nil)
      await registry.settlePersistence(h.store.namespace)
    }
  }
}

actor RefusedCronPersistence: CronReplyPersistence {
  private let entries: [CronReplyReference]
  private var maximum = 0
  init(entries: [CronReplyReference] = []) { self.entries = entries }
  func load(_ namespace: ConsoleNamespace) -> [CronReplyReference] { entries }
  func save(_ references: [CronReplyReference], namespace: ConsoleNamespace, revision: UInt64)
    throws
  {
    maximum = max(maximum, references.count)
    throw ConsoleStorageError.unavailable
  }
  func delete(profileID: UUID) throws { throw ConsoleStorageError.unavailable }
  func largestWrite() -> Int { maximum }
}

actor PausedCronPersistence: CronReplyPersistence {
  private var waiter: CheckedContinuation<[CronReplyReference], Never>?
  func load(_ namespace: ConsoleNamespace) async -> [CronReplyReference] {
    await withCheckedContinuation { waiter = $0 }
  }
  func isPaused() -> Bool { waiter != nil }
  func release(_ entries: [CronReplyReference] = []) {
    waiter?.resume(returning: entries)
    waiter = nil
  }
  func save(_ references: [CronReplyReference], namespace: ConsoleNamespace, revision: UInt64) {}
  func delete(profileID: UUID) {}
}
