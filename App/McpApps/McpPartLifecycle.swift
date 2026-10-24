// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI

struct McpPartIdentity: Hashable {
  let profile: UUID
  let thread: String
  let message: String
  let publication: McpAppPart
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(profile)
    hasher.combine(thread)
    hasher.combine(message)
    hasher.combine(publication.id)
    hasher.combine(publication.invocationId)
  }
  @MainActor init(part: McpAppPart, message: WebMessage, store: ConsoleStore) {
    profile = store.profile.id
    thread = message.threadId
    self.message = message.id
    var identity = part
    identity.resourceUrl = nil
    identity.bridgeUrl = nil
    // Equality still covers every sanitized publication field; hashing needs only stable IDs.
    publication = identity
  }
}

/// Scene/transcript-owned admission, including in-progress loads. No retained document cache.
@MainActor @Observable final class McpHostPool {
  let consent = McpNativeConsent()
  #if DEBUG
    private(set) var debugCreatedControllers = 0
    func recordControllerCreation() { debugCreatedControllers += 1 }
  #endif
  private(set) var activeCount = 0
  private(set) var isActive = true
  @ObservationIgnored private var order: UInt64 = 0
  @ObservationIgnored private var arrivals: Set<McpPartIdentity> = []
  private struct Entry {
    weak var owner: McpPartController?
    let order: UInt64
  }
  @ObservationIgnored private var entries: [UUID: Entry] = [:]
  func acquire(_ owner: McpPartController) -> Bool {
    guard isActive else { return false }
    entries = entries.filter { $0.value.owner != nil }
    if entries[owner.id] != nil { return true }
    if entries.count >= 2 {
      let oldest = entries.values.sorted {
        let leftVisible = $0.owner?.isVisible == true
        let rightVisible = $1.owner?.isVisible == true
        return leftVisible != rightVisible ? !leftVisible : $0.order < $1.order
      }.first?.owner
      oldest?.stop(.closed, text: "App paused to free resources. Reopen to load it again.")
    }
    guard entries.count < 2 else { return false }
    order &+= 1
    entries[owner.id] = Entry(owner: owner, order: order)
    activeCount = entries.count
    return true
  }
  func release(_ id: UUID) {
    entries[id] = nil
    activeCount = entries.count
  }
  func closeAll(_ text: String = "The app was paused. Reopen to load it again.") {
    let owners = entries.values.compactMap(\.owner)
    for owner in owners { owner.stop(.closed, text: text) }
    entries.removeAll()
    activeCount = 0
  }
  func firstArrival(_ identity: McpPartIdentity) -> Bool { arrivals.insert(identity).inserted }
  func retainMessages(_ ids: [String]) { arrivals = arrivals.filter { ids.contains($0.message) } }
  func selectionChanged(_ threadID: String?) {
    arrivals = arrivals.filter { $0.thread == threadID }
    let owners = entries.values.compactMap(\.owner).filter { $0.threadID != threadID }
    for owner in owners {
      owner.stop(.closed, text: "The selected conversation changed. Reopen to load the app again.")
    }
  }
  func sceneChanged(_ phase: ScenePhase) {
    if phase == .background { setActive(false) } else if phase == .active { setActive(true) }
  }
  func setActive(_ active: Bool) {
    isActive = active
    if !active { closeAll() }
  }
}

