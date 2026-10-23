// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore

/// The composer's submission state machine. Every transition is driven by an explicit user
/// action or a Store result; nothing here resends on its own.
enum ComposerPhase: Equatable {
  case idle
  /// A submission is between the durable journal checkpoint and its receipt.
  case sending(liveInput: Bool)
  /// The console admitted the submission (`turn`) or attached it to the running turn.
  case confirmed(liveInput: Bool)
  /// The console may have received it. Retry reuses the same submission identity.
  case uncertain(String)
  /// Definitely not admitted (rejected, or stopped before dispatch). Text is retained.
  case failed(String)

  var isSending: Bool {
    if case .sending = self { return true }
    return false
  }
  var allowsRetry: Bool {
    switch self {
    case .uncertain, .failed: true
    default: false
    }
  }
}

/// What the primary trailing control does in the current state.
enum ComposerPrimaryAction: Equatable {
  /// Start a new turn (or the first turn of a new conversation).
  case send
  /// Add live input to the running turn; the server decides turn vs live input.
  case queue
}

struct ComposerAffordances: Equatable {
  var primary: ComposerPrimaryAction
  var primaryEnabled: Bool
  /// Stop is offered whenever the conversation is confirmed running.
  var showsStop: Bool
  var showsRetry: Bool
  var placeholder: String
  /// Why sending is unavailable, spoken and shown instead of a silent disabled button.
  var unavailableReason: String?
}

enum ComposerRules {
  /// Mirrors Composer.tsx: Send and Stop are both present while running; an empty composer
  /// cannot send; compaction and uploads block admission without hiding Stop.
  static func affordances(
    hasContent: Bool, uploading: Bool, running: Bool, canSend: Bool, compacting: Bool,
    phase: ComposerPhase, agentLabel: String?, agentOffline: Bool, archived: Bool
  ) -> ComposerAffordances {
    let reason: String? =
      if agentOffline {
        "\(agentLabel ?? "The agent") is offline"
      } else if archived {
        "Conversation archived"
      } else if !canSend {
        "Not connected to the console"
      } else if compacting {
        "Compacting context — you can send when it finishes"
      } else if uploading {
        "Waiting for uploads to finish"
      } else {
        nil
      }
    let name = agentLabel ?? (running ? "the agent" : "an agent")
    let placeholder =
      agentOffline || archived
      ? (reason ?? "") : running ? "Message \(name) while it works…" : "Message \(name)…"
    return ComposerAffordances(
      primary: running ? .queue : .send,
      primaryEnabled: hasContent && reason == nil && !phase.isSending,
      showsStop: running, showsRetry: phase.allowsRetry, placeholder: placeholder,
      unavailableReason: reason)
  }

  /// The phase after an admitted receipt. A `rejected` outcome is surfaced by the Store as
  /// `SubmissionError.rejected`, never as a receipt here.
  static func phase(after receipt: WebSubmissionReceipt) -> ComposerPhase {
    .confirmed(liveInput: receipt.outcome == "live-input")
  }

  /// Uncertainty is decided by Store state, not guessed from the error: it exists exactly
  /// while a possibly-dispatched journal reference for this conversation remains.
  static func phase(after error: any Error, possiblyDispatched: Bool) -> ComposerPhase {
    if possiblyDispatched {
      return .uncertain(
        "Not confirmed. The console may have received this message. Retry checks with the same ID and cannot send it twice."
      )
    }
    switch error {
    case SubmissionError.rejected(let reason):
      return .failed("The console rejected this message (\(reason)). Your text is kept.")
    case SubmissionError.busy: return .failed("Another send is still settling. Try again.")
    case SubmissionError.journalFull:
      return .failed(
        "Recovery history is full. Check the conversation, then forget an older uncertain message.")
    case SubmissionError.journalUnavailable:
      return .failed("Sending is disabled: the recovery journal cannot be saved on this device.")
    case SubmissionError.threadWriteFailed, SubmissionError.threadWriteTimeout,
      SubmissionError.threadWriteInterrupted:
      return .failed("A settings change did not finish, so nothing was sent. Try again.")
    case let error as APIError:
      return .failed("Not sent: \(error.localizedDescription)")
    case is CancellationError:
      return .failed("Not sent: the conversation changed before sending.")
    default:
      return .failed("Not sent. Check the connection and try again.")
    }
  }

  /// Confirmation text shown briefly after admission.
  static func label(_ phase: ComposerPhase) -> String? {
    switch phase {
    case .idle: nil
    case .sending(let live): live ? "Sending live input…" : "Sending…"
    case .confirmed(let live): live ? "Queued as live input for the running turn" : "Sent"
    case .uncertain(let text), .failed(let text): text
    }
  }
}
