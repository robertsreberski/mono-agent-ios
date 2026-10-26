// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

extension ConsoleStore {
  /// Automatic GETs and explicit refresh have independent ownership from authentication.
  /// A manual refresh supersedes GET, but a timer can never supersede a manual refresh.
  public func loadProviderUsage(sourceID: String, superseding: Bool = false) {
    let state = providerState(sourceID)
    guard providerAvailable(state), agent(sourceID)?.supportsProviderUsage == true,
      !state.usageRefreshing, superseding || !state.usageLoading
    else { return }
    requestProviderUsage(state, manual: false)
  }
  public func refreshProviderUsage(sourceID: String) {
    let state = providerState(sourceID)
    guard providerAvailable(state), agent(sourceID)?.supportsProviderUsage == true,
      agent(sourceID)?.supportsProviderUsageRefresh == true,
      !state.usageRefreshing, !state.busy, !state.checkActive, !state.sessionActive
    else { return }
    requestProviderUsage(state, manual: true)
  }
  private func requestProviderUsage(_ state: ProviderState, manual: Bool) {
    state.usageSequence += 1
    let sequence = state.usageSequence
    let owner = state.owner
    let epoch = epoch
    state.usageTask?.cancel()
    state.usageTimer?.cancel()
    state.usageTimer = nil
    if manual {
      state.usageRefreshing = true
      state.usageFeedback = "Refreshing usage…"
      state.announce("Refreshing usage…")
    } else {
      state.usageLoading = true
    }
    state.usageTask = Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      var delay: TimeInterval = 300
      defer {
        if self.providerCurrent(state, owner: owner, epoch: epoch), state.usageSequence == sequence
        {
          state.usageLoading = false
          state.usageRefreshing = false
          self.scheduleProviderUsage(state, delay: delay)
        }
      }
      do {
        let next: ProviderUsageSnapshot
        if manual {
          next = try await self.api.refreshProviderUsage(
            id: state.sourceID, query: .init(), body: .init())
        } else {
          next = try await self.api.providerUsage(id: state.sourceID, query: .init(), etag: nil)
            .valueRequired()
        }
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.usageSequence == sequence, !Task.isCancelled
        else { return }
        let missing =
          state.usage?.providers.contains { old in
            !next.providers.contains { $0.providerId == old.providerId }
          } ?? false
        state.usage = next
        state.usageError = nil
        if manual {
          if missing || next.providers.contains(where: { $0.stale || $0.error != nil }) {
            state.usageFeedback = "Some usage could not be refreshed · last known shown"
          } else if next.providers.isEmpty {
            state.usageFeedback = "No subscription usage available"
          } else {
            state.usageFeedback = "Usage updated"
          }
          state.announce(state.usageFeedback ?? "Usage updated")
        }
        if next.providers.contains(where: { $0.stale && $0.error == nil }) { delay = 15 }
        self.loadProviderStatus(state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.usageSequence == sequence, !Task.isCancelled
        else { return }
        if var retained = state.usage {
          for index in retained.providers.indices { retained.providers[index].stale = true }
          state.usage = retained
        }
        state.usageError = "Provider usage is unavailable."
        if manual {
          state.usageFeedback = "Usage refresh failed · last known shown"
          state.announce(state.usageFeedback!)
        }
      }
    }
  }
  private func scheduleProviderUsage(_ state: ProviderState, delay: TimeInterval) {
    let owner = state.owner
    let epoch = epoch
    state.usageTimer = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: delay) } catch { return }
      guard let self, !Task.isCancelled, self.providerCurrent(state, owner: owner, epoch: epoch)
      else { return }
      self.loadProviderUsage(sourceID: state.sourceID)
    }
  }
}
