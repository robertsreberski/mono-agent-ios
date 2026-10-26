// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

/// Ephemeral settings owner. Auth DTOs are deliberately absent from all persistence records.
/// Credential input belongs to the view, never to this observable state.
@MainActor @Observable public final class ProviderState {
  public let sourceID: String
  public internal(set) var status: ProviderAuthStatusSnapshot?
  public internal(set) var session: ProviderAuthSessionSnapshot?
  public internal(set) var check: ProviderAuthCheckSessionSnapshot?
  public internal(set) var usage: ProviderUsageSnapshot?
  public internal(set) var methodProviderID: String?
  public internal(set) var sessionProviderID: String?
  public internal(set) var replacement: ProviderAuthMethod?
  public internal(set) var authError: String?
  public internal(set) var usageError: String?
  public internal(set) var usageFeedback: String?
  public internal(set) var statusLoading = false
  public internal(set) var usageLoading = false
  public internal(set) var usageRefreshing = false
  public internal(set) var busy = false
  public internal(set) var notice: String?
  public internal(set) var noticeSerial = 0
  public var sessionActive: Bool {
    session.map { !ProviderPresentation.authTerminal($0.state) } ?? (resumeSessionID != nil)
  }
  public var checkActive: Bool {
    check.map { !ProviderPresentation.checkTerminal($0.state) } ?? (resumeCheckID != nil)
  }
  @ObservationIgnored var generation: String?
  @ObservationIgnored var capabilityKey = ""
  @ObservationIgnored var owner = UUID()
  @ObservationIgnored var open = false
  @ObservationIgnored var resumeSessionID: String?
  @ObservationIgnored var resumeCheckID: String?
  @ObservationIgnored var statusSequence = 0
  @ObservationIgnored var sessionSequence = 0
  @ObservationIgnored var checkSequence = 0
  @ObservationIgnored var usageSequence = 0
  @ObservationIgnored var statusTask: Task<Void, Never>?
  @ObservationIgnored var sessionPoll: Task<Void, Never>?
  @ObservationIgnored var checkPoll: Task<Void, Never>?
  @ObservationIgnored var usageTask: Task<Void, Never>?
  @ObservationIgnored var usageTimer: Task<Void, Never>?
  init(sourceID: String) { self.sourceID = sourceID }
  func announce(_ text: String) {
    notice = text
    noticeSerial += 1
  }
}

public enum ProviderPresentation {
  public static func authTerminal(_ state: String) -> Bool {
    ["succeeded", "failed", "cancelled"].contains(state)
  }
  public static func checkTerminal(_ state: String) -> Bool {
    ["completed", "cancelled"].contains(state)
  }
  public static func authLabel(_ provider: ProviderAuthProviderStatus) -> String {
    if provider.lastFailure?.kind == "provider_auth" { return "Needs action" }
    if provider.state == "not_applicable" { return "Not applicable" }
    if provider.state != "present" { return "Needs action" }
    if provider.lastFailure == nil {
      if provider.verification == "verified_by_live_request" { return "OK" }
      if provider.verification == "verified_by_account_request" { return "Credential OK" }
    }
    return "Not verified"
  }
  public static func checkLabel(_ state: String) -> String {
    switch state {
    case "pending": "Pending"
    case "running": "Checking…"
    case "passed": "Check passed"
    case "auth_failed": "Auth failed"
    case "network_failed": "Network error"
    case "quota_limited": "Quota blocked"
    case "model_not_entitled": "Model unavailable"
    case "inconclusive": "Inconclusive"
    case "unsupported": "Not checked"
    case "timeout": "Timed out"
    case "cancelled": "Cancelled"
    case "stale": "Credential changed"
    default: "Not run"
    }
  }
  public static func checkSummary(_ check: ProviderAuthCheckSessionSnapshot) -> String {
    if checkTerminal(check.state) {
      return
        "Checks complete: \(check.results.filter { $0.state == "passed" }.count) of \(check.results.count) passed."
    }
    let finished = check.results.filter { !["pending", "running"].contains($0.state) }.count
    return "Checking providers: \(finished) of \(check.results.count) complete."
  }
  /// A character boundary is also a UTF-8 boundary; never exceed the display byte budget.
  public static func boundedText(_ text: String) -> String {
    var bytes = 0
    return String(
      text.prefix { character in
        bytes += character.utf8.count
        return bytes <= 4096
      })
  }
  public static func needsReplacement(
    _ provider: ProviderAuthProviderStatus, method: ProviderAuthMethod
  ) -> Bool {
    provider.providerId == "openai" && provider.source == "stored"
      && provider.credentialType != nil && provider.credentialType != method.authType
  }
}

