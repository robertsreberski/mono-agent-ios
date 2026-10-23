// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentKit
import Observation

/// Monotonic local reconciliation: a pending poll cannot undo an answer or terminal tool result.
@MainActor @Observable
final class AskInteractionState {
  private(set) var snapshot: ChannelAskSnapshot?
  private(set) var submitting = false
  private(set) var revision = 0

  static func terminal(snapshot: ChannelAskSnapshot?, persisted: String?) -> String? {
    if let persisted, ["answered", "cancelled", "expired"].contains(persisted) { return persisted }
    return snapshot.flatMap { $0.status == "pending" ? nil : $0.status }
  }

  func applyPoll(_ value: ChannelAskSnapshot, revision: Int) {
    guard self.revision == revision, !submitting,
      Self.terminal(snapshot: snapshot, persisted: nil) == nil
    else { return }
    snapshot = value
  }

  func beginSubmission() -> Bool {
    guard !submitting, Self.terminal(snapshot: snapshot, persisted: nil) == nil else {
      return false
    }
    revision += 1
    submitting = true
    return true
  }

  func finishSubmission(_ value: ChannelAskSnapshot?) {
    if let value { snapshot = value }
    submitting = false
  }
}
