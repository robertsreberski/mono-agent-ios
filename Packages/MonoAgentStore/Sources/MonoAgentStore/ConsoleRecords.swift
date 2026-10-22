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
public struct CacheRecord: Codable, Sendable {
  public var version = 1
  public var revision: UInt64 = 0
  public var bootstrap: ApiBootstrap?
  public var buckets: [ThreadBucket] = []
  public var conversations: [CachedConversation] = []
  public var tombstones: Set<String> = []
  public init() {}
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
  public init(
    threadID: String, submissionID: String, payloadDigest: String, draftKey: DraftKey,
    draftVersion: UUID?
  ) {
    self.threadID = threadID
    self.submissionID = submissionID
    self.payloadDigest = payloadDigest
    self.draftKey = draftKey
    self.draftVersion = draftVersion
  }
}
public struct JournalRecord: Codable, Sendable {
  public var version = 1
  public var revision: UInt64 = 0
  public var pending: [SubmissionReference] = []
  public init() {}
}
public enum ConsoleStorageError: Error { case invalidFormat, byteBudget, unavailable }
public struct ConsoleBounds: Sendable {
  public static let memoryConversations = 8
  public static let diskConversations = 24
  public static let maxAge: TimeInterval = 30 * 24 * 60 * 60
  public static let cacheBytes = 16 * 1024 * 1024
  public static let conversationBytes = 2 * 1024 * 1024
  public static let authoredBytes = 6 * 1024 * 1024
  public static let journalBytes = 1024 * 1024
}

/// Sanitization is applied on both write and hydrate, including opaque extension objects.
public enum CacheSanitizer {
  static let forbidden: Set<String> = [
    "contentUrl", "storedUrl", "resourceUrl", "bridgeUrl", "expiresAt", "accessToken",
    "refreshToken", "token", "ackToken", "authorization", "etag",
  ]
  public static func scrub(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      return .object(fields.filter { !forbidden.contains($0.key) }.mapValues(scrub))
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
