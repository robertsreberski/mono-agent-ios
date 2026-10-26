// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

/// Settings restarts belong to the source, not to an agent-process generation. No state is persisted.
@MainActor @Observable public final class AgentRestartState {
  public enum ReadState { case loading, ready, error }
  public let sourceID: String
  public internal(set) var initialOperation: WebAgentRestartOperation?
  public internal(set) var operation: WebAgentRestartOperation?
  public internal(set) var readState: ReadState = .loading
  public internal(set) var confirming = false
  public internal(set) var requesting = false
  public internal(set) var requestFailure: String?
  public internal(set) var requestUnknown: String?
  public internal(set) var pollWarning: String?
  public internal(set) var notice: String?
  public internal(set) var noticeSerial = 0
  public var outcome: String? { operation?.outcome ?? (requestFailure == nil ? nil : "failure") }
  public var inProgress: Bool { operation != nil && operation?.outcome == nil }
  public var stage: String { operation?.stage ?? "requesting" }
  public var restartedThisVisit: Bool { operation != nil && operation?.id != initialOperation?.id }
  @ObservationIgnored var open = false
  @ObservationIgnored var lifetime = UUID()
  @ObservationIgnored var owner = UUID()
  @ObservationIgnored var confirmationScope: String?
  @ObservationIgnored var resumeID: String?
  @ObservationIgnored var latestTask: Task<Void, Never>?
  @ObservationIgnored var poll: Task<Void, Never>?
  @ObservationIgnored var admission: Task<Void, Never>?
  init(sourceID: String) { self.sourceID = sourceID }
  func announce(_ text: String) {
    notice = ProviderPresentation.boundedText(text)
    noticeSerial += 1
  }
}

