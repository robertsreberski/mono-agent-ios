// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

@MainActor @Observable public final class RestartProposalState {
  public internal(set) var confirming = false
  public internal(set) var requesting = false
  public internal(set) var operation: WebAgentRestartOperation?
  public internal(set) var operationID: String?
  public internal(set) var requestFailure: String?
  public internal(set) var requestUnknown: String?
  public internal(set) var pollWarning: String?
  public var outcome: String? { operation?.outcome ?? (requestFailure == nil ? nil : "failure") }
  public var outcomeReason: String? {
    (operation?.reason ?? requestFailure).map { String($0.prefix(280)) }
  }
  public var stage: String { operation?.stage ?? "requesting" }
  init(operationID: String?) { self.operationID = operationID }
}

extension ConsoleStore {
  public func restartProposalState(_ reference: ReplyPartReference) -> RestartProposalState {
    if let state = restartProposals[reference] {
      if state.operationID == nil,
        let part = restartProposal(reference), part.restartable?.state == "used"
      {
        state.operationID = part.restartable?.operationId
      }
      return state
    }
    // Ephemeral UI state, not a persistence format. Bound retained idle cards.
    if restartProposals.count >= 128,
      let key = restartProposals.first(where: { !$0.value.requesting })?.key
    {
      restartProposals[key] = nil
    }
    let part = restartProposal(reference)
    let state = RestartProposalState(
      operationID: part?.restartable?.state == "used" ? part?.restartable?.operationId : nil)
    restartProposals[reference] = state
    return state
  }
  public func restartUnavailableReason(_ reference: ReplyPartReference) -> String? {
    guard enabled, started, !stopping, !backgrounded, selectedThreadID == reference.threadId,
      !tombstones.keys.contains(reference.threadId),
      let thread = conversations[reference.threadId]?.thread, !thread.sourceId.isEmpty,
      let availability = restartProposal(reference)?.restartable
    else { return "Restart is unavailable." }
    if availability.state == "used" {
      return availability.operationId?.isEmpty == false ? nil : "Restart status is unavailable."
    }
    return availability.state == "available"
      ? nil : String((availability.reason ?? "Restart is unavailable.").prefix(280))
  }
  /// Merely displaying/restoring a proposal never submits a restart.
  public func requestRestartConfirmation(_ reference: ReplyPartReference) {
    let state = restartProposalState(reference)
    guard restartUnavailableReason(reference) == nil, !state.requesting,
      state.operationID == nil, state.outcome == nil,
      restartProposal(reference)?.restartable?.state == "available"
    else { return }
    state.confirming = true
  }
  public func cancelRestartConfirmation(_ reference: ReplyPartReference) {
    restartProposals[reference]?.confirming = false
  }
  public func confirmRestart(_ reference: ReplyPartReference) async {
    let state = restartProposalState(reference)
    guard state.confirming, !state.requesting, state.operationID == nil, state.outcome == nil,
      restartUnavailableReason(reference) == nil,
      restartProposal(reference)?.restartable?.state == "available",
      let conversation = conversations[reference.threadId]
    else { return }
    let generation = epoch
    let selected = selection
    let source = conversation.thread.sourceId
    state.confirming = false
    state.requesting = true
    state.requestUnknown = nil
    state.requestFailure = nil
    defer { state.requesting = false }
    func valid() -> Bool {
      restartReadIsCurrent(
        reference, state: state, epoch: generation, selection: selected, source: source)
        && !Task.isCancelled
    }
    do {
      let result = try await api.restartProposal(
        threadId: reference.threadId,
        messageId: reference.messageId, partId: reference.partId, body: .init())
      guard valid() else { return }
      guard result.sourceId == source, !result.id.isEmpty else {
        state.requestUnknown =
          "Couldn't confirm the request was received — check the agent. You can retry."
        return
      }
      state.operation = result
      state.operationID = result.id
    } catch {
      guard valid() else { return }
      if let error = error as? APIError, [400, 401, 403, 404, 409].contains(error.status) {
        state.requestFailure = "The agent refused the request."
        return
      }
      // A lost response is not a failure verdict, nor permission to replay the POST.
      // Correlate the latest operation with this exact persisted proposal before adopting it.
      do {
        let latest = try await api.latestRestart(id: source, etag: nil).valueRequired().operation
        guard valid() else { return }
        let message = try await api.message(
          threadId: reference.threadId, messageId: reference.messageId,
          query: .init(), etag: nil
        ).valueRequired().message
        guard valid() else { return }
        if let latest, latest.sourceId == source, message.id == reference.messageId,
          message.threadId == reference.threadId,
          message.parts.contains(where: {
            if case .restartProposal(let part) = $0 {
              return part.id == reference.partId && part.restartable?.state == "used"
                && part.restartable?.operationId == latest.id
            }
            return false
          })
        {
          state.operation = latest
          state.operationID = latest.id
          return
        }
      } catch { /* Retain uncertainty; never automatically retry a mutation. */  }
      guard valid() else { return }
      state.requestUnknown =
        "Couldn't confirm the request was received — check the agent. You can retry."
    }
  }
  public func pollRestartProposal(_ reference: ReplyPartReference) async {
    let state = restartProposalState(reference)
    guard let id = state.operationID, !id.isEmpty, state.outcome == nil,
      let source = conversations[reference.threadId]?.thread.sourceId
    else { return }
    let generation = epoch
    let selected = selection
    while restartReadIsCurrent(
      reference, state: state, epoch: generation, selection: selected, source: source),
      !Task.isCancelled, state.operationID == id, state.outcome == nil
    {
      do {
        let result = try await api.restartOperation(id: source, operationId: id, etag: nil)
          .valueRequired()
        guard
          restartReadIsCurrent(
            reference, state: state, epoch: generation, selection: selected, source: source),
          !Task.isCancelled
        else { return }
        guard result.id == id, result.sourceId == source else {
          state.pollWarning = "Restart status is temporarily unavailable."
          try await clock.sleep(seconds: 2)
          continue
        }
        state.operation = result
        state.pollWarning = nil
        if result.outcome != nil { return }
      } catch is CancellationError { return } catch {
        guard
          restartReadIsCurrent(
            reference, state: state, epoch: generation, selection: selected, source: source),
          !Task.isCancelled
        else { return }
        state.pollWarning = "Restart status is temporarily unavailable."
      }
      do { try await clock.sleep(seconds: 2) } catch { return }
    }
  }
  private func restartReadIsCurrent(
    _ reference: ReplyPartReference, state: RestartProposalState,
    epoch: UInt64, selection: UInt64, source: String
  ) -> Bool {
    enabled && started && !stopping && !backgrounded && self.epoch == epoch
      && self.selection == selection
      && selectedThreadID == reference.threadId && !tombstones.keys.contains(reference.threadId)
      && conversations[reference.threadId]?.thread.sourceId == source
      && restartProposals[reference] === state && restartProposal(reference) != nil
  }
  private func restartProposal(_ reference: ReplyPartReference) -> RestartProposalPart? {
    conversations[reference.threadId]?.messages.first(where: { $0.id == reference.messageId })?
      .parts.compactMap {
        if case .restartProposal(let part) = $0, part.id == reference.partId { return part }
        return nil
      }.first
  }
}