@MainActor @Observable final class McpPartController {
  enum Phase: Equatable { case hidden, loading, ready, unavailable, closed, error }
  let id = UUID()
  let part: McpAppPart
  let threadID: String
  let messageID: String
  private let identity: McpPartIdentity
  private(set) var phase: Phase = .hidden
  private(set) var status = "App hidden. Show to load the interactive app."
  private(set) var bridge: McpAppBridge?
  private(set) var isVisible = false
  private(set) var hasArrived = false
  private var lean: Bool
  private var wantsOpen = false
  private var environment = McpHostEnvironment()
  private let store: ConsoleStore
  private let pool: McpHostPool
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  @ObservationIgnored private var session: McpAppAccess?
  init(part: McpAppPart, message: WebMessage, store: ConsoleStore, pool: McpHostPool) {
    #if DEBUG
      pool.recordControllerCreation()
    #endif
    self.part = part
    identity = McpPartIdentity(part: part, message: message, store: store)
    threadID = message.threadId
    messageID = message.id
    self.store = store
    self.pool = pool
    lean = store.effectiveDataMode == .lean
  }
  var degraded: Bool { bridge?.retryRequiresConsent == true }
  var displayedStatus: String {
    degraded ? "App access expired. Reopen for fresh access and confirmation." : status
  }
  var actionTitle: String {
    if degraded { return "Reopen" }
    switch phase {
    case .hidden: return "Show"
    case .loading, .ready: return "Hide"
    case .closed, .error, .unavailable: return "Reopen"
    }
  }
  var isError: Bool { degraded || [.closed, .error, .unavailable].contains(phase) }
  var showsWebContent: Bool { !degraded && bridge?.host != nil && bridge?.state != .closed }
  func activateAction() {
    if !hasArrived {
      hasArrived = true
      _ = pool.firstArrival(identity)
    }
    if actionTitle == "Hide" {
      hide()
      return
    }
    // A native button tap is visibility evidence even if scroll visibility didn't re-emit
    // after a cover or navigation transition.
    isVisible = true
    if degraded { stop(.closed, text: displayedStatus) }
    open()
  }
  func visibility(_ visible: Bool) {
    guard isVisible != visible else { return }
    isVisible = visible
    if !visible {
      if bridge != nil || phase == .loading {
        stop(.hidden, text: "App hidden. Show to load the interactive app.")
      }
      return
    }
    if !hasArrived {
      hasArrived = true
      if pool.firstArrival(identity) && !lean { wantsOpen = true }
    }
    if wantsOpen && phase == .hidden { open() }
  }
  func setLean(_ lean: Bool) { self.lean = lean }
  func open(timeout: Duration = .seconds(15)) {
    wantsOpen = true
    guard isVisible, pool.isActive, phase != .loading, phase != .ready else { return }
    guard pool.acquire(self) else { return }
    generation &+= 1
    let current = generation
    phase = .loading
    status = "Loading interactive app…"
    deadline?.cancel()
    deadline = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let self, self.generation == current, self.phase == .loading else {
        return
      }
      self.stop(.closed, text: "The app did not initialize in time. Reopen to try again.")
    }
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        let access = try await self.store.loadMcpApp(
          threadID: self.threadID, messageID: self.messageID, partID: self.part.id)
        guard !Task.isCancelled, self.generation == current, self.isVisible else {
          self.store.closeMcpApp(access)
          return
        }
        self.session = access
        guard access.resource?.app.hasSameMcpResourceIdentity(as: self.part) == true else {
          self.stop(.closed, text: "The app identity changed. Reopen to load it again.")
          return
        }
        guard access.resource?.connected == true else {
          self.stop(
            .unavailable, text: "This MCP App is unavailable. Reopen to request fresh access.")
          return
        }
        let bridge = try await McpAppBridge.make(
          store: self.store, session: access, consent: self.pool.consent,
          environment: self.environment)
        guard !Task.isCancelled, self.generation == current, self.isVisible else {
          bridge.close()
          return
        }
        self.bridge = bridge
        self.observeBridge()
      } catch {
        guard !Task.isCancelled, self.generation == current else { return }
        if let error = error as? APIError,
          error.status == 404 || error.status == 409 || error.status == 410
        {
          self.stop(
            .unavailable, text: "This MCP App is unavailable. Reopen to request fresh access.")
        } else {
          self.stop(.error, text: "The interactive app could not load. Reopen to try again.")
        }
      }
    }
  }
  private func observeBridge() {
    guard let bridge else { return }
    if bridge.state == .closed {
      stop(.closed, text: bridge.statusText)
      return
    }
    if bridge.state == .ready {
      phase = .ready
      status = "Interactive app ready."
      deadline?.cancel()
      deadline = nil
    }
    withObservationTracking {
      _ = bridge.state
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeBridge() }
    }
  }
  func updateEnvironment(_ environment: McpHostEnvironment) {
    self.environment = environment
    guard let bridge else { return }
    Task { await bridge.updateEnvironment(environment) }
  }
  func hide() { stop(.hidden, text: "App hidden. Show to load the interactive app.") }
  func stop(_ next: Phase, text: String) {
    generation &+= 1
    wantsOpen = false
    operation?.cancel()
    operation = nil
    deadline?.cancel()
    deadline = nil
    bridge?.close()
    bridge = nil
    if let session { store.closeMcpApp(session) }
    session = nil
    pool.release(id)
    phase = next
    status = text
  }
  static func displayHeight(_ requested: Double, viewport: Double, compact: Bool) -> Double {
    let bounded = max(160, min(1600, requested.isFinite ? requested : 320))
    return compact && viewport > 0 ? max(160, min(bounded, viewport * 0.7)) : bounded
  }
  isolated deinit {
    operation?.cancel()
    deadline?.cancel()
    bridge?.close()
    if let session { store.closeMcpApp(session) }
    pool.release(id)
  }
}
