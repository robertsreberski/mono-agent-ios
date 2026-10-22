// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

actor ControlledRepository: ConsoleRepository {
  let base: FileConsoleRepository
  var failAuthoredSaves: Set<Int> = []
  var authoredSaves = 0
  var failJournalSaves: Set<Int> = []
  var journalSaves = 0
  var pauseJournal = false
  var journalWaiter: CheckedContinuation<Void, Never>?
  var supersededCaches = 0
  var pauseCache = false
  var cacheWaiter: CheckedContinuation<Void, Never>?
  init(directory: URL) { base = FileConsoleRepository(directory: directory) }
  func failAuthored(_ saves: Set<Int>) { failAuthoredSaves = saves }
  func failJournal(_ saves: Set<Int>) { failJournalSaves = saves }
  func pauseNextJournalSave() { pauseJournal = true }
  func isJournalPaused() -> Bool { journalWaiter != nil }
  func releaseJournal() {
    journalWaiter?.resume()
    journalWaiter = nil
  }
  func supersedeCache(_ count: Int) { supersededCaches = count }
  func pauseNextCacheLoad() { pauseCache = true }
  func isPaused() -> Bool { cacheWaiter != nil }
  func releaseCache() {
    cacheWaiter?.resume()
    cacheWaiter = nil
  }
  func loadCache(_ namespace: ConsoleNamespace) async throws -> CacheRecord {
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
  @discardableResult func saveCache(_ record: CacheRecord, namespace: ConsoleNamespace) async throws
    -> RepositorySaveResult
  {
    if supersededCaches > 0 {
      supersededCaches -= 1
      return .superseded(revision: 99)
    }
    return try await base.saveCache(record, namespace: namespace)
  }
  @discardableResult func saveAuthored(_ record: AuthoredRecord, namespace: ConsoleNamespace)
    async throws -> RepositorySaveResult
  {
    authoredSaves += 1
    if failAuthoredSaves.contains(authoredSaves) { throw ConsoleStorageError.unavailable }
    return try await base.saveAuthored(record, namespace: namespace)
  }
  @discardableResult func saveJournal(_ record: JournalRecord, namespace: ConsoleNamespace)
    async throws -> RepositorySaveResult
  {
    journalSaves += 1
    if failJournalSaves.contains(journalSaves) { throw ConsoleStorageError.unavailable }
    if pauseJournal {
      pauseJournal = false
      await withCheckedContinuation { journalWaiter = $0 }
    }
    return try await base.saveJournal(record, namespace: namespace)
  }
  func delete(profileID: UUID) async throws { try await base.delete(profileID: profileID) }
}
@MainActor
struct CorrectionHarness {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let profile = SavedConsole(name: "Flockbox", endpoint: Scenario.endpoint)
  let transport = RouteTransport()
  let events = TestEvents()
  let clock = ManualStoreClock()
  let repository: ControlledRepository
  let store: ConsoleStore
  init() {
    repository = ControlledRepository(directory: directory)
    store = ConsoleStore(
      profile: profile, api: APIClient(endpoint: Scenario.endpoint, transport: transport),
      events: events, repository: repository, clock: clock)
  }
}
let submissionPath = "/api/v1/threads/thread-example/submissions"
func notFound() -> HTTPResponse {
  HTTPResponse(data: Data(#"{"error":"not found"}"#.utf8), status: 404)
}
func admission(_ reference: SubmissionReference, status: Int = 202) throws -> HTTPResponse {
  try response(
    JSONValue.object([
      "submissionId": .string(reference.submissionID),
      "threadId": .string(reference.threadID), "outcome": .string("turn"),
    ]), status: status)
}
func prepared(profileID: UUID, createdAt: Date, dispatched: Bool = false) -> SubmissionReference {
  .init(
    threadID: "thread-example", submissionID: UUID().uuidString, payloadDigest: "fictional-digest",
    draftKey: .init(profileID: profileID, sourceID: "agent-example"), draftVersion: nil,
    dispatched: dispatched, createdAt: createdAt)
}

actor WriteOrder {
  var values: [String] = []
  func record(_ value: String) { values.append(value) }
}
func exampleAttachment() throws -> WebAttachment {
  try decode(
    #"{"id":"upload-example","name":"sample.txt","contentType":"text/plain","sizeBytes":4,"kind":"file","status":"ready","uploaded":true,"createdAt":"2030-01-02T12:00:00Z"}"#
  )
}
func reference(profileID: UUID, input: ApiStartSubmission, createdAt: Date, dispatched: Bool) throws
  -> SubmissionReference
{
  var payload = input
  payload.submissionId = ""
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return .init(
    threadID: "thread-example", submissionID: UUID().uuidString.lowercased(),
    payloadDigest: ConsoleNamespace.digest(
      String(decoding: try encoder.encode(payload), as: UTF8.self)),
    draftKey: .init(profileID: profileID, sourceID: "agent-example", threadID: "thread-example"),
    draftVersion: nil, dispatched: dispatched, createdAt: createdAt,
    attachmentIDs: input.attachmentIds ?? [])
}
