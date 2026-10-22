// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import MonoAgentKit

public enum DataMode: String, Codable, Sendable { case auto, lean, full }
public enum Freshness: String, Codable, Sendable { case stale, fresh }
public enum SyncState: Sendable, Equatable { case offline, connecting, live, waiting }
public enum PersistenceState: Sendable, Equatable {
  case durable
  case memoryOnly
  case writeFailed
  case superseded
}

/// Identity is deliberately conservative: an endpoint edit or advertised identity change isolates data.
public struct ConsoleNamespace: Codable, Hashable, Sendable {
  public let profileID: UUID
  public let identity: String
  public init(profile: SavedConsole) {
    profileID = profile.id
    identity = Self.digest(
      profile.endpoint.url.absoluteString + "\n" + (profile.lastIdentity?.hostName ?? ""))
  }
  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
public struct BucketKey: Codable, Hashable, Sendable {
  public var sourceID: String
  public var archived: Bool
  public init(sourceID: String, archived: Bool = false) {
    self.sourceID = sourceID
    self.archived = archived
  }
}
public struct ThreadBucket: Codable, Sendable {
  public var key: BucketKey
  public var threads: [WebThread]
  public var nextCursor: String?
  public var freshness: Freshness = .stale
  public var savedAt: Date
  public init(key: BucketKey, threads: [WebThread], nextCursor: String? = nil, savedAt: Date) {
    self.key = key
    self.threads = threads
    self.nextCursor = nextCursor
    self.savedAt = savedAt
  }
}
public struct CachedConversation: Codable, Sendable {
  public var thread: WebThread
  public var messages: [WebMessage]
  public var nextCursor: String?
  public var pagedIDs: Set<String> = []
  public var repairedToolCallIDs: Set<String> = []
  public var savedAt: Date
  public var truncated = false
  public init(thread: WebThread, messages: [WebMessage], nextCursor: String? = nil, savedAt: Date) {
    self.thread = thread
    self.messages = messages
    self.nextCursor = nextCursor
    self.savedAt = savedAt
  }
}
public struct ThreadTombstone: Codable, Sendable, Equatable {
  public enum Origin: String, Codable, Sendable { case removed, notFound, legacyUnknown }
  public var revision: Int
  public var removedAt: Date
  public var origin: Origin
  public init(revision: Int, removedAt: Date, origin: Origin = .removed) {
    self.revision = revision
    self.removedAt = removedAt
    self.origin = origin
  }
  func allows(revision: Int, fetchedAt: Date?) -> Bool {
    revision > self.revision || (origin != .removed && fetchedAt.map { $0 > removedAt } == true)
  }
  private enum CodingKeys: String, CodingKey { case revision, removedAt, origin }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    revision = try c.decode(Int.self, forKey: .revision)
    removedAt = try c.decode(Date.self, forKey: .removedAt)
    origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .legacyUnknown
  }
}
public struct CacheRecord: Codable, Sendable {
  public var version = 1
  public var revision: UInt64 = 0
  public var bootstrap: ApiBootstrap?
  public var buckets: [ThreadBucket] = []
  public var conversations: [CachedConversation] = []
  public var tombstones: [String: ThreadTombstone] = [:]
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case version, revision, bootstrap, buckets, conversations, tombstones
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    revision = try c.decode(UInt64.self, forKey: .revision)
    bootstrap = try c.decodeIfPresent(ApiBootstrap.self, forKey: .bootstrap)
    buckets = try c.decode([ThreadBucket].self, forKey: .buckets)
    conversations = try c.decode([CachedConversation].self, forKey: .conversations)
    if let values = try? c.decode([String: ThreadTombstone].self, forKey: .tombstones) {
      tombstones = values
    } else {
      // The first v1 cache had an unbounded ID set. Give legacy entries a finite lifetime.
      let ids = try c.decode(Set<String>.self, forKey: .tombstones)
      tombstones = Dictionary(
        uniqueKeysWithValues: ids.map {
          ($0, ThreadTombstone(revision: 0, removedAt: .distantPast))
        })
    }
  }
}
public struct DraftKey: Codable, Hashable, Sendable {
  public var profileID: UUID
  public var sourceID: String
  public var threadID: String?
  public init(profileID: UUID, sourceID: String, threadID: String? = nil) {
    self.profileID = profileID
    self.sourceID = sourceID
    self.threadID = threadID
  }
}
public struct ComposerDraft: Codable, Sendable, Equatable {
  public var key: DraftKey
  public var text: String
  public var version: UUID
  public var updatedAt: Date
}
public struct ReadMarker: Codable, Sendable {
  public var id: String
  public var revision: Int
  public init(id: String, revision: Int) {
    self.id = id
    self.revision = revision
  }
}
public struct AuthoredRecord: Codable, Sendable {
  public var version = 1
  public var revision: UInt64 = 0
  public var dataMode: DataMode = .auto
  public var drafts: [ComposerDraft] = []
  public var seen: [ReadMarker] = []
  public init() {}
}
/// Only the reference and payload digest are durable. No upload bytes, URLs or immutable payload.
public struct SubmissionReference: Codable, Sendable, Equatable {
  public var threadID: String
  public var submissionID: String
  public var payloadDigest: String
  public var draftKey: DraftKey
  public var draftVersion: UUID?
  public var dispatched: Bool
  public var historicalPreparation: Bool
  public var lastDispatchedAt: Date?
  public var createdAt: Date
  public var attachmentIDs: [String]
  private enum CodingKeys: String, CodingKey {
    case threadID, submissionID, payloadDigest, draftKey, draftVersion, dispatched, createdAt,
      attachmentIDs, historicalPreparation, lastDispatchedAt
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    threadID = try c.decode(String.self, forKey: .threadID)
    submissionID = try c.decode(String.self, forKey: .submissionID)
    payloadDigest = try c.decode(String.self, forKey: .payloadDigest)
    draftKey = try c.decode(DraftKey.self, forKey: .draftKey)
    draftVersion = try c.decodeIfPresent(UUID.self, forKey: .draftVersion)
    // Legacy references might have reached the server; never assume they were undispatched.
    let dispatchFlag = try c.decodeIfPresent(Bool.self, forKey: .dispatched)
    let preparationDate = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    dispatched = dispatchFlag ?? true
    let historical = try c.decodeIfPresent(Bool.self, forKey: .historicalPreparation) ?? false
    historicalPreparation =
      dispatchFlag == nil || preparationDate == nil || !dispatched || historical
    lastDispatchedAt = try c.decodeIfPresent(Date.self, forKey: .lastDispatchedAt)
    createdAt = preparationDate ?? .distantPast
    attachmentIDs = try c.decodeIfPresent([String].self, forKey: .attachmentIDs) ?? []
  }
  public init(
    threadID: String, submissionID: String, payloadDigest: String, draftKey: DraftKey,
    draftVersion: UUID?, dispatched: Bool = false, createdAt: Date = Date(),
    attachmentIDs: [String] = [], historicalPreparation: Bool = false, lastDispatchedAt: Date? = nil
  ) {
    self.threadID = threadID
    self.submissionID = submissionID
    self.payloadDigest = payloadDigest
    self.draftKey = draftKey
    self.draftVersion = draftVersion
    self.dispatched = dispatched
    self.historicalPreparation = historicalPreparation
    self.lastDispatchedAt = lastDispatchedAt
    self.createdAt = createdAt
    self.attachmentIDs = attachmentIDs
  }
}
public struct JournalRecord: Codable, Sendable {
  public var version = 1
  public var revision: UInt64 = 0
  public var pending: [SubmissionReference] = []
  public init() {}
}
public enum ConsoleStorageError: Error { case invalidFormat, byteBudget, unavailable, superseded }
public struct ConsoleBounds: Sendable {
  public static let memoryConversations = 8
  public static let diskConversations = 24
  public static let maxAge: TimeInterval = 30 * 24 * 60 * 60
  public static let cacheBytes = 16 * 1024 * 1024
  public static let conversationBytes = 2 * 1024 * 1024
  public static let authoredBytes = 6 * 1024 * 1024
  public static let tombstoneCount = 256
  public static let tombstoneAge: TimeInterval = 30 * 24 * 60 * 60
  public static let journalCount = 50
  public static let journal404Age: TimeInterval = 30 * 24 * 60 * 60
  public static let notFoundConfirmation: TimeInterval = 5
  public static let threadWriteTimeout: TimeInterval = 15
  public static let journalBytes = 1024 * 1024
}

