// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// One server-side search answer. Hits are summaries as the server saw them when it searched;
/// they never patch buckets, the fleet or read markers.
public struct ThreadSearchResult: Sendable, Equatable {
  public var hits: [WebThreadSearchHit]
  public var truncated: Bool
  public init(hits: [WebThreadSearchHit] = [], truncated: Bool = false) {
    self.hits = hits
    self.truncated = truncated
  }
}

public enum ConsoleSearchError: Error, Equatable {
  /// The Store is not live (offline hydration, stopped or backgrounded). No request was made.
  case unavailable
}

extension ConsoleStore {
  /// Below this a query matches almost everything; mirrors the web console and the server floor.
  public static let minimumSearchQuery = 2

  /// Server-side search across every conversation of one agent, in the web console's `chats`
  /// scope. A trimmed query shorter than ``minimumSearchQuery`` returns an empty result
  /// without a request. Search is an explicit read: it needs a started, foreground Store and
  /// never changes selection, buckets, unread state or the cache. A result that arrives after
  /// the Store stopped, backgrounded or was replaced throws `CancellationError`.
  public func searchThreads(sourceID: String, query: String) async throws -> ThreadSearchResult {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= Self.minimumSearchQuery else { return ThreadSearchResult() }
    guard enabled, started, !stopping, !backgrounded else { throw ConsoleSearchError.unavailable }
    let generation = epoch
    let result = try await api.searchThreads(
      query: .init(sourceId: sourceID, q: trimmed, scope: "chats"), etag: nil)
    guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
    let page = try result.valueRequired()
    // Tombstoned conversations stay hidden here exactly as in every other projection.
    pruneTombstones()
    return ThreadSearchResult(
      hits: page.hits.filter { !tombstones.keys.contains($0.thread.id) }, truncated: page.truncated)
  }

  /// Dismisses the last reported refresh/read problem after the UI has shown it. Persistence
  /// states (`storage`, `authoredStorage`, `journalStorage`) are separate and unaffected.
  public func clearErrorMessage() {
    errorMessage = nil
  }
}
