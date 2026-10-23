// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Observation

/// Server snippet highlighting, mirrored from the web console's `thread-search.ts`.
enum SearchHighlight {
  /// The server's `WEB_SEARCH_HIGHLIGHT_*` sentinels. Pinned: changing one breaks highlights.
  static let open: Character = "\u{2}"
  static let close: Character = "\u{3}"

  struct Segment: Equatable {
    var text: String
    var match: Bool
  }

  private static func stripped(_ text: Substring) -> String {
    String(text.filter { $0 != open && $0 != close })
  }

  /// Plain and matched runs. Never markup; an unbalanced marker degrades to plain text.
  static func segments(_ snippet: String) -> [Segment] {
    var result: [Segment] = []
    var cursor = snippet.startIndex
    while let start = snippet[cursor...].firstIndex(of: open),
      let end = snippet[snippet.index(after: start)...].firstIndex(of: close)
    {
      let before = snippet[cursor..<start]
      if !before.isEmpty { result.append(.init(text: stripped(before), match: false)) }
      result.append(.init(text: stripped(snippet[snippet.index(after: start)..<end]), match: true))
      cursor = snippet.index(after: end)
    }
    let rest = snippet[cursor...]
    if !rest.isEmpty { result.append(.init(text: stripped(rest), match: false)) }
    return result
  }

  /// A title the server did not snippet: the first case-insensitive occurrence of the query.
  static func title(_ title: String, query: String) -> [Segment] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty,
      let range = title.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
    else { return [.init(text: title, match: false)] }
    var result: [Segment] = []
    if range.lowerBound > title.startIndex {
      result.append(.init(text: String(title[..<range.lowerBound]), match: false))
    }
    result.append(.init(text: String(title[range]), match: true))
    if range.upperBound < title.endIndex {
      result.append(.init(text: String(title[range.upperBound...]), match: false))
    }
    return result
  }

  /// Matched runs are bold and underlined, so the cue survives without colour.
  static func attributed(_ segments: [Segment]) -> AttributedString {
    segments.reduce(into: AttributedString()) { result, segment in
      var run = AttributedString(segment.text)
      if segment.match {
        run.inlinePresentationIntent = .stronglyEmphasized
        run.underlineStyle = .single
      }
      result += run
    }
  }
}

/// A debounced server-side conversation search for one agent.
///
/// Results stay visible while the next request is in flight, each new query cancels the
/// previous one so a slow early answer cannot overwrite a newer one, and a lean data mode
/// waits longer before spending a request. Clock and search are injected for tests.
@MainActor @Observable
final class ThreadSearchModel {
  enum Status: Equatable { case idle, loading, ready, error }

  static let debounce: Duration = .milliseconds(200)
  static let leanDebounce: Duration = .milliseconds(350)

  typealias Search =
    @MainActor (_ sourceID: String, _ query: String) async throws -> ThreadSearchResult
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private(set) var hits: [WebThreadSearchHit] = []
  private(set) var truncated = false
  private(set) var status: Status = .idle
  /// The query the current hits answer.
  private(set) var answeredQuery = ""
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0
  /// Agent and trimmed query of the request in flight or answered; repeats are no-ops.
  @ObservationIgnored private var lastKey: String?
  @ObservationIgnored private let search: Search
  @ObservationIgnored private let sleep: Sleep

  init(
    search: @escaping Search,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.search = search
    self.sleep = sleep
  }

  /// Whether a query is long enough to replace the dashboard with results.
  static func isSearching(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).count >= ConsoleStore.minimumSearchQuery
  }

  /// Call on every edit, agent switch and reappearance. Short queries reset to idle. The data
  /// mode only sets the wait: re-reporting the same query never cancels a request in flight.
  func update(query: String, sourceID: String?, lean: Bool) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = sourceID.map { $0 + "\u{0}" + trimmed }
    if key == lastKey, status == .loading || status == .ready { return }
    lastKey = key
    generation &+= 1
    let current = generation
    task?.cancel()
    guard let sourceID, Self.isSearching(trimmed) else {
      task = nil
      hits = []
      truncated = false
      status = .idle
      answeredQuery = ""
      return
    }
    status = .loading
    let wait = lean ? Self.leanDebounce : Self.debounce
    task = Task { [weak self, sleep] in
      do { try await sleep(wait) } catch { return }
      guard let self, self.generation == current, !Task.isCancelled else { return }
      do {
        let result = try await self.search(sourceID, trimmed)
        guard self.generation == current, !Task.isCancelled else { return }
        self.hits = result.hits
        self.truncated = result.truncated
        self.answeredQuery = trimmed
        self.status = .ready
      } catch {
        guard self.generation == current, !Task.isCancelled, !(error is CancellationError) else {
          return
        }
        self.hits = []
        self.truncated = false
        self.status = .error
      }
    }
  }

  func cancel() {
    lastKey = nil
    generation &+= 1
    task?.cancel()
    task = nil
  }

  /// Await the in-flight debounce/request (tests only need this; views never block on it).
  func settle() async { await task?.value }
}