/// Sanitization is applied on both write and hydrate, including opaque extension objects.
public enum CacheSanitizer {
  public static func scrub(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      let isAttachment =
        fields["type"] == .string("attachment")
        || (fields["uploaded"] != nil && fields["sizeBytes"] != nil)
      let isMCP = fields["type"] == .string("mcp_app")
      let stripped = fields.filter { key, _ in
        !(isAttachment && key == "contentUrl")
          && !(isMCP && ["resourceUrl", "bridgeUrl"].contains(key))
      }
      let isTool = fields["type"] == .string("tool-call") || fields["type"] == .string("subagent")
      return .object(
        stripped.mapValues(scrub).merging(
          isTool ? fields.filter { ["args", "result", "structuredResult"].contains($0.key) } : [:],
          uniquingKeysWith: { _, opaque in opaque }))
    case .array(let items): return .array(items.map(scrub))
    case .string(let text):
      // Capability URLs can also be embedded in authored text/opaque tool output.
      return .string(
        text.replacingOccurrences(
          of: #"(?:https?://[^\s\"<>]+)?/api/v1/[^\s\"<>]*[?&](?:token|expires)=[^\s\"<>]*"#,
          with: "[local capability removed]", options: .regularExpression))
    default: return value
    }
  }
  public static func sanitize<T: Codable>(_ value: T) throws -> T {
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(scrub(json)))
  }
  public static func conversation(_ input: CachedConversation) throws -> CachedConversation {
    var entry = try sanitize(input)
    entry.thread.compaction = nil
    let oldCount = entry.messages.count
    entry.messages.removeAll(where: silentCron)
    if entry.messages.count != oldCount {
      entry.thread.messageCount = max(
        0, entry.thread.messageCount - oldCount + entry.messages.count)
      let text = entry.messages.last?.parts.compactMap { part -> String? in
        if case .text(let value) = part { return value.text }
        return nil
      }.joined(separator: " ")
      entry.thread.lastMessagePreview = text.flatMap { $0.isEmpty ? nil : String($0.prefix(280)) }
    }
    entry.pagedIDs.formIntersection(entry.messages.map(\.id))
    return entry
  }
  static func silentCron(_ message: WebMessage) -> Bool {
    guard message.role == "assistant", message.status == "complete", message.attachments.isEmpty
    else { return false }
    let silent = message.parts.contains { part in
      guard case .telemetry(let value) = part, value.event == "cron_run",
        case .object(let data) = value.data
      else { return false }
      return data["status"] == .string("succeeded") && data["silent"] == .bool(true)
    }
    return silent
      && message.parts.allSatisfy { part in
        switch part {
        case .telemetry(let value): return value.event == "cron_run"
        case .text(let value):
          return value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || value.text == "Completed silently (no message was reported)."
        default: return false
        }
      }
  }
}
