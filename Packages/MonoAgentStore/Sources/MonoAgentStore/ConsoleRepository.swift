// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum RepositorySaveResult: Sendable, Equatable {
  case saved
  case superseded(revision: UInt64)
}

public protocol ConsoleRepository: Sendable {
  func loadCache(_ namespace: ConsoleNamespace) async throws -> CacheRecord
  func loadAuthored(_ namespace: ConsoleNamespace) async throws -> AuthoredRecord
  func loadJournal(_ namespace: ConsoleNamespace) async throws -> JournalRecord
  @discardableResult func saveCache(_ record: CacheRecord, namespace: ConsoleNamespace) async throws
    -> RepositorySaveResult
  @discardableResult func saveAuthored(_ record: AuthoredRecord, namespace: ConsoleNamespace)
    async throws -> RepositorySaveResult
  @discardableResult func saveJournal(_ record: JournalRecord, namespace: ConsoleNamespace)
    async throws -> RepositorySaveResult
  func delete(profileID: UUID) async throws
}

/// Each record has an independent monotonic revision and atomic replacement. A failed load
/// preserves the original file and disables writes for that record for this repository lifetime.
public actor FileConsoleRepository: ConsoleRepository {
  private let directory: URL
  private var revisions: [URL: UInt64] = [:]
  private var blocked: Set<URL> = []
  private var deletedProfiles: Set<UUID> = []
  private let now: @Sendable () -> Date
  public init(
    directory: URL = URL.applicationSupportDirectory.appendingPathComponent("MonoAgent/Consoles"),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directory = directory
    self.now = now
  }
  private func file(_ namespace: ConsoleNamespace, _ name: String) -> URL {
    directory.appendingPathComponent(namespace.profileID.uuidString)
      .appendingPathComponent(namespace.identity).appendingPathComponent(name + "-v1.json")
  }
  private func load<T: Decodable>(
    _ type: T.Type, at url: URL, empty: T,
    version: (T) -> Int, revision: (T) -> UInt64, budget: Int
  ) throws -> T {
    guard !blocked.contains(url) else { throw ConsoleStorageError.unavailable }
    guard FileManager.default.fileExists(atPath: url.path) else { return empty }
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= budget else { throw ConsoleStorageError.byteBudget }
      let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
      guard version(value) == 1 else { throw ConsoleStorageError.invalidFormat }
      revisions[url] = max(revisions[url] ?? 0, revision(value))
      return value
    } catch {
      blocked.insert(url)
      throw error
    }
  }
  public func loadCache(_ namespace: ConsoleNamespace) throws -> CacheRecord {
    var record = try load(
      CacheRecord.self, at: file(namespace, "cache"), empty: CacheRecord(),
      version: { $0.version }, revision: { $0.revision }, budget: ConsoleBounds.cacheBytes)
    record = try bounded(record)
    return record
  }
  public func loadAuthored(_ namespace: ConsoleNamespace) throws -> AuthoredRecord {
    let value = try load(
      AuthoredRecord.self, at: file(namespace, "authored"), empty: AuthoredRecord(),
      version: { $0.version }, revision: { $0.revision }, budget: ConsoleBounds.authoredBytes)
    return try bounded(value)
  }
  public func loadJournal(_ namespace: ConsoleNamespace) throws -> JournalRecord {
    try load(
      JournalRecord.self, at: file(namespace, "journal"), empty: JournalRecord(),
      version: { $0.version }, revision: { $0.revision }, budget: ConsoleBounds.journalBytes)
  }
  @discardableResult public func saveCache(_ record: CacheRecord, namespace: ConsoleNamespace)
    throws -> RepositorySaveResult
  {
    guard !deletedProfiles.contains(namespace.profileID) else {
      throw ConsoleStorageError.unavailable
    }
    let url = file(namespace, "cache")
    if revisions[url] == nil { _ = try loadCache(namespace) }
    // Retain evicted in-memory conversations on disk, up to the independent 24-entry bound.
    var merged = record
    let old = try loadCache(namespace)
    merged.bootstrap = record.bootstrap ?? old.bootstrap
    let ids = Set(record.conversations.map { $0.thread.id })
    merged.conversations += old.conversations.filter {
      !ids.contains($0.thread.id) && record.tombstones[$0.thread.id] == nil
    }
    return try write(
      bounded(merged), at: url, revision: record.revision, budget: ConsoleBounds.cacheBytes)
  }
  @discardableResult public func saveAuthored(_ record: AuthoredRecord, namespace: ConsoleNamespace)
    throws -> RepositorySaveResult
  {
    guard !deletedProfiles.contains(namespace.profileID) else {
      throw ConsoleStorageError.unavailable
    }
    let url = file(namespace, "authored")
    _ = try loadAuthored(namespace)
    return try write(
      bounded(record), at: url, revision: record.revision, budget: ConsoleBounds.authoredBytes)
  }
  @discardableResult public func saveJournal(_ record: JournalRecord, namespace: ConsoleNamespace)
    throws -> RepositorySaveResult
  {
    guard !deletedProfiles.contains(namespace.profileID) else {
      throw ConsoleStorageError.unavailable
    }
    let url = file(namespace, "journal")
    _ = try loadJournal(namespace)
    return try write(record, at: url, revision: record.revision, budget: ConsoleBounds.journalBytes)
  }
  public func delete(profileID: UUID) throws {
    deletedProfiles.insert(profileID)
    let url = directory.appendingPathComponent(profileID.uuidString)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    revisions = revisions.filter { !$0.key.path.hasPrefix(url.path + "/") }
    blocked = blocked.filter { !$0.path.hasPrefix(url.path + "/") }
  }
  private func write<T: Encodable>(_ record: T, at url: URL, revision: UInt64, budget: Int) throws
    -> RepositorySaveResult
  {
    guard !blocked.contains(url) else { throw ConsoleStorageError.unavailable }
    if let latest = revisions[url], revision <= latest { return .superseded(revision: latest) }
    let data = try JSONEncoder().encode(record)
    guard data.count <= budget else { throw ConsoleStorageError.byteBudget }
    var parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try parent.setResourceValues(values)
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
    var target = url
    try target.setResourceValues(values)
    revisions[url] = revision
    return .saved
  }
  private func bounded(_ input: CacheRecord) throws -> CacheRecord {
    var record = try CacheSanitizer.sanitize(input)
    record.tombstones = CacheMerge.prune(record.tombstones, now: now())
    let cutoff = now().addingTimeInterval(-ConsoleBounds.maxAge)
    record.conversations = try record.conversations.filter {
      $0.savedAt >= cutoff && record.tombstones[$0.thread.id] == nil
    }
    .sorted { $0.savedAt > $1.savedAt }.prefix(ConsoleBounds.diskConversations).map(
      CacheSanitizer.conversation)
    for index in record.conversations.indices {
      while try JSONEncoder().encode(record.conversations[index]).count
        > ConsoleBounds.conversationBytes,
        !record.conversations[index].messages.isEmpty
      {
        record.conversations[index].messages.removeFirst()
        record.conversations[index].truncated = true
        // The ordinary cursor may skip pruned rows: require a fresh detail before paging.
        record.conversations[index].nextCursor = nil
      }
    }
    let sanitized = Dictionary(
      record.conversations.map { ($0.thread.id, $0.thread) },
      uniquingKeysWith: { first, _ in first })
    func summary(_ incoming: WebThread) -> WebThread {
      var row = incoming
      row.compaction = nil
      if let cleaned = sanitized[row.id], cleaned.revision == row.revision { return cleaned }
      return row
    }
    record.buckets = record.buckets.filter { $0.savedAt >= cutoff }
    record.buckets = Array(record.buckets.sorted { $0.savedAt > $1.savedAt }.prefix(24))
    for index in record.buckets.indices {
      record.buckets[index].freshness = .stale
      record.buckets[index].threads = record.buckets[index].threads.map(summary)
    }
    if var bootstrap = record.bootstrap {
      bootstrap.threads = bootstrap.threads.map(summary)
      if var fleet = bootstrap.activeThreads {
        fleet.threads = fleet.threads.map(summary)
        bootstrap.activeThreads = fleet
      }
      record.bootstrap = bootstrap
    }
    // Summary metadata alone can exceed the budget: fail visibly rather than lose authored state.
    while try JSONEncoder().encode(record).count > ConsoleBounds.cacheBytes,
      !record.conversations.isEmpty
    {
      record.conversations.removeLast()
    }
    return record
  }
  private func bounded(_ input: AuthoredRecord) throws -> AuthoredRecord {
    var record = try CacheSanitizer.sanitize(input)
    let cutoff = now().addingTimeInterval(-ConsoleBounds.maxAge)
    record.drafts = Array(
      record.drafts.filter { $0.updatedAt >= cutoff }
        .sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
    ).map { draft in
      var draft = draft
      draft.text = String(draft.text.prefix(32_768))
      return draft
    }
    record.seen = Array(record.seen.suffix(200))
    return record
  }
}
