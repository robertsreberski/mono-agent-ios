// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

extension ConsoleStore {
  public func refreshBootstrap() async {
    let request = UUID()
    bootstrapRequest = request
    let generation = epoch
    let began = observation
    let globalBegan = bootstrapClock
    let selected = selection
    let fetchedAt = await clock.wallNow()
    do {
      let result = try await api.bootstrap(
        query: .init(
          sourceId: selectedBucket?.sourceID,
          archived: selectedBucket?.archived, limit: pageLimit), etag: bootstrapETag)
      guard epoch == generation, bootstrapRequest == request,
        !Task.isCancelled
      else { return }
      if case .modified(let value, let etag) = result {
        bootstrap = value
        bootstrapETag = etag
        if observation == began, selection == selected {
          tags = value.tags
          projects = value.projects
        }
        if let active = value.activeThreads { applyFleet(active, fetchedAt: fetchedAt) }
        if selection == selected, let source = value.threadsSourceId {
          let key = BucketKey(sourceID: source, archived: selectedBucket?.archived ?? false)
          if selectedBucket == nil { selectedBucket = key }
          mergeBucket(
            key, rows: value.threads, cursor: value.threadsNextCursor, older: false,
            fresh: observation == began, fetchedAt: fetchedAt)
        }
      }
      freshness = bootstrapClock == globalBegan ? .fresh : .stale
      scheduleCache()
    } catch {
      if epoch == generation { errorMessage = "Console refresh failed; cached data may be stale." }
    }
  }
  var pageLimit: Int { effectiveDataMode == .lean ? 25 : 50 }
  var messagePageLimit: Int { effectiveDataMode == .lean ? 15 : 30 }
  public func refreshBucket(_ key: BucketKey, older: Bool = false) async {
    let generation = epoch
    let began = observation
    let cursor = older ? buckets[key]?.nextCursor : nil
    if older && cursor == nil { return }
    let fetchedAt = await clock.wallNow()
    do {
      let result = try await api.threads(
        query: .init(
          sourceId: key.sourceID, archived: key.archived,
          limit: pageLimit, before: cursor), etag: nil)
      guard epoch == generation, !Task.isCancelled else { return }
      if case .modified(let value, _) = result {
        mergeBucket(
          key, rows: value.threads, cursor: value.nextCursor, older: older,
          fresh: observation == began, fetchedAt: fetchedAt)
        scheduleCache()
      }
    } catch {
      if epoch == generation { errorMessage = "Conversation list could not be refreshed." }
    }
  }
  func mergeBucket(
    _ key: BucketKey, rows: [WebThread], cursor: String?, older: Bool, fresh: Bool,
    fetchedAt: Date? = nil
  ) {
    let old = buckets[key]?.threads ?? []
    let mapped = rows.filter { acceptSummary($0, fetchedAt: fetchedAt) }.map { row -> WebThread in
      noteSummary(row)
      patchSummary(row, listed: true)
      if let detail = conversations[row.id]?.record.thread, detail.revision >= row.revision {
        return detail
      }
      let held = old.first { $0.id == row.id }
      return held.map { $0.revision >= row.revision ? $0 : row } ?? row
    }
    let ids = Set(mapped.map(\.id))
    let combined = older ? old + mapped.filter { row in !old.contains { $0.id == row.id } } : mapped
    // Preserve paged-in tail when revalidating the current authoritative page.
    let tail =
      !older && cursor != nil ? old.dropFirst(pageLimit).filter { !ids.contains($0.id) } : []
    var bucket = ThreadBucket(
      key: key, threads: combined + tail, nextCursor: cursor, savedAt: fetchedAt ?? Date())
    bucket.freshness = fresh ? .fresh : .stale
    buckets[key] = bucket
  }
  public func refreshDetail(_ id: String) async {
    pruneTombstones()
    guard !tombstones.keys.contains(id) else { return }
    let request = UUID()
    detailRequests[id] = request
    defer { if detailRequests[id] == request { detailRequests[id] = nil } }
    let generation = epoch
    let selected = selection
    let wasSelected = selectedThreadID == id
    let began = observations[id] ?? 0
    let etag = conversations[id]?.etag
    do {
      let result = try await api.thread(id: id, query: .init(), etag: etag)
      guard epoch == generation, detailRequests[id] == request, !Task.isCancelled,
        !tombstones.keys.contains(id),
        !wasSelected || selection == selected
      else { return }
      missingReads[id] = nil
      switch result {
      case .notModified:
        if let state = conversations[id], began == (observations[id] ?? 0) {
          state.freshness = .fresh
          state.runningConfirmed = true
          noteSummary(state.thread)
        }
      case .modified(let value, let validator):
        let now = await clock.wallNow()
        guard epoch == generation, detailRequests[id] == request, !tombstones.keys.contains(id),
          !wasSelected || selection == selected
        else { return }
        let previous = conversations[id]?.record
        var record = CachedConversation(
          thread: value.thread, messages: value.messages,
          nextCursor: value.messagesNextCursor, savedAt: now)
        if let previous {
          if previous.thread.revision > record.thread.revision || began != (observations[id] ?? 0) {
            record.thread = previous.thread
          }
          record.pagedIDs = previous.pagedIDs
          record.repairedToolCallIDs = previous.repairedToolCallIDs
          record.messages = TranscriptMerge.window(
            value.messages, held: previous.messages,
            paged: previous.pagedIDs, repaired: previous.repairedToolCallIDs,
            complete: value.messagesNextCursor == nil)
        }
        guard epoch == generation, detailRequests[id] == request, !tombstones.keys.contains(id),
          !wasSelected || selection == selected
        else { return }
        hold(record)
        patchSummary(record.thread)
        conversations[id]?.etag = validator
        conversations[id]?.freshness = began == (observations[id] ?? 0) ? .fresh : .stale
        noteSummary(record.thread)
        scheduleCache()
      }
    } catch {
      guard epoch == generation, detailRequests[id] == request else { return }
      if let error = error as? APIError, error.status == 404 {
        let instant = await clock.now()
        let now = await clock.wallNow()
        guard epoch == generation, detailRequests[id] == request, !Task.isCancelled else { return }
        if let first = missingReads[id], instant - first >= ConsoleBounds.notFoundConfirmation {
          removeThread(id, origin: .notFound, now: now)
        } else {
          if missingReads[id] == nil { missingReads[id] = instant }
          if missingReads.count > 256,
            let oldest = missingReads.min(by: { $0.value < $1.value })?.key
          {
            missingReads[oldest] = nil
          }
          conversations[id]?.freshness = .stale
        }
      } else {
        errorMessage = "Conversation could not be refreshed."
      }
    }
  }
  public func loadOlder() async {
    guard let id = selectedThreadID, let state = conversations[id], let cursor = state.nextCursor
    else { return }
    let generation = epoch
    let selected = selection
    do {
      let page = try await api.messages(
        id: id, query: .init(before: cursor, limit: messagePageLimit), etag: nil)
      guard epoch == generation, selection == selected, !tombstones.keys.contains(id),
        !Task.isCancelled
      else { return }
      if case .modified(let value, _) = page {
        let ids = Set(state.record.messages.map(\.id))
        let old = value.messages.filter { !ids.contains($0.id) }
        state.record.messages =
          old
          + state.record.messages.map { held in
            guard let fetched = value.messages.first(where: { $0.id == held.id }) else {
              return held
            }
            return TranscriptMerge.message(
              fetched, held: held, repaired: state.record.repairedToolCallIDs)
          }
        state.record.pagedIDs.formUnion(value.messages.map(\.id))
        state.record.nextCursor = value.nextCursor
        state.publish()
        scheduleCache()
      }
    } catch { if epoch == generation { errorMessage = "Older messages could not be loaded." } }
  }
  public func refreshActiveFleet() async {
    let generation = epoch
    let fetchedAt = await clock.wallNow()
    do {
      let result = try await api.activeThreads(etag: nil)
      guard epoch == generation, !Task.isCancelled else { return }
      if case .modified(let value, _) = result { applyFleet(value, fetchedAt: fetchedAt) }
    } catch { if epoch == generation { errorMessage = "Active fleet could not be refreshed." } }
  }
  func applyFleet(_ incoming: WebActiveThreads, fetchedAt: Date? = nil) {
    var value = incoming
    value.threads = incoming.threads.filter { acceptSummary($0, fetchedAt: fetchedAt) }.map { row in
      noteSummary(row)
      patchSummary(row, listed: true)
      if let detail = conversations[row.id]?.record.thread, detail.revision >= row.revision {
        return detail
      }
      if let held = activeFleet?.threads.first(where: { $0.id == row.id }),
        held.revision >= row.revision
      {
        return held
      }
      return row
    }
    activeFleet = value
  }
  func refreshRegistries() async {
    guard let source = selectedBucket?.sourceID else { return }
    await refreshOrganizeLabels(sourceID: source)
  }
  public func refreshOrganizeLabels(sourceID: String) async {
    guard canOrganize else { return }
    let generation = epoch
    let selected = selection
    do {
      let tagsBegan = tags.filter { $0.sourceId == sourceID }
      let tagResult = try await api.tags(query: .init(sourceId: sourceID), etag: nil)
      try checkOrganizeResponse(epoch: generation, selection: selected)
      if case .modified(let value, _) = tagResult {
        tags =
          tags.filter { $0.sourceId != sourceID }
          + mergeOrganizeRegistry(
            baseline: tagsBegan, current: tags.filter { $0.sourceId == sourceID },
            fetched: value.tags.filter { $0.sourceId == sourceID }, id: \.id, revision: \.revision)
      }
      let projectsBegan = projects.filter { $0.sourceId == sourceID }
      let projectResult = try await api.projects(query: .init(sourceId: sourceID), etag: nil)
      try checkOrganizeResponse(epoch: generation, selection: selected)
      if case .modified(let value, _) = projectResult {
        projects =
          projects.filter { $0.sourceId != sourceID }
          + mergeOrganizeRegistry(
            baseline: projectsBegan, current: projects.filter { $0.sourceId == sourceID },
            fetched: value.projects.filter { $0.sourceId == sourceID }, id: \.id,
            revision: \.revision)
      }
    } catch {
      if canOrganize, epoch == generation, selection == selected, !(error is CancellationError) {
        errorMessage = "Tags and projects may be stale."
      }
    }
  }
  /// Preserve only rows changed during this read; unrelated SSE envelopes cannot starve it.
  private func mergeOrganizeRegistry<Row: Equatable>(
    baseline: [Row], current: [Row], fetched: [Row], id: KeyPath<Row, String>,
    revision: KeyPath<Row, Int>
  ) -> [Row] {
    let before = Dictionary(
      baseline.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { _, last in last })
    let held = Dictionary(
      current.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { _, last in last })
    var merged = fetched.compactMap { row -> Row? in
      let key = row[keyPath: id]
      if held[key] != before[key] { return held[key] }
      if let current = held[key], current[keyPath: revision] > row[keyPath: revision] {
        return current
      }
      return row
    }
    for row in current
    where held[row[keyPath: id]] != before[row[keyPath: id]]
      && !merged.contains(where: { $0[keyPath: id] == row[keyPath: id] })
    { merged.append(row) }
    return merged
  }
  func patchSummary(_ incoming: WebThread, listed: Bool = false) {
    guard acceptSummary(incoming) else { return }
    if let state = conversations[incoming.id] {
      guard incoming.revision >= state.record.thread.revision else { return }
      if incoming.revision > state.record.thread.revision
        || (!listed && incoming.revision == state.record.thread.revision)
      {
        state.record.thread = incoming
        state.thread = incoming
      }
      state.runningConfirmed = true
    }
    for key in buckets.keys {
      guard let index = buckets[key]?.threads.firstIndex(where: { $0.id == incoming.id }),
        let held = buckets[key]?.threads[index], incoming.revision >= held.revision
      else { continue }
      if !listed || incoming.revision > held.revision { buckets[key]?.threads[index] = incoming }
    }
    if let index = activeFleet?.threads.firstIndex(where: { $0.id == incoming.id }),
      let held = activeFleet?.threads[index], incoming.revision >= held.revision,
      !listed || incoming.revision > held.revision
    {
      activeFleet?.threads[index] = incoming
    }
  }
  func pruneTombstones() { tombstones = CacheMerge.prune(tombstones, now: Date()) }
  func acceptSummary(_ row: WebThread, fetchedAt: Date? = nil) -> Bool {
    pruneTombstones()
    if let removed = tombstones[row.id] {
      guard removed.allows(revision: row.revision, fetchedAt: fetchedAt) else { return false }
      tombstones[row.id] = nil
    }
    if let fetchedAt {
      authoritativeRows[row.id] = fetchedAt
      if authoritativeRows.count > 256,
        let oldest = authoritativeRows.min(by: { $0.value < $1.value })?.key
      {
        authoritativeRows[oldest] = nil
      }
    }
    missingReads[row.id] = nil
    return true
  }
  func removeThread(_ id: String, origin: ThreadTombstone.Origin = .removed, now: Date = Date()) {
    observe(id)
    let revision = max(
      conversations[id]?.thread.revision ?? 0,
      (buckets.values.flatMap(\.threads) + (bootstrap?.threads ?? []) + (activeFleet?.threads ?? []))
        .filter { $0.id == id }.map(\.revision).max() ?? 0)
    tombstones[id] = ThreadTombstone(revision: revision, removedAt: now, origin: origin)
    tombstones = CacheMerge.prune(tombstones, now: now)
    missingReads[id] = nil
    authoritativeRows[id] = nil
    conversations[id] = nil
    lru.removeAll { $0 == id }
    for key in buckets.keys { buckets[key]?.threads.removeAll { $0.id == id } }
    activeFleet?.threads.removeAll { $0.id == id }
    bootstrap?.threads.removeAll { $0.id == id }
    bootstrap?.activeThreads?.threads.removeAll { $0.id == id }
    scheduleCache()
  }