extension ConsoleStore {
  public func agentRestartState(_ sourceID: String) -> AgentRestartState {
    if let state = agentRestarts[sourceID] { return state }
    let state = AgentRestartState(sourceID: sourceID)
    agentRestarts[sourceID] = state
    return state
  }
  private func restartCapability(_ sourceID: String) -> String {
    agent(sourceID)?.restart?.supported == true ? "supported" : "unsupported"
  }
  private func restartConfirmationScope(_ sourceID: String) -> String {
    sourceID + ":" + (agent(sourceID)?.generation ?? "") + ":" + restartCapability(sourceID)
  }
  private func restartAvailable(_ state: AgentRestartState) -> Bool {
    enabled && started && !stopped && !stopping && !backgrounded && connection == .live
      && state.open && agent(state.sourceID) != nil && agentRestarts[state.sourceID] === state
  }
  private func restartCurrent(_ state: AgentRestartState, owner: UUID, epoch: UInt64) -> Bool {
    restartAvailable(state) && state.owner == owner && self.epoch == epoch
  }
  public func agentRestartUnavailableReason(_ sourceID: String) -> String? {
    guard restartAvailable(agentRestartState(sourceID)) else { return "The console is not live." }
    guard let agent = agent(sourceID) else { return "Agent is unavailable." }
    if agent.status == "offline" { return "\(agent.label) is offline." }
    if agent.restart?.supported != true {
      return String(
        (agent.restart?.reason ?? "This agent cannot restart from the console.").prefix(280))
    }
    return nil
  }
  public func openAgentRestart(sourceID: String) {
    for previous in agentRestarts.values where previous.open && previous.sourceID != sourceID {
      closeAgentRestart(sourceID: previous.sourceID)
    }
    let state = agentRestartState(sourceID)
    guard !state.open else { return }
    state.open = true
    state.lifetime = UUID()
    state.owner = UUID()
    state.requestFailure = nil
    state.requestUnknown = nil
    state.pollWarning = nil
    state.initialOperation = nil
    state.operation = nil
    state.resumeID = nil
    resumeAgentRestart(state)
  }
  public func closeAgentRestart(sourceID: String) {
    guard let state = agentRestarts[sourceID] else { return }
    suspendAgentRestart(state)
    state.open = false
    state.lifetime = UUID()
  }
  func suspendAgentRestart(_ state: AgentRestartState) {
    state.owner = UUID()
    state.confirming = false
    state.confirmationScope = nil
    state.latestTask?.cancel()
    state.latestTask = nil
    state.poll?.cancel()
    state.poll = nil
    // Observe an admitted POST until it settles; cancellation cannot prove non-admission.
  }
  func resumeAgentRestart(_ state: AgentRestartState) {
    guard restartAvailable(state) else { return }
    suspendAgentRestart(state)
    if state.inProgress || state.resumeID != nil {
      pollAgentRestart(state)
    } else if state.admission == nil {
      loadLatestAgentRestart(sourceID: state.sourceID)
    }
  }
  func reconcileAgentRestarts() {
    for state in agentRestarts.values where state.open {
      if agent(state.sourceID) == nil { closeAgentRestart(sourceID: state.sourceID) }
      if state.confirmationScope != restartConfirmationScope(state.sourceID) {
        state.confirming = false
        state.confirmationScope = nil
      }
    }
  }
  public func loadLatestAgentRestart(sourceID: String) {
    let state = agentRestartState(sourceID)
    guard restartAvailable(state), state.latestTask == nil, state.admission == nil,
      !state.inProgress, state.resumeID == nil
    else { return }
    let owner = state.owner
    let epoch = epoch
    state.readState = .loading
    state.latestTask = Task { [weak self] in
      guard let self else { return }
      defer { if state.owner == owner { state.latestTask = nil } }
      do {
        let latest = try await self.api.latestRestart(id: sourceID, etag: nil).valueRequired()
          .operation
        guard self.restartCurrent(state, owner: owner, epoch: epoch), !Task.isCancelled else {
          return
        }
        guard latest == nil || (latest?.sourceId == sourceID && latest?.id.isEmpty == false) else {
          throw APIError(status: 502, code: "unexpected_restart")
        }
        state.readState = .ready
        state.initialOperation = latest
        state.operation = latest
        self.pollAgentRestart(state)
      } catch {
        guard self.restartCurrent(state, owner: owner, epoch: epoch), !Task.isCancelled else {
          return
        }
        state.readState = .error
        state.announce("Couldn't read restart status.")
      }
    }
  }
  public func requestAgentRestartConfirmation(sourceID: String) {
    let state = agentRestartState(sourceID)
    guard state.readState == .ready, state.admission == nil, !state.inProgress,
      state.resumeID == nil, agentRestartUnavailableReason(sourceID) == nil
    else { return }
    state.confirming = true
    state.confirmationScope = restartConfirmationScope(sourceID)
  }
  public func cancelAgentRestartConfirmation(sourceID: String) {
    let state = agentRestartState(sourceID)
    state.confirming = false
    state.confirmationScope = nil
  }
  public func confirmAgentRestart(sourceID: String) {
    let state = agentRestartState(sourceID)
    guard state.confirming, state.confirmationScope == restartConfirmationScope(sourceID),
      state.admission == nil, !state.inProgress, state.resumeID == nil,
      agentRestartUnavailableReason(sourceID) == nil
    else { return }
    let scope = restartConfirmationScope(sourceID)
    let capability = restartCapability(sourceID)
    let lifetime = state.lifetime
    let owner = state.owner
    let epoch = epoch
    state.confirming = false
    state.confirmationScope = nil
    state.requesting = true
    state.requestFailure = nil
    state.requestUnknown = nil
    state.pollWarning = nil
    state.operation = nil
    state.announce("Requesting restart.")
    state.admission = Task { [weak self] in
      guard let self else { return }
      @MainActor func current() -> Bool {
        self.restartCurrent(state, owner: owner, epoch: epoch)
          && self.restartCapability(sourceID) == capability
      }
      defer {
        state.admission = nil
        state.requesting = false
        if self.restartAvailable(state) {
          if state.inProgress || state.resumeID != nil {
            self.pollAgentRestart(state)
          } else if state.lifetime != lifetime {
            self.loadLatestAgentRestart(sourceID: sourceID)
          }
        }
      }
      guard current(), self.restartConfirmationScope(sourceID) == scope,
        self.agentRestartUnavailableReason(sourceID) == nil
      else { return }
      // nil is a known empty baseline; baselineKnown=false must never adopt latest.
      var baselineKnown = false
      var baselineID: String?
      do {
        let latest = try await self.api.latestRestart(id: sourceID, etag: nil).valueRequired()
          .operation
        if latest == nil || (latest?.sourceId == sourceID && latest?.id.isEmpty == false) {
          baselineKnown = true
          baselineID = latest?.id
        }
      } catch { /* A failed baseline read does not authorize recovery correlation. */  }
      guard current(), self.restartConfirmationScope(sourceID) == scope,
        self.agentRestartUnavailableReason(sourceID) == nil
      else { return }
      do {
        let result = try await self.api.restartAgent(id: sourceID, body: .init())
        guard result.sourceId == sourceID, !result.id.isEmpty else {
          throw APIError(status: 502, code: "unexpected_restart")
        }
        guard current() else {
          // Preserve only by-id resume material through a temporary background/disconnect.
          if state.open && state.lifetime == lifetime && self.enabled && !self.stopped
            && self.restartCapability(sourceID) == capability
          {
            state.resumeID = result.id
            if self.restartAvailable(state) { self.pollAgentRestart(state) }
          }
          return
        }
        self.adoptAgentRestart(result, state: state)
      } catch {
        guard current() else {
          if state.open && state.lifetime == lifetime {
            state.requestUnknown =
              "Couldn't confirm the request was received — check the agent. You can retry."
          }
          return
        }
        if let error = error as? APIError, [400, 401, 403, 404, 409].contains(error.status) {
          state.requestFailure = "The agent refused the request."
          state.announce("Restart failed: The agent refused the request.")
          return
        }
        if baselineKnown {
          do {
            let latest = try await self.api.latestRestart(id: sourceID, etag: nil).valueRequired()
              .operation
            guard current() else { return }
            if let latest, latest.sourceId == sourceID, !latest.id.isEmpty, latest.id != baselineID
            {
              self.adoptAgentRestart(latest, state: state)
              return
            }
          } catch { /* A read failure is not a failure verdict or permission to retry. */  }
        }
        guard current() else { return }
        state.requestUnknown =
          "Couldn't confirm the request was received — check the agent. You can retry."
        state.announce(state.requestUnknown!)
      }
    }
  }
  private func adoptAgentRestart(_ operation: WebAgentRestartOperation, state: AgentRestartState) {
    // A stale GET cannot regress a terminal operation.
    guard state.operation?.id != operation.id || state.operation?.outcome == nil else { return }
    let changed =
      state.operation?.stage != operation.stage || state.operation?.outcome != operation.outcome
    state.operation = operation
    state.resumeID = nil
    state.readState = .ready
    state.pollWarning = nil
    if changed {
      let message: String
      switch operation.outcome {
      case "success": message = "Agent is back online. Restart succeeded."
      case "failure": message = "Restart failed."
      case "not_confirmed": message = "Restart not confirmed — check the agent."
      case .some: message = "Restart finished. Check the agent."
      case nil:
        message = operation.stage == "requesting" ? "Requesting restart." : "Restarting agent."
      }
      state.announce(message)
    }
  }
  private func pollAgentRestart(_ state: AgentRestartState) {
    guard restartAvailable(state), state.poll == nil,
      let id = state.resumeID ?? (state.inProgress ? state.operation?.id : nil)
    else { return }
    let owner = state.owner
    let epoch = epoch
    state.poll = Task { [weak self] in
      guard let self else { return }
      defer { if state.owner == owner { state.poll = nil } }
      while self.restartCurrent(state, owner: owner, epoch: epoch), !Task.isCancelled {
        do {
          let result = try await self.api.restartOperation(
            id: state.sourceID, operationId: id, etag: nil
          )
          .valueRequired()
          guard self.restartCurrent(state, owner: owner, epoch: epoch), !Task.isCancelled else {
            return
          }
          guard result.sourceId == state.sourceID, result.id == id else {
            throw APIError(status: 502, code: "unexpected_restart")
          }
          self.adoptAgentRestart(result, state: state)
          if result.outcome != nil { return }
        } catch {
          guard self.restartCurrent(state, owner: owner, epoch: epoch), !Task.isCancelled else {
            return
          }
          state.pollWarning = "Restart status is temporarily unavailable."
          state.announce(state.pollWarning!)
        }
        do { try await self.clock.sleep(seconds: 2) } catch { return }
      }
    }
  }
}
