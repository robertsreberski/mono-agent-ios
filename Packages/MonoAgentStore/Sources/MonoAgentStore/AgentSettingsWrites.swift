// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Pin and new-conversation run defaults (web `AgentPinRow`, `NewConversationsSection`).
///
/// Both use the ordered per-agent lane, so a pin and a save on the same agent reach the console
/// in the order they were made. Each checks the Store lifetime, a live console and the agent at
/// admission and again immediately before dispatch, and publishes only the returned row for the
/// same agent in the same lifetime. A write never retries automatically.
extension ConsoleStore {
  /// Settings writes need the console itself, not the agent: pin and "Use agent config" work
  /// while the agent is offline.
  public var canWriteAgentSettings: Bool { canOrganize }

  /// Why a save cannot start now, or `nil` when it can.
  public func runDefaultsSaveBlocked(_ sourceID: String) -> String? {
    guard let agent = agent(sourceID) else { return "This agent is no longer available." }
    guard canWriteAgentSettings else { return "Reconnect to the console to save." }
    if agent.status == "offline", let draft = agentSettings[sourceID]?.draft,
      !draft.model.isEmpty || !draft.effort.isEmpty
    {
      return "Reconnect \(agent.label) to pick a model. Using the agent config works offline."
    }
    return nil
  }

  /// Saves the current draft: PUT for a custom choice, DELETE for "Use agent config".
  /// `summary` is the confirmed "model · effort" wording for the success notice.
  public func saveRunDefaults(sourceID: String, summary: String) {
    guard let state = agentSettings[sourceID], let draft = state.draft, !state.saving,
      runDefaultsDirty(sourceID), runDefaultsSaveBlocked(sourceID) == nil
    else { return }
    state.saving = true
    state.saveError = nil
    let generation = epoch
    enqueueThreadWrite(
      threadID: Self.agentLane(sourceID),
      onFinish: { [weak self, weak state] outcome in
        guard let self, let state, self.agentSettings[sourceID] === state else { return }
        state.saving = false
        if outcome == .timedOut, self.epoch == generation {
          state.saveError = "The console did not answer in time. Check the setting, then retry."
        }
      },
      operation: { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.dispatchRunDefaults(
          sourceID: sourceID, draft: draft, summary: summary, state: state, generation: generation)
      }
    )
  }

  private func dispatchRunDefaults(
    sourceID: String, draft: RunDefaultsDraft, summary: String, state: AgentSettingsState,
    generation: UInt64
  ) async throws {
    guard epoch == generation, agentSettings[sourceID] === state, canWriteAgentSettings,
      let agent = agent(sourceID),
      agent.status != "offline" || (draft.model.isEmpty && draft.effort.isEmpty)
    else { throw CancellationError() }
    do {
      let result: ApiAgent
      if draft.usesAgentConfig {
        result = try await api.deleteRunDefaults(id: sourceID)
      } else {
        result = try await api.putRunDefaults(
          id: sourceID,
          body: .init(
            model: draft.model.isEmpty ? .null : .value(draft.model),
            effort: draft.effort.isEmpty ? .null : .value(draft.effort),
            context1M: draft.context1M.map { .value($0) } ?? .omitted))
      }
      guard epoch == generation, agentSettings[sourceID] === state,
        result.agent.sourceId == sourceID
      else { throw CancellationError() }
      applyAgentWrite(result.agent, pinOnly: false)
      // A newer edit made while this request was in flight stays unsaved.
      if state.draft == draft {
        state.draft = nil
        state.draftVersion &+= 1
      }
      reconcileRunDefaultsDraft(sourceID: sourceID)
      state.saveError = nil
      state.notice = "New conversations will start with \(summary)."
      state.noticeSerial &+= 1
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if epoch == generation, agentSettings[sourceID] === state, !Task.isCancelled {
        state.saveError = Self.settingsFailure(error)
      }
      throw error
    }
  }

  /// Web `AgentPinRow`: optimistic requested value while pending, confirmed row afterwards.
  public func setAgentPinned(sourceID: String, pinned: Bool) {
    let state = agentSettingsState(sourceID)
    guard !state.pinPending, canWriteAgentSettings, agent(sourceID) != nil else { return }
    state.requestedPin = pinned
    state.pinPending = true
    state.pinError = nil
    let generation = epoch
    enqueueThreadWrite(
      threadID: Self.agentLane(sourceID),
      onFinish: { [weak self, weak state] outcome in
        guard let self, let state, self.agentSettings[sourceID] === state else { return }
        state.pinPending = false
        state.requestedPin = nil
        if outcome == .timedOut, self.epoch == generation {
          state.pinError = "The console did not answer in time. Check the pin, then retry."
        }
      },
      operation: { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.dispatchPin(
          sourceID: sourceID, pinned: pinned, state: state, generation: generation)
      }
    )
  }

  private func dispatchPin(
    sourceID: String, pinned: Bool, state: AgentSettingsState, generation: UInt64
  ) async throws {
    guard epoch == generation, agentSettings[sourceID] === state, canWriteAgentSettings,
      agent(sourceID) != nil
    else { throw CancellationError() }
    do {
      let result = try await api.patchAgent(id: sourceID, body: .init(pinned: pinned))
      guard epoch == generation, result.agent.sourceId == sourceID else {
        throw CancellationError()
      }
      applyAgentWrite(result.agent, pinOnly: true)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if epoch == generation, agentSettings[sourceID] === state, !Task.isCancelled {
        state.pinError = "Couldn't change the pin. " + Self.settingsFailure(error)
      }
      throw error
    }
  }
}
