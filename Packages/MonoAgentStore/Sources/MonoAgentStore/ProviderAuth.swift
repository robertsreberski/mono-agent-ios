// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

extension ConsoleStore {
  public func openProviderAuth(sourceID: String, providerID: String) {
    let state = providerState(sourceID)
    guard providerAvailable(state), !state.busy, !state.checkActive, !state.usageRefreshing,
      let provider = state.status?.providers.first(where: { $0.providerId == providerID }),
      !provider.methods.isEmpty
    else { return }
    state.methodProviderID = providerID
    state.authError = nil
    if provider.methods.count == 1, let method = provider.methods.first {
      startProviderAuth(sourceID: sourceID, providerID: providerID, method: method)
    } else if providerID == "openai-codex",
      let method = provider.methods.first(where: \.recommended)
    {
      startProviderAuth(sourceID: sourceID, providerID: providerID, method: method)
    }
  }
  public func dismissProviderReplacement(sourceID: String) {
    providerState(sourceID).replacement = nil
  }
  public func startProviderAuth(
    sourceID: String, providerID: String, method: ProviderAuthMethod,
    confirmedReplacement: Bool = false
  ) {
    let state = providerState(sourceID)
    guard providerAvailable(state), agent(sourceID)?.supportsProviderAuth == true,
      !state.busy, !state.checkActive, !state.usageRefreshing,
      let provider = state.status?.providers.first(where: { $0.providerId == providerID }),
      provider.methods.contains(method)
    else { return }
    if ProviderPresentation.needsReplacement(provider, method: method) {
      guard confirmedReplacement, state.methodProviderID == providerID, state.replacement == method
      else {
        state.methodProviderID = providerID
        state.replacement = method
        return
      }
    }
    state.replacement = nil
    let priorID = state.sessionActive ? state.session?.id : nil
    state.busy = true
    state.authError = nil
    state.sessionSequence += 1
    let sequence = state.sessionSequence
    let owner = state.owner
    let epoch = epoch
    let sourceGeneration = state.generation
    state.sessionPoll?.cancel()
    // Do not cancel admission tasks: observe IDs even if the view/lifetime disappears.
    Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.owner == owner {
          state.busy = false
          self.pollProviderSession(state)
        }
      }
      do {
        let next = try await self.api.startAuth(
          id: sourceID,
          body: .init(providerId: providerID, authType: method.authType, strategy: method.strategy))
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence
        else {
          if !ProviderPresentation.authTerminal(next.state) {
            self.cleanupProviderResource(
              state, id: next.id, check: false, generation: sourceGeneration)
          }
          return
        }
        guard next.providerId == providerID else {
          self.cleanupProviderResource(state, id: next.id, check: false)
          state.authError = "The console returned an unexpected authentication session."
          return
        }
        if let priorID, priorID != next.id {
          self.cleanupProviderResource(state, id: priorID, check: false)
        }
        state.sessionProviderID = providerID
        state.methodProviderID = nil
        self.adoptProviderSession(next, state: state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence, !(error is CancellationError)
        else { return }
        state.authError = Self.settingsFailure(error)
      }
    }
  }
  /// `value` is transient command input only. The view clears its field before calling this.
  public func submitProviderAuth(
    sourceID: String, sessionID: String, promptID: String, value: String
  ) {
    let state = providerState(sourceID)
    guard providerAvailable(state), !state.busy, !state.usageRefreshing, !state.checkActive,
      let session = state.session, session.id == sessionID,
      !ProviderPresentation.authTerminal(session.state),
      let prompt = session.prompt, prompt.id == promptID,
      !value.isEmpty || prompt.allowEmpty == true,
      prompt.type != "select" || prompt.options?.contains(where: { $0.id == value }) == true
    else { return }
    state.busy = true
    state.authError = nil
    state.sessionSequence += 1
    let sequence = state.sessionSequence
    let owner = state.owner
    let epoch = epoch
    state.sessionPoll?.cancel()
    Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.owner == owner {
          state.busy = false
          self.pollProviderSession(state)
        }
      }
      do {
        let next = try await self.api.authInput(
          id: sourceID, sessionId: sessionID, body: .init(promptId: promptID, value: value))
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence,
          state.session?.id == sessionID, next.id == sessionID,
          next.providerId == session.providerId
        else { return }
        self.adoptProviderSession(next, state: state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence, !(error is CancellationError)
        else { return }
        if Self.providerResourceAbsent(error) {
          state.session = nil
          state.resumeSessionID = nil
          state.sessionProviderID = nil
        } else {
          state.authError = Self.settingsFailure(error)
        }
      }
    }
  }
  public func cancelProviderAuth(sourceID: String) {
    let state = providerState(sourceID)
    guard providerAvailable(state), !state.busy, let session = state.session else { return }
    if ProviderPresentation.authTerminal(session.state) {
      state.session = nil
      state.resumeSessionID = nil
      state.sessionProviderID = nil
      state.methodProviderID = nil
      return
    }
    state.busy = true
    state.sessionSequence += 1
    let sequence = state.sessionSequence
    let owner = state.owner
    let epoch = epoch
    state.sessionPoll?.cancel()
    Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.owner == owner {
          state.busy = false
          self.pollProviderSession(state)
        }
      }
      do {
        try await self.api.cancelAuth(id: sourceID, sessionId: session.id)
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence, state.session?.id == session.id
        else { return }
        var next = session
        next.state = "cancelled"
        next.authUrl = nil
        next.deviceCode = nil
        next.prompt = nil
        self.adoptProviderSession(next, state: state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence, !(error is CancellationError)
        else { return }
        if Self.providerResourceAbsent(error) {
          state.session = nil
          state.resumeSessionID = nil
          state.sessionProviderID = nil
        } else {
          state.authError = Self.settingsFailure(error)
        }
      }
    }
  }
  func adoptProviderSession(_ next: ProviderAuthSessionSnapshot, state: ProviderState) {
    if let held = state.session, held.id == next.id, ProviderPresentation.authTerminal(held.state) {
      return
    }
    let previous = state.session?.state
    var bounded = next
    if let error = bounded.error {
      bounded.error?.message = ProviderPresentation.boundedText(error.message)
    }
    state.session = bounded
    state.resumeSessionID = ProviderPresentation.authTerminal(next.state) ? nil : next.id
    state.authError = nil
    if previous != next.state { state.announce("Authentication \(next.state).") }
    if next.state == "succeeded" {
      if let check = state.check, ProviderPresentation.checkTerminal(check.state) {
        state.check = nil
      }
      loadProviderStatus(state)
      loadProviderUsage(sourceID: state.sourceID, superseding: true)
    }
  }
  func pollProviderSession(_ state: ProviderState, immediately: Bool = false) {
    guard providerAvailable(state), !state.busy,
      let id = state.session?.id ?? state.resumeSessionID,
      state.session.map({ !ProviderPresentation.authTerminal($0.state) }) ?? true
    else { return }
    state.sessionPoll?.cancel()
    let owner = state.owner
    let epoch = epoch
    let sequence = state.sessionSequence
    state.sessionPoll = Task { [weak self] in
      guard let self else { return }
      var first = true
      while !Task.isCancelled {
        do { if !first || !immediately { try await self.clock.sleep(seconds: 1) } } catch { return }
        first = false
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.sessionSequence == sequence, !state.busy,
          (state.session?.id ?? state.resumeSessionID) == id,
          state.session.map({ !ProviderPresentation.authTerminal($0.state) }) ?? true
        else { return }
        do {
          let next = try await self.api.authSession(id: state.sourceID, sessionId: id, etag: nil)
            .valueRequired()
          guard !Task.isCancelled, self.providerCurrent(state, owner: owner, epoch: epoch),
            state.sessionSequence == sequence,
            (state.session?.id ?? state.resumeSessionID) == id, next.id == id,
            state.sessionProviderID == nil || next.providerId == state.sessionProviderID,
            state.session.map({ !ProviderPresentation.authTerminal($0.state) }) ?? true
          else { return }
          self.adoptProviderSession(next, state: state)
        } catch {
          guard !Task.isCancelled, self.providerCurrent(state, owner: owner, epoch: epoch),
            state.sessionSequence == sequence
          else { return }
          if Self.providerResourceAbsent(error) {
            state.session = nil
            state.resumeSessionID = nil
            state.sessionProviderID = nil
            state.authError = nil
            return
          }
          state.authError = Self.settingsFailure(error)
        }
      }
    }
  }
  public func startProviderCheck(sourceID: String) {
    let state = providerState(sourceID)
    guard providerAvailable(state), agent(sourceID)?.supportsProviderAuthChecks == true,
      state.status != nil,
      !state.busy, !state.checkActive, !state.sessionActive, !state.usageRefreshing
    else { return }
    state.busy = true
    state.authError = nil
    state.methodProviderID = nil
    state.checkSequence += 1
    let sequence = state.checkSequence
    let owner = state.owner
    let epoch = epoch
    let sourceGeneration = state.generation
    let key = UUID().uuidString
    Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.owner == owner {
          state.busy = false
          self.pollProviderCheck(state)
        }
      }
      do {
        let next = try await self.api.startAuthCheck(id: sourceID, body: .init(idempotencyKey: key))
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.checkSequence == sequence
        else {
          if !ProviderPresentation.checkTerminal(next.state) {
            self.cleanupProviderResource(
              state, id: next.id, check: true, generation: sourceGeneration)
          }
          return
        }
        self.adoptProviderCheck(next, state: state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.checkSequence == sequence, !(error is CancellationError)
        else { return }
        state.authError = Self.settingsFailure(error)
      }
    }
  }
  public func cancelProviderCheck(sourceID: String) {
    let state = providerState(sourceID)
    guard providerAvailable(state), !state.busy, let check = state.check,
      !ProviderPresentation.checkTerminal(check.state)
    else { return }
    state.busy = true
    state.checkSequence += 1
    let sequence = state.checkSequence
    let owner = state.owner
    let epoch = epoch
    state.checkPoll?.cancel()
    Task { [weak self] in
      guard let self, self.providerCurrent(state, owner: owner, epoch: epoch) else { return }
      defer {
        if state.owner == owner {
          state.busy = false
          self.pollProviderCheck(state)
        }
      }
      do {
        try await self.api.cancelAuthCheck(id: sourceID, checkId: check.id)
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.checkSequence == sequence, state.check?.id == check.id
        else { return }
        var next = check
        next.state = "cancelled"
        self.adoptProviderCheck(next, state: state)
      } catch {
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.checkSequence == sequence, !(error is CancellationError)
        else { return }
        if Self.providerResourceAbsent(error) {
          state.check = nil
          state.resumeCheckID = nil
          state.authError = nil
        } else {
          state.authError = Self.settingsFailure(error)
        }
      }
    }
  }
  func adoptProviderCheck(_ next: ProviderAuthCheckSessionSnapshot, state: ProviderState) {
    if let held = state.check, held.id == next.id, ProviderPresentation.checkTerminal(held.state) {
      return
    }
    state.check = next
    state.resumeCheckID = ProviderPresentation.checkTerminal(next.state) ? nil : next.id
    state.authError = nil
    state.announce(ProviderPresentation.checkSummary(next))
    if ProviderPresentation.checkTerminal(next.state) { loadProviderStatus(state) }
  }
  func pollProviderCheck(_ state: ProviderState, immediately: Bool = false) {
    guard providerAvailable(state), !state.busy,
      let id = state.check?.id ?? state.resumeCheckID,
      state.check.map({ !ProviderPresentation.checkTerminal($0.state) }) ?? true
    else { return }
    state.checkPoll?.cancel()
    let owner = state.owner
    let epoch = epoch
    let sequence = state.checkSequence
    state.checkPoll = Task { [weak self] in
      guard let self else { return }
      var first = true
      while !Task.isCancelled {
        do { if !first || !immediately { try await self.clock.sleep(seconds: 1) } } catch { return }
        first = false
        guard self.providerCurrent(state, owner: owner, epoch: epoch),
          state.checkSequence == sequence, !state.busy,
          (state.check?.id ?? state.resumeCheckID) == id,
          state.check.map({ !ProviderPresentation.checkTerminal($0.state) }) ?? true
        else { return }
        do {
          let next = try await self.api.authCheck(id: state.sourceID, checkId: id, etag: nil)
            .valueRequired()
          guard !Task.isCancelled, self.providerCurrent(state, owner: owner, epoch: epoch),
            state.checkSequence == sequence,
            (state.check?.id ?? state.resumeCheckID) == id, next.id == id,
            state.check.map({ !ProviderPresentation.checkTerminal($0.state) }) ?? true
          else { return }
          self.adoptProviderCheck(next, state: state)
        } catch {
          guard !Task.isCancelled, self.providerCurrent(state, owner: owner, epoch: epoch),
            state.checkSequence == sequence
          else { return }
          if Self.providerResourceAbsent(error) {
            state.check = nil
            state.resumeCheckID = nil
            state.authError = nil
            return
          }
          state.authError = Self.settingsFailure(error)
        }
      }
    }
  }
  /// Best-effort, scoped cleanup. Cancellation of a misbehaving transport cannot hold the caller.
  func cleanupProviderResource(_ state: ProviderState, id: String, check: Bool) {
    cleanupProviderResource(state, id: id, check: check, generation: state.generation)
  }
  func cleanupProviderResource(_ state: ProviderState, id: String, check: Bool, generation: String?)
  {
    guard !stopped, !stopping, !backgrounded, started, connection == .live,
      agent(state.sourceID)?.generation == generation
    else { return }
    let source = state.sourceID
    let epoch = epoch
    let request = Task { [weak self] in
      guard let self, !self.stopped, !self.stopping, !self.backgrounded, self.connection == .live,
        self.epoch == epoch, self.agent(source)?.generation == generation
      else { return }
      do {
        if check {
          try await self.api.cancelAuthCheck(id: source, checkId: id)
        } else {
          try await self.api.cancelAuth(id: source, sessionId: id)
        }
      } catch { /* Expiry is the fallback; never log auth material. */  }
    }
    Task { [clock] in
      do {
        try await clock.sleep(seconds: 2)
        request.cancel()
      } catch {}
    }
  }
}
