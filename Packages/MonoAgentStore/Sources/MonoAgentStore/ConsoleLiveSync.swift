// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum ConsoleScenePhase: Sendable { case active, inactive, background }
extension ConsoleStore {
  func scheduleSubscription() {
    subscriptionTask?.cancel()
    guard !backgrounded else { return }
    let generation = epoch
    subscriptionTask = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: 0.25) } catch { return }
      guard let self, self.epoch == generation, !Task.isCancelled else { return }
      await self.connectStream()
    }
  }
  func connectStream() async {
    guard !backgrounded else { return }
    subscriptionRevision &+= 1
    let subscription = subscriptionRevision
    streamTask?.cancel()
    streamGeneration = 0
    let generation = epoch
    let updates = await events.subscribe(thread: selectedThreadID, capacity: 128)
    guard epoch == generation, subscriptionRevision == subscription, !backgrounded else { return }
    streamTask = Task { [weak self] in
      do {
        for try await update in updates {
          guard let self, self.epoch == generation, self.subscriptionRevision == subscription,
            !Task.isCancelled
          else { return }
          await self.receive(update)
        }
      } catch {
        guard let self, self.epoch == generation, !Task.isCancelled else { return }
        self.connection = .waiting
        self.markGap(bootstrap: true)
      }
    }
  }
  /// Public to support deterministic scripted fixtures; production receives Kit updates only.
  public func receive(_ update: StreamUpdate) async {
    guard !backgrounded else { return }
    switch update {
    case .connecting(let generation, let reason):
      guard generation >= streamGeneration else { return }
      streamGeneration = generation
      connection = .connecting
      markGap(bootstrap: reason != .initial && reason != .subscriptionChanged)
    case .gap(let generation, let reason):
      guard generation >= streamGeneration else { return }
      streamGeneration = generation
      markGap(bootstrap: reason != .initial && reason != .subscriptionChanged)
      // EventStream owns reconnect, including overflow. Never create a second subscription here.
      requestReconciliation()
    case .waiting(let generation, _, _):
      guard generation >= streamGeneration else { return }
      streamGeneration = generation
      connection = .waiting
    case .diagnostic: break
    case .unreadable(let generation, let event):
      guard generation >= streamGeneration else { return }
      streamGeneration = generation
      if let thread = event.threadId {
        observe(thread)
        if let message = event.messageId {
          repairMessage(threadID: thread, messageID: message)
        } else {
          requestDetailRepair(thread)
        }
      } else {
        markGap(bootstrap: false)
        requestReconciliation()
      }
    case .event(let generation, _, let envelope):
      guard generation >= streamGeneration else { return }
      streamGeneration = generation
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let timestamp = formatter.date(from: envelope.at)
        ?? ISO8601DateFormatter().date(from: envelope.at)
      {
        let generation = epoch
        let now = await clock.wallNow()
        guard epoch == generation else { return }
        serverClockOffset = timestamp.timeIntervalSince(now)
      }
      await apply(envelope)
    }
  }
  func apply(_ envelope: ApiEvent) async {
    if let id = envelope.threadId { observe(id) } else { observation &+= 1 }
    switch envelope.event {
    case .ready:
      pendingDiscontinuity = false
      connection = .live
      requestReconciliation()
    case .messageDelta(let delta):
      guard let id = envelope.threadId else {
        markGap(bootstrap: false)
        return
      }
      let state = conversations[id]
      let message = state?.record.messages.first { $0.id == delta.messageId }
      let result = DeltaReducer.apply(
        delta, to: message, threadHeld: state != nil,
        repairedToolCallIds: state?.record.repairedToolCallIDs ?? [])
      switch result.outcome {
      case .applied:
        if let state, let message = result.message,
          let index = state.record.messages.firstIndex(where: { $0.id == message.id })
        {
          state.record.messages[index] = message
          publish(state, terminal: message.status != "running")
          scheduleCache()
        }
      case .stale, .unheld: break
      case .gap, .unknown:
        repairMessage(threadID: id, messageID: delta.messageId, wantedSeq: delta.seq)
      }
    case .messageChanged(let payload):
      if let id = envelope.threadId { repairMessage(threadID: id, messageID: payload.messageId) }
    case .threadChanged(let payload): applyThreadChange(payload)
    case .threadsChanged(let payload):
      if let payload {
        applyThreadChange(payload)
      } else {
        markGap(bootstrap: false)
        requestReconciliation()
      }
    case .turnChanged(let payload):
      if let id = envelope.threadId {
        if let state = conversations[id] {
          state.record.thread.runState = payload.turn
          state.runningConfirmed = true
          publish(state, terminal: payload.turn.status != "running")
        }
        confirmedSummaryIDs.insert(id)
        for key in buckets.keys {
          if let index = buckets[key]?.threads.firstIndex(where: { $0.id == id }) {
            buckets[key]?.threads[index].runState = payload.turn
          }
        }
        if let index = activeFleet?.threads.firstIndex(where: { $0.id == id }) {
          activeFleet?.threads[index].runState = payload.turn
        }
        scheduleCache()
      }
    case .agentsChanged:
      needsBootstrap = true
      requestReconciliation()
    case .tagsChanged(let payload):
      if payload.removed == true, let id = payload.tagId {
        tags.removeAll { $0.id == id }
      } else if let tag = payload.tag {
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
          if tag.revision >= tags[index].revision { tags[index] = tag }
        } else {
          tags.append(tag)
        }
      }
      requestReconciliation()
    case .projectsChanged(let payload):
      if payload.removed == true, let id = payload.projectId {
        projects.removeAll { $0.id == id }
      } else if let project = payload.project {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
          if project.revision >= projects[index].revision { projects[index] = project }
        } else {
          projects.append(project)
        }
      }
      requestReconciliation()
    case .attachmentChanged:
      if let id = envelope.threadId { requestDetailRepair(id) }
    case .cronChanged, .pushPending: break
    }
  }
  func applyThreadChange(_ payload: ThreadChangedPayload) {
    if payload.removed == true, let id = payload.threadId ?? payload.thread?.id {
      removeThread(id)
      return
    }
    if let thread = payload.thread {
      guard !tombstones.contains(thread.id) else { return }
      let heldRows = buckets.values.flatMap(\.threads) + (activeFleet?.threads ?? [])
      let revision = max(
        conversations[thread.id]?.record.thread.revision ?? 0,
        heldRows.filter { $0.id == thread.id }.map(\.revision).max() ?? 0)
      guard thread.revision >= revision else { return }
      observe(thread.id)
      patchSummary(thread)
      for key in buckets.keys where key.sourceID == thread.sourceId {
        let belongs = key.archived == (thread.archivedAt != nil)
        if !belongs {
          buckets[key]?.threads.removeAll { $0.id == thread.id }
        } else if buckets[key]?.threads.contains(where: { $0.id == thread.id }) == false,
          !tombstones.contains(thread.id)
        {
          buckets[key]?.threads.insert(thread, at: 0)
        }
      }
      noteSummary(thread)
      scheduleCache()
    }
  }
  func requestDetailRepair(_ id: String) {
    guard conversations[id] != nil || id == selectedThreadID else { return }
    let key = id + "\u{0}detail"
    repairDirty.insert(key)
    guard repairs[key] == nil else { return }
    let generation = epoch
    repairs[key] = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.epoch == generation {
          self.repairs[key] = nil
          self.repairDirty.remove(key)
        }
      }
      repeat {
        self.repairDirty.remove(key)
        await self.refreshDetail(id)
      } while self.repairDirty.contains(key) && self.epoch == generation && !Task.isCancelled
    }
  }
  func markGap(bootstrap: Bool) {
    observation &+= 1
    freshness = .stale
    for id in conversations.keys {
      observations[id] = observation
      conversations[id]?.freshness = .stale
    }
    for key in buckets.keys { buckets[key]?.freshness = .stale }
    if bootstrap && !pendingDiscontinuity {
      needsBootstrap = true
      pendingDiscontinuity = true
    }
  }
  func requestReconciliation() {
    guard !backgrounded else { return }
    reconciliationDirty = true
    guard reconciliationTask == nil else { return }
    let generation = epoch
    reconciliationTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == generation { self.reconciliationTask = nil } }
      repeat {
        self.reconciliationDirty = false
        await self.reconcilePass()
      } while self.reconciliationDirty && self.epoch == generation && !Task.isCancelled
    }
  }
  /// Explicit refresh joins the single reconciliation flight.
  public func reconcile() async {
    requestReconciliation()
    await reconciliationTask?.value
  }
  func reconcilePass() async {
    let generation = epoch
    if needsBootstrap {
      needsBootstrap = false
      await refreshBootstrap()
    }
    guard epoch == generation, !Task.isCancelled else { return }
    if let id = selectedThreadID { await refreshDetail(id) }
    guard epoch == generation, !Task.isCancelled else { return }
    if let bucket = selectedBucket { await refreshBucket(bucket) }
    guard epoch == generation, !Task.isCancelled else { return }
    await refreshActiveFleet()
    guard epoch == generation, !Task.isCancelled else { return }
    await refreshRegistries()
    guard epoch == generation, !Task.isCancelled else { return }
    await recoverSubmissions()
  }
  public func scenePhaseChanged(_ phase: ConsoleScenePhase) async {
    switch phase {
    case .inactive: break
    case .background:
      guard !backgrounded else { return }
      backgrounded = true
      await stopEffects()
      publishAll()
      await discardStagedUploads()
      await flushAuthored()
      await flushCache()
    case .active:
      guard backgrounded else { return }
      backgrounded = false
      pendingDiscontinuity = false
      markGap(bootstrap: true)
      await connectStream()
    // Reconciliation starts after ready so selected deltas cannot fall into the setup gap.
    }
  }
  public func stop() async {
    backgrounded = true
    await stopEffects()
    await flushAuthored()
    await flushCache()
    await discardStagedUploads()
  }
  func stopEffects() async {
    epoch &+= 1
    streamTask?.cancel()
    streamTask = nil
    subscriptionTask?.cancel()
    subscriptionTask = nil
    draftTask?.cancel()
    draftTask = nil
    publicationTask?.cancel()
    publicationTask = nil
    cacheTask?.cancel()
    cacheTask = nil
    reconciliationTask?.cancel()
    reconciliationTask = nil
    for task in repairs.values { task.cancel() }
    repairs.removeAll()
    recoveries.removeAll()
    repairDirty.removeAll()
    repairWanted.removeAll()
    for task in writeTasks.values { task.cancel() }
    writeTasks.removeAll()
    connection = .offline
    markGap(bootstrap: true)
    await events.cancel()
  }
}