  /// Single-flight repair with a trailing obligation. Unknown sequence hints always trail once.
  public func repairMessage(threadID: String, messageID: String, wantedSeq: Int? = nil) {
    guard conversations[threadID] != nil, !tombstones.keys.contains(threadID), !backgrounded else {
      return
    }
    let key = threadID + "\u{0}" + messageID
    if let wantedSeq {
      repairWanted[key] = max(repairWanted[key] ?? 0, wantedSeq)
    } else {
      repairDirty.insert(key)
    }
    guard repairs[key] == nil else { return }
    let generation = epoch
    repairs[key] = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.epoch == generation {
          self.repairs[key] = nil
          self.repairDirty.remove(key)
          self.repairWanted[key] = nil
        }
      }
      repeat {
        self.repairDirty.remove(key)
        self.repairWanted[key] = nil
        do {
          let result = try await self.api.message(
            threadId: threadID, messageId: messageID, query: .init(), etag: nil)
          guard self.epoch == generation, !Task.isCancelled,
            !self.tombstones.keys.contains(threadID),
            let state = self.conversations[threadID]
          else { return }
          if case .modified(let value, _) = result {
            TranscriptMerge.insert(
              value.message, into: &state.record.messages,
              repaired: state.record.repairedToolCallIDs)
            self.publish(state, terminal: value.message.status != "running")
            if (value.message.seq ?? -1) >= (self.repairWanted[key] ?? 0) {
              self.repairWanted[key] = nil
            }
          }
          self.scheduleCache()
        } catch { return }
      } while self.repairDirty.contains(key) || self.repairWanted[key] != nil
    }
  }
  @discardableResult
  public func repairToolOutput(threadID: String, messageID: String, toolCallID: String) async
    -> Bool
  {
    let generation = epoch
    do {
      let result = try await api.toolCall(
        threadId: threadID, messageId: messageID, toolCallId: toolCallID, etag: nil)
      guard epoch == generation, !tombstones.keys.contains(threadID),
        let state = conversations[threadID],
        let index = state.record.messages.firstIndex(where: { $0.id == messageID })
      else { return false }
      if case .modified(let value, _) = result {
        var message = state.record.messages[index]
        guard
          let slot = message.parts.firstIndex(where: { part in
            switch part {
            case .toolCall(let v), .subagent(let v): return v.toolCallId == toolCallID
            default: return false
            }
          })
        else { return false }
        let current = message.parts[slot]
        let ids: Set<String>
        switch value.part {
        case .toolCall(let tool), .subagent(let tool):
          ids = Set([tool.toolCallId] + (tool.calls ?? []).map(\.toolCallId))
        default: return false
        }
        // The read may have raced a rewrite. Install full bodies only under matching digests.
        let merged = try DeltaReducer.apply(
          ops: [.set(index: 0, part: current)], to: [value.part], repairedToolCallIds: ids)
        message.parts[slot] = merged[0]
        state.record.messages[index] = message
        state.record.repairedToolCallIDs.formUnion(ids)
        state.publish()
        scheduleCache()
        return merged[0] != current
      }
    } catch { if epoch == generation { errorMessage = "Full tool output could not be loaded." } }
    return false
  }
}
