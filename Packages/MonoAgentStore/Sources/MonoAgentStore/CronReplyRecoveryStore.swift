// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

public struct CronReplyKey: Codable, Hashable, Sendable {
  public let sourceID: String
  public let jobID: String
  public let runID: String
  public init(sourceID: String, jobID: String, runID: String) {
    self.sourceID = sourceID
    self.jobID = jobID
    self.runID = runID
  }
}
public struct CronReplyReference: Codable, Equatable, Sendable {
  public let key: CronReplyKey
  public let operationID: UUID
  public let snapshotKind: String
  public init(key: CronReplyKey, operationID: UUID = UUID(), snapshotKind: String) {
    self.key = key
    self.operationID = operationID
    self.snapshotKind = snapshotKind
  }
  var valid: Bool {
    [key.sourceID, key.jobID, key.runID].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
      && ["summary", "detail"].contains(snapshotKind)
  }
}

/// Separate from the chat submission journal. Failure is always best-effort.
public protocol CronReplyPersistence: Sendable {
  func load(_ namespace: ConsoleNamespace) async throws -> [CronReplyReference]
  func save(_ references: [CronReplyReference], namespace: ConsoleNamespace, revision: UInt64)
    async throws
  func delete(profileID: UUID) async throws
}

public actor FileCronReplyPersistence: CronReplyPersistence {
  private let directory: URL
  private var deleted: Set<UUID> = []
  private var revisions: [ConsoleNamespace: UInt64] = [:]
  private struct Record: Codable {
    var version = 1
    var entries: [CronReplyReference]
  }
  public init(directory: URL) { self.directory = directory }
  private func file(_ namespace: ConsoleNamespace) -> URL {
    directory.appendingPathComponent(namespace.profileID.uuidString)
      .appendingPathComponent(namespace.identity).appendingPathComponent("cron-replies-v1.json")
  }
  public func load(_ namespace: ConsoleNamespace) throws -> [CronReplyReference] {
    guard !deleted.contains(namespace.profileID) else { return [] }
    let url = file(namespace)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= 128 * 1024 else { throw ConsoleStorageError.byteBudget }
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    guard record.version == 1, record.entries.count <= 32 else {
      throw ConsoleStorageError.invalidFormat
    }
    return record.entries.filter(\.valid)
  }
  public func save(
    _ references: [CronReplyReference], namespace: ConsoleNamespace, revision: UInt64
  ) throws {
    guard !deleted.contains(namespace.profileID) else { return }
    guard revision > (revisions[namespace] ?? 0) else { return }
    let entries = Array(references.filter(\.valid).prefix(32))
    let data = try JSONEncoder().encode(Record(entries: entries))
    guard data.count <= 128 * 1024 else { throw ConsoleStorageError.byteBudget }
    let url = file(namespace)
    var parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var attributes = URLResourceValues()
    attributes.isExcludedFromBackup = true
    try parent.setResourceValues(attributes)
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
    var target = url
    try target.setResourceValues(attributes)
    revisions[namespace] = revision
  }
  public func delete(profileID: UUID) throws {
    deleted.insert(profileID)
    let url = directory.appendingPathComponent(profileID.uuidString)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

/// Process-lifetime owner, injected into replacement Stores. Unresolved memory is never evicted.
/// Disk is an optional newest-32 hint, not admission authority or a chat-send dependency.
@MainActor @Observable public final class CronReplyRecoveryStore {
  @ObservationIgnored private let persistence: (any CronReplyPersistence)?
  private var references: [ConsoleNamespace: [CronReplyReference]] = [:]
  private var active: [ConsoleNamespace: Set<CronReplyKey>] = [:]
  @ObservationIgnored private var forgotten: Set<UUID> = []
  @ObservationIgnored private var deleted: Set<UUID> = []
  @ObservationIgnored private var loaded: Set<ConsoleNamespace> = []
  @ObservationIgnored private var loads: [ConsoleNamespace: Task<Void, Never>] = [:]
  @ObservationIgnored private var writes: [ConsoleNamespace: Task<Void, Never>] = [:]
  @ObservationIgnored private var revision: UInt64 = 0
  public init(persistence: (any CronReplyPersistence)? = nil) { self.persistence = persistence }
  public func hydrate(_ namespace: ConsoleNamespace) async {
    guard !deleted.contains(namespace.profileID), !loaded.contains(namespace) else { return }
    if let flight = loads[namespace] {
      await flight.value
      return
    }
    let task = Task { [weak self, persistence] in
      let entries = (try? await persistence?.load(namespace)) ?? []
      guard let self, !self.deleted.contains(namespace.profileID) else { return }
      for entry in entries.reversed()
      where entry.valid && !self.forgotten.contains(entry.operationID) {
        if self.reference(entry.key, namespace: namespace) == nil {
          self.references[namespace, default: []].insert(entry, at: 0)
        }
      }
      self.loaded.insert(namespace)
      self.loads[namespace] = nil
    }
    loads[namespace] = task
    await task.value
  }
  public func reference(_ key: CronReplyKey, namespace: ConsoleNamespace) -> CronReplyReference? {
    references[namespace]?.first { $0.key == key }
  }
  public func isActive(_ key: CronReplyKey, namespace: ConsoleNamespace) -> Bool {
    active[namespace]?.contains(key) == true
  }
  /// Reserves before any suspension or POST, including across Store replacement.
  func begin(_ key: CronReplyKey, snapshotKind: String, namespace: ConsoleNamespace)
    -> CronReplyReference?
  {
    guard !deleted.contains(namespace.profileID), !isActive(key, namespace: namespace) else {
      return nil
    }
    let reference =
      reference(key, namespace: namespace)
      ?? CronReplyReference(key: key, snapshotKind: snapshotKind)
    guard reference.valid else { return nil }
    active[namespace, default: []].insert(key)
    references[namespace, default: []].removeAll { $0.key == key }
    references[namespace, default: []].insert(reference, at: 0)
    persist(namespace)
    return reference
  }
  func finish(_ key: CronReplyKey, namespace: ConsoleNamespace) {
    active[namespace]?.remove(key)
  }
  func forget(_ reference: CronReplyReference, namespace: ConsoleNamespace) {
    forgotten.insert(reference.operationID)
    references[namespace]?.removeAll { $0.operationID == reference.operationID }
    persist(namespace)
  }
  private func persist(_ namespace: ConsoleNamespace) {
    guard !deleted.contains(namespace.profileID), let persistence else { return }
    revision &+= 1
    let revision = revision
    let snapshot = Array((references[namespace] ?? []).prefix(32))
    let previous = writes[namespace]
    writes[namespace] = Task {
      await previous?.value
      try? await persistence.save(snapshot, namespace: namespace, revision: revision)
    }
  }
  public func delete(profileID: UUID) async {
    // Fence synchronously, before any pending load or save can complete.
    deleted.insert(profileID)
    references = references.filter { $0.key.profileID != profileID }
    active = active.filter { $0.key.profileID != profileID }
    try? await persistence?.delete(profileID: profileID)
  }
  func settlePersistence(_ namespace: ConsoleNamespace) async { await writes[namespace]?.value }
}
