// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// IDs, never DTOs, are navigation identity. Every console-scoped route carries its profile
/// UUID, so a route restored or kept across a console switch can never open another console's
/// conversation. Feature PRs can extend these routes.
enum AppRoute: Hashable, Codable {
  /// A saved console's connection detail (connection screens and the consoles sheet).
  case console(UUID)
  /// One conversation. `archived` selects the bucket the conversation is listed in.
  case conversation(profile: UUID, sourceID: String, threadID: String, archived: Bool)
  /// A new conversation for one agent: no thread exists until the composer sends (C8).
  case newConversation(profile: UUID, sourceID: String)
  /// A project page placeholder (the page itself belongs to the organize feature).
  case project(profile: UUID, sourceID: String, projectID: String)

  var profile: UUID {
    switch self {
    case .console(let id): id
    case .conversation(let profile, _, _, _), .newConversation(let profile, _),
      .project(let profile, _, _):
      profile
    }
  }

  /// The agent the destination belongs to, if any.
  var sourceID: String? {
    switch self {
    case .console: nil
    case .conversation(_, let source, _, _), .newConversation(_, let source),
      .project(_, let source, _):
      source
    }
  }

  var threadID: String? {
    if case .conversation(_, _, let thread, _) = self { return thread }
    return nil
  }

  /// Dashboard destinations (pushed on iPhone, shown in the iPad detail column).
  var isDashboardDestination: Bool {
    if case .console = self { return false }
    return true
  }

  /// Stable text form for scene restoration. Decoding failures simply restore nothing.
  var encoded: String? {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
  }

  init?(encoded: String) {
    guard !encoded.isEmpty,
      let value = try? JSONDecoder().decode(AppRoute.self, from: Data(encoded.utf8))
    else { return nil }
    self = value
  }
}

/// When the Store may treat a transcript as read. Selection alone never marks it read: only a
/// destination that is on screen, in an active scene, for the Store's selected thread.
enum TranscriptVisibility {
  /// `true` marks visible, `false` marks hidden, `nil` leaves the Store alone because another
  /// destination (or none) owns the Store's selection.
  static func command(
    onScreen: Bool, sceneActive: Bool, selectedThreadID: String?, threadID: String?
  ) -> Bool? {
    guard let threadID, selectedThreadID == threadID else { return nil }
    return onScreen && sceneActive
  }
}

/// What an agent switch does to an open destination: a conversation of another agent closes.
enum AgentSwitch {
  static func route(afterSelecting sourceID: String, current: AppRoute?) -> AppRoute? {
    guard let current, current.isDashboardDestination else { return current }
    return current.sourceID == sourceID ? current : nil
  }
}
