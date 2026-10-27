// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

/// An overview may be displayed from disk, but only a current, successful live read grants authority.
@MainActor @Observable public final class AutomationState {
  public let sourceID: String
  public internal(set) var overview: WebCronOverview?
  public internal(set) var savedAt: Date?
  public internal(set) var freshness: Freshness = .stale
  public internal(set) var loading = false
  public internal(set) var error: String?
  public internal(set) var job: CronJobState?
  public internal(set) var pendingJobs: Set<String> = []
  @ObservationIgnored var scope = ""
  @ObservationIgnored var revision: UInt64 = 0
  @ObservationIgnored var dirty = false
  @ObservationIgnored var flight: Task<Void, Never>?
  @ObservationIgnored var owner = UUID()
  init(sourceID: String) { self.sourceID = sourceID }
}

extension ConsoleStore {
  public func automationState(_ sourceID: String) -> AutomationState {
    if let state = automations[sourceID] { return state }
    let state = AutomationState(sourceID: sourceID)
    state.scope = cronScope(sourceID)
    automations[sourceID] = state
    return state
  }
  func cronScope(_ sourceID: String) -> String {
    guard let agent = agent(sourceID) else { return "missing" }
    return [
      agent.generation ?? "", agent.status, String(agent.cron?.read == true),
      String(agent.cron?.actions == true),
    ].joined(separator: "\u{0}")
  }
  func cronReadable(_ sourceID: String) -> Bool {
    enabled && started && !stopped && !stopping && !backgrounded && connection == .live
      && agent(sourceID)?.status != "offline" && agent(sourceID)?.cron?.read == true
  }
  public func automationIsAuthoritative(_ sourceID: String) -> Bool {
    let state = automationState(sourceID)
    return cronReadable(sourceID) && state.scope == cronScope(sourceID)
      && state.freshness == .fresh && state.error == nil && state.overview != nil
      && state.overview?.degradedReason == nil
  }
  public func refreshAutomations(sourceID: String) async {
    requestAutomations(sourceID: sourceID)
    await automations[sourceID]?.flight?.value
  }
  /// One physical read per source, with one trailing obligation for any number of invalidations.
  func requestAutomations(sourceID: String, invalidate: Bool = false) {
    let state = automationState(sourceID)
    if invalidate {
      state.job?.confirmation = nil
      state.revision &+= 1
      state.freshness = .stale
    }
    guard cronReadable(sourceID) else {
      state.freshness = .stale
      if state.overview == nil { state.error = "Automations are unavailable for this agent." }
      return
    }
    state.dirty = true
    guard state.flight == nil else { return }
    let owner = UUID()
    state.owner = owner
    let epoch = epoch
    let scope = cronScope(sourceID)
    state.scope = scope
    state.loading = true
    state.flight = Task { [weak self] in
      guard let self else { return }
      defer {
        if state.owner == owner {
          state.flight = nil
          state.loading = false
        }
      }
      while state.dirty {
        state.dirty = false
        let revision = state.revision
        guard self.cronReadCurrent(state, owner: owner, epoch: epoch, scope: scope) else { return }
        do {
          let overview = try await self.api.cronOverview(id: sourceID, etag: nil).valueRequired()
          let now = await self.clock.wallNow()
          guard self.cronReadCurrent(state, owner: owner, epoch: epoch, scope: scope) else {
            return
          }
          // A changed event while awaiting this GET obliges another GET; never grant the old read authority.
          guard revision == state.revision else { continue }
          state.overview = overview
          state.savedAt = now
          state.error = nil
          state.freshness = overview.degradedReason == nil ? .fresh : .stale
          self.scheduleCache()
        } catch {
          guard self.cronReadCurrent(state, owner: owner, epoch: epoch, scope: scope) else {
            return
          }
          state.freshness = .stale
          state.error = (error as? APIError)?.safeDetails ?? "Couldn't refresh automations."
        }
      }
    }
  }
  private func cronReadCurrent(_ state: AutomationState, owner: UUID, epoch: UInt64, scope: String)
    -> Bool
  {
    self.epoch == epoch && state.owner == owner && automations[state.sourceID] === state
      && cronReadable(state.sourceID) && cronScope(state.sourceID) == scope && !Task.isCancelled
  }
  func invalidateAutomations() {
    for state in automations.values {
      state.revision &+= 1
      state.freshness = .stale
      state.job?.confirmation = nil
    }
  }
  func suspendAutomations() {
    invalidateAutomations()
    for state in automations.values {
      state.owner = UUID()
      state.flight?.cancel()
      state.flight = nil
      state.loading = false
      closeCronJob(sourceID: state.sourceID)
    }
  }
  func adoptAutomationCache(_ snapshots: [CachedAutomationOverview]) {
    for entry in snapshots {
      let state = automationState(entry.sourceID)
      guard state.savedAt == nil || entry.savedAt > state.savedAt! else { continue }
      state.overview = entry.overview
      state.savedAt = entry.savedAt
      state.freshness = .stale
      state.revision &+= 1
      state.job?.confirmation = nil
    }
  }
  func reconcileAutomations() {
    for state in automations.values where state.scope != cronScope(state.sourceID) {
      state.owner = UUID()
      state.flight?.cancel()
      state.flight = nil
      state.loading = false
      state.freshness = .stale
      state.scope = cronScope(state.sourceID)
      closeCronJob(sourceID: state.sourceID)
    }
  }
  /// Resolve a durable job identity through this source's overview, never a caller-supplied thread ID.
  public func automationJob(sourceID: String, jobID: String) -> WebCronJob? {
    automationState(sourceID).overview?.jobs.first { $0.jobId == jobID }
  }
  public func selectAutomation(sourceID: String, jobID: String) async -> String? {
    let epoch = epoch
    if !automationIsAuthoritative(sourceID), cronReadable(sourceID) {
      await refreshAutomations(sourceID: sourceID)
    }
    guard self.epoch == epoch, let job = automationJob(sourceID: sourceID, jobID: jobID) else {
      return nil
    }
    await select(sourceID: sourceID, threadID: job.threadId)
    guard self.epoch == epoch, selectedBucket?.sourceID == sourceID,
      selectedThreadID == job.threadId
    else { return nil }
    return job.threadId
  }
}