extension ConsoleStore {
  public func providerState(_ sourceID: String) -> ProviderState {
    if let state = providers[sourceID] { return state }
    let state = ProviderState(sourceID: sourceID)
    providers[sourceID] = state
    return state
  }
  public func providerScope(_ sourceID: String) -> String {
    sourceID + ":" + (agent(sourceID)?.generation ?? "") + ":" + (agent(sourceID)?.status ?? "")
      + ":" + providerCapabilities(sourceID)
  }
  func providerCapabilities(_ sourceID: String) -> String {
    let agent = agent(sourceID)
    return [
      agent?.supportsProviderAuth, agent?.supportsProviderAuthChecks, agent?.supportsProviderUsage,
      agent?.supportsProviderUsageRefresh,
    ]
    .map { $0 == true ? "1" : "0" }.joined()
  }
  func providerAvailable(_ state: ProviderState) -> Bool {
    !stopped && !stopping && !backgrounded && started && connection == .live
      && state.open && agent(state.sourceID)?.status != "offline"
      && agent(state.sourceID) != nil && agent(state.sourceID)?.generation == state.generation
      && state.capabilityKey == providerCapabilities(state.sourceID)
  }
  func providerCurrent(_ state: ProviderState, owner: UUID, epoch: UInt64) -> Bool {
    providerAvailable(state) && state.owner == owner && self.epoch == epoch
  }
  public func openProviders(sourceID: String) {
    let state = providerState(sourceID)
    guard
      !state.open || state.generation != agent(sourceID)?.generation
        || state.capabilityKey != providerCapabilities(sourceID)
    else { return }
    if state.open { closeProviders(sourceID: sourceID) }
    state.open = true
    state.generation = agent(sourceID)?.generation
    state.capabilityKey = providerCapabilities(sourceID)
    state.owner = UUID()
    resumeProviders(state)
  }
  func resumeProviders(_ state: ProviderState) {
    guard providerAvailable(state) else { return }
    loadProviderStatus(state)
    loadProviderUsage(sourceID: state.sourceID)
    pollProviderSession(state, immediately: true)
    pollProviderCheck(state, immediately: true)
  }
  public func closeProviders(sourceID: String) {
    guard let state = providers[sourceID] else { return }
    let sessionID = state.sessionActive ? state.session?.id ?? state.resumeSessionID : nil
    let checkID = state.checkActive ? state.check?.id ?? state.resumeCheckID : nil
    // Cleanup dispatch is admitted while the old owner is still live, never after stop/background.
    if let sessionID { cleanupProviderResource(state, id: sessionID, check: false) }
    if let checkID { cleanupProviderResource(state, id: checkID, check: true) }
    suspendProviders(state)
    state.open = false
    state.resumeSessionID = nil
    state.resumeCheckID = nil
    state.sessionProviderID = nil
    state.status = nil
    state.usage = nil
    state.check = nil
  }
  func suspendProviders(_ state: ProviderState) {
    state.owner = UUID()
    state.statusTask?.cancel()
    state.statusTask = nil
    state.sessionPoll?.cancel()
    state.sessionPoll = nil
    state.checkPoll?.cancel()
    state.checkPoll = nil
    state.usageTask?.cancel()
    state.usageTask = nil
    state.usageTimer?.cancel()
    state.usageTimer = nil
    if let session = state.session {
      state.resumeSessionID = ProviderPresentation.authTerminal(session.state) ? nil : session.id
    }
    if let check = state.check {
      state.resumeCheckID = ProviderPresentation.checkTerminal(check.state) ? nil : check.id
    }
    state.session = nil
    state.check = nil
    state.methodProviderID = nil
    state.replacement = nil
    state.authError = nil
    state.notice = nil
    state.busy = false
    state.statusLoading = false
    state.usageLoading = false
    state.usageRefreshing = false
  }
  func reconcileProviderOwners() {
    for state in providers.values where state.open {
      if state.capabilityKey != providerCapabilities(state.sourceID)
        || agent(state.sourceID)?.generation != state.generation
        || agent(state.sourceID)?.status == "offline" || agent(state.sourceID) == nil
      {
        closeProviders(sourceID: state.sourceID)
      }
    }
  }
  func loadProviderStatus(_ state: ProviderState) {
    guard providerAvailable(state), agent(state.sourceID)?.supportsProviderAuth == true else {
      return
    }
    state.statusSequence += 1
    let sequence = state.statusSequence
    let owner = state.owner
    let epoch = epoch
    state.statusTask?.cancel()
    state.statusLoading = true
    state.statusTask = Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.statusSequence == sequence && state.owner == owner { state.statusLoading = false }
      }
      do {
        let next = try await self.api.providerAuth(id: state.sourceID, etag: nil).valueRequired()
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.statusSequence == sequence
        else { return }
        state.status = next
        state.authError = nil
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.statusSequence == sequence, !(error is CancellationError)
        else { return }
        state.authError = Self.settingsFailure(error)
      }
    }
  }
  public func reloadProviderStatus(sourceID: String) { loadProviderStatus(providerState(sourceID)) }
  static func providerResourceAbsent(_ error: any Error) -> Bool {
    guard let error = error as? APIError else { return false }
    return error.status == 404 && error.code == "provider_auth_not_found"
  }
}
