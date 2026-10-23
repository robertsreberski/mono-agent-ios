// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum ConversationActivityReadError: Error, Equatable {
  case unavailable, identityMismatch
}

extension ConsoleStore {
  /// Refreshes the retained projection only. The pinned contract offers no job mutation or
  /// full log route; output references are host-local paths, never native navigation targets.
  @discardableResult
  public func refreshJob(threadID: String, jobID: String) async throws -> Bool {
    guard enabled, started, !stopping, !backgrounded,
      let state = conversations[threadID], !tombstones.keys.contains(threadID)
    else { throw ConversationActivityReadError.unavailable }
    let generation = epoch
    let result = try await api.job(id: threadID, jobId: jobID, etag: nil).valueRequired().job
    guard epoch == generation, enabled, started, !backgrounded, !Task.isCancelled,
      conversations[threadID] === state, !tombstones.keys.contains(threadID)
    else { throw CancellationError() }
    guard result.jobId == jobID else { throw ConversationActivityReadError.identityMismatch }
    var changed = false
    for messageIndex in state.record.messages.indices {
      for partIndex in state.record.messages[messageIndex].parts.indices {
        guard case .processJob(var part) = state.record.messages[messageIndex].parts[partIndex],
          part.job.jobId == jobID
        else { continue }
        let merged = JobPresentation.merge(part.job, result)
        if merged != part.job {
          part.job = merged
          state.record.messages[messageIndex].parts[partIndex] = .processJob(part)
          changed = true
        }
      }
    }
    if changed {
      state.publish()
      scheduleCache()
    }
    return changed
  }

  /// An explicit aggregate read, not an estimate from the loaded message window. A late
  /// response cannot replace another conversation or a newer transcript revision.
  @discardableResult
  public func refreshUsage(threadID: String) async throws -> Bool {
    guard enabled, started, !stopping, !backgrounded,
      let state = conversations[threadID], !tombstones.keys.contains(threadID)
    else { throw ConversationActivityReadError.unavailable }
    let generation = epoch
    let revision = state.thread.revision
    let request = UUID()
    state.usageRequest = request
    let result = try await api.threadUsage(id: threadID, etag: nil).valueRequired().usage
    guard epoch == generation, enabled, started, !backgrounded, !Task.isCancelled,
      conversations[threadID] === state, !tombstones.keys.contains(threadID),
      state.thread.revision == revision, state.usageRequest == request
    else { throw CancellationError() }
    state.usage = result
    state.usageRevision = revision
    return true
  }
}
