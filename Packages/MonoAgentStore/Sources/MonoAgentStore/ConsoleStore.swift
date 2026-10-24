// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public protocol ConsoleEventSource: Sendable {
  func subscribe(thread: String?, capacity: Int) async -> AsyncThrowingStream<
    StreamUpdate, any Error
  >
  func cancel() async
}
extension EventStream: ConsoleEventSource {}
public protocol UploadReservations: Sendable {
  func disposeVisible() async
}
public struct NoUploadReservations: UploadReservations {
  public init() {}
  public func disposeVisible() async {}
}

/// One connected console in one scene. Commands are the only mutation seam for feature UI.
@MainActor @Observable
public final class ConsoleStore {
  public let profile: SavedConsole
  public let namespace: ConsoleNamespace
  public internal(set) var bootstrap: ApiBootstrap?
  public var agents: [WebAgentSummary] { bootstrap?.agents ?? [] }
  public internal(set) var buckets: [BucketKey: ThreadBucket] = [:]
  public internal(set) var activeFleet: WebActiveThreads?
  public internal(set) var tags: [WebTag] = []
  public internal(set) var projects: [WebProject] = []
  public internal(set) var selectedBucket: BucketKey?
  public internal(set) var selectedThreadID: String?
  public internal(set) var conversations: [String: ConversationState] = [:]
  public var selectedConversation: ConversationState? {
    selectedThreadID.flatMap { conversations[$0] }
  }
  public internal(set) var connection: SyncState = .offline
  public internal(set) var freshness: Freshness = .stale
  public internal(set) var storage: PersistenceState = .durable
  public internal(set) var authoredStorage: PersistenceState = .durable
  public internal(set) var journalStorage: PersistenceState = .durable
  public internal(set) var errorMessage: String?
  public internal(set) var dataMode: DataMode = .auto
  public internal(set) var isConstrained = false
  public var effectiveDataMode: DataMode {
    dataMode == .auto ? (isConstrained ? .lean : .full) : dataMode
  }
  public var drafts: [ComposerDraft] {
    _ = authoredRevision
    return authored.drafts
  }
  public var pendingSubmissions: [SubmissionReference] {
    _ = journalRevision
    return journal.pending
  }
  public internal(set) var serverClockOffset: TimeInterval = 0
  public internal(set) var confirmedSummaryIDs: Set<String> = []
  public func isRunningConfirmed(threadID: String) -> Bool {
    confirmedSummaryIDs.contains(threadID)
  }
  public var isStarted: Bool { started }
  public internal(set) var hydrated = false
  public internal(set) var draftClearStorage: [String: PersistenceState] = [:]
  public internal(set) var tagDeletionConfirmation: TagDeletionConfirmation?
  public internal(set) var projectMembers: [String: ProjectMembers] = [:]
  public internal(set) var projectConfirmation: ProjectConfirmation?
  @ObservationIgnored var projectMemberRequests: [String: UUID] = [:]
  public internal(set) var conversationActionConfirmation: ConversationActionConfirmation?
  public internal(set) var pendingConversationActions: [String: UUID] = [:]
  public internal(set) var manualCompactions: [String: ManualCompactionState] = [:]
  public internal(set) var stagedAttachments: [WebAttachment] = []
  public internal(set) var uploadProgress: [UploadProgressItem] = []
  /// Per-agent skill registries for the composer; memory only, refreshed on demand.
  public internal(set) var skillRegistries: [String: SkillRegistryState] = [:]
  @ObservationIgnored var uploadTasks: [UUID: Task<[WebAttachment], any Error>] = [:]

  @ObservationIgnored var restartProposals: [ReplyPartReference: RestartProposalState] = [:]
  @ObservationIgnored let replyImages = ReplyImageCache()
  @ObservationIgnored let replyFiles: ReplyFileCache
  @ObservationIgnored var mcpApps: [ReplyPartReference: McpAppAccess] = [:]
  @ObservationIgnored let capabilities: CapabilityService
  @ObservationIgnored let api: any ConsoleAPI
  @ObservationIgnored let events: any ConsoleEventSource
  @ObservationIgnored let repository: any ConsoleRepository
  @ObservationIgnored let clock: any StreamClock
  @ObservationIgnored let uploads: any UploadReservations
  @ObservationIgnored var authored = AuthoredRecord()
  @ObservationIgnored var authoredBaseline = AuthoredRecord()
  @ObservationIgnored var draftRemovals: [UUID] = []
  @ObservationIgnored var journal = JournalRecord()
  @ObservationIgnored var cacheRevision: UInt64 = 0
  @ObservationIgnored var tombstones: [String: ThreadTombstone] = [:]
  @ObservationIgnored var authoritativeRows: [String: Date] = [:]
  @ObservationIgnored var observedOrder: [String] = []
  @ObservationIgnored var observations: [String: UInt64] = [:]
  @ObservationIgnored var observation: UInt64 = 0
  @ObservationIgnored var bootstrapClock: UInt64 = 0
  @ObservationIgnored var epoch: UInt64 = 0
  @ObservationIgnored var selection: UInt64 = 0
  @ObservationIgnored var visible = false
  @ObservationIgnored var backgrounded = false
  @ObservationIgnored var started = false
  @ObservationIgnored var detailRequests: [String: UUID] = [:]
  @ObservationIgnored var bootstrapRequest: UUID?
  @ObservationIgnored var bootstrapETag: String?
  @ObservationIgnored var streamTask: Task<Void, Never>?
  @ObservationIgnored var subscriptionTask: Task<Void, Never>?
  @ObservationIgnored var draftTask: Task<Void, Never>?
  @ObservationIgnored var publicationTask: Task<Void, Never>?
  @ObservationIgnored var cacheTask: Task<Void, Never>?
  @ObservationIgnored var reconciliationTask: Task<Void, Never>?
  @ObservationIgnored var needsBootstrap = false
  @ObservationIgnored var reconciliationDirty = false
  @ObservationIgnored var streamGeneration: UInt64 = 0
  @ObservationIgnored var subscriptionRevision: UInt64 = 0
  @ObservationIgnored var pendingDiscontinuity = false
  @ObservationIgnored var repairs: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var repairDirty: Set<String> = []
  @ObservationIgnored var repairWanted: [String: Int] = [:]
  @ObservationIgnored var recoveries: Set<String> = []
  @ObservationIgnored var submitting: Set<String> = []
  @ObservationIgnored var writeTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var writeTokens: [String: UUID] = [:]
  @ObservationIgnored var writeStates: [String: ThreadWriteState] = [:]
  @ObservationIgnored var writeLifetimes: [UUID: ThreadWriteState] = [:]
  @ObservationIgnored var attachmentClaims: [UUID: Set<String>] = [:]
  var protectedAttachmentIDs: Set<String> {
    attachmentClaims.values.reduce(into: []) { $0.formUnion($1) }
  }
  var inFlightAttachments: [String: WebAttachment] {
    Dictionary(
      stagedAttachments.filter { protectedAttachmentIDs.contains($0.id) }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
  }
  @ObservationIgnored var preparedHere: Set<String> = []
  @ObservationIgnored var runOverrides: [String: RunOverrideState] = [:]
  @ObservationIgnored var retryIdentities: [String: SubmissionReference] = [:]
  @ObservationIgnored var knownSubmissionReceipts: [String: WebSubmissionReceipt] = [:]
  @ObservationIgnored var receiptOrder: [String] = []
  @ObservationIgnored var completedSubmissions: Set<String> = []
  @ObservationIgnored var retirementOrder: [String] = []
  @ObservationIgnored var draftClearOrder: [String] = []
  @ObservationIgnored var missingReads: [String: TimeInterval] = [:]
  @ObservationIgnored var enabled = false
  @ObservationIgnored var stopping = false
  @ObservationIgnored var stopped = false
  @ObservationIgnored var lru: [String] = []

  public init(
    profile: SavedConsole, api: any ConsoleAPI, events: any ConsoleEventSource,
    repository: any ConsoleRepository, clock: any StreamClock = SystemStreamClock(),
    uploads: any UploadReservations = NoUploadReservations(),
    replyFiles: ReplyFileCache? = nil
  ) {
    self.profile = profile
    namespace = ConsoleNamespace(profile: profile)
    self.replyFiles = replyFiles ?? .live(namespace: profile.id.uuidString + namespace.identity)
    self.api = api
    capabilities = CapabilityService(endpoint: profile.endpoint, api: api)
    self.events = events
    self.repository = repository
    self.clock = clock
    self.uploads = uploads
  }
  deinit {
    streamTask?.cancel()
    subscriptionTask?.cancel()
    draftTask?.cancel()
    publicationTask?.cancel()
    cacheTask?.cancel()
    reconciliationTask?.cancel()
    for task in repairs.values { task.cancel() }
    for task in uploadTasks.values { task.cancel() }
  }
  public func start() async {
    guard !stopping, !enabled || !started else { return }
    stopped = false
    enabled = true
    started = true
    backgrounded = false
    await initialize()
  }
  func initialize() async {
    let generation = epoch
    await hydrate()
    guard epoch == generation, !backgrounded else { return }
    await refreshBootstrap()
    guard epoch == generation, !backgrounded else { return }
    await recoverSubmissions()
    await connectStream()
  }
  public func hydrate() async {
    guard !hydrated else { return }
    let generation = epoch
    do {
      let cache = try await repository.loadCache(namespace)
      guard epoch == generation else { return }
      cacheRevision = cache.revision
      tombstones = cache.tombstones
      bootstrap = try cache.bootstrap.map(CacheSanitizer.sanitize)
      if let bootstrap {
        tags = bootstrap.tags
        projects = bootstrap.projects
        activeFleet = bootstrap.activeThreads
      }
      for bucket in cache.buckets { buckets[bucket.key] = bucket }
      for entry in cache.conversations.sorted(by: { $0.savedAt < $1.savedAt }) {
        hold(try CacheSanitizer.conversation(entry), fromDevice: true)
      }
    } catch {
      storage = .memoryOnly
      errorMessage = "Offline cache is unavailable; using memory only."
    }
    do {
      let record = try await repository.loadAuthored(namespace)
      guard epoch == generation else { return }
      authored = record
      authoredBaseline = record
      authoredRevision &+= 1
      dataMode = record.dataMode
    } catch {
      authoredStorage = .memoryOnly
      errorMessage = "Drafts and read markers could not be restored."
    }
    do {
      let record = try await repository.loadJournal(namespace)
      guard epoch == generation else { return }
      journal = record
      journalRevision &+= 1
    } catch {
      journalStorage = .memoryOnly
      errorMessage = "Submission recovery is unavailable. Sending is disabled."
    }
    guard epoch == generation else { return }
    hydrated = true
    // Offline hydration permits authored edits, but never starts live effects (`started` is false).
    if !stopped { enabled = true }
    trimJournal()
    if !completedSubmissions.isEmpty { try? await persistJournal() }
  }
  public func select(sourceID: String, archived: Bool = false, threadID: String? = nil) async {
    pruneTombstones()
    selection &+= 1
    invalidateMcpApps()
    visible = false
    selectedBucket = BucketKey(sourceID: sourceID, archived: archived)
    selectedThreadID = threadID
    let generation = epoch
    let selected = selection
    draftTask?.cancel()
    await flushAuthored()
    await discardStagedUploads()
    guard epoch == generation, selection == selected else { return }
    // The disk cache has 24 entries but memory holds eight. Restore a cold selection
    // before attempting network I/O, including when the console is offline.
    if hydrated, let threadID, conversations[threadID] == nil, storage != .memoryOnly {
      do {
        let cache = try await repository.loadCache(namespace)
        guard epoch == generation, selection == selected else { return }
        if let entry = cache.conversations.first(where: { $0.thread.id == threadID }) {
          hold(try CacheSanitizer.conversation(entry), fromDevice: true)
        }
      } catch { errorMessage = "This conversation's offline cache could not be restored." }
    }
    guard epoch == generation, selection == selected, started, !backgrounded else { return }
    scheduleSubscription()
    if let threadID { await refreshDetail(threadID) }
    guard epoch == generation, selection == selected else { return }
    if let key = selectedBucket, buckets[key]?.freshness != .fresh { await refreshBucket(key) }
  }
  public func markVisible(_ isVisible: Bool) {
    visible = isVisible
    if isVisible, let thread = selectedConversation?.thread { noteRead(thread) }
  }
  public func isUnread(_ thread: WebThread) -> Bool {
    _ = authoredRevision
    guard let marker = authored.seen.first(where: { $0.id == thread.id }) else { return false }
    return thread.revision > marker.revision
  }
  public func draft(sourceID: String, threadID: String? = nil) -> ComposerDraft? {
    _ = authoredRevision
    let key = DraftKey(profileID: profile.id, sourceID: sourceID, threadID: threadID)
    return authored.drafts.first { $0.key == key }
  }
  public func setDraft(sourceID: String, threadID: String? = nil, text: String) async {
    let key = DraftKey(profileID: profile.id, sourceID: sourceID, threadID: threadID)
    let now = await clock.wallNow()
    for draft in authored.drafts
    where draft.key == key || now.timeIntervalSince(draft.updatedAt) > ConsoleBounds.maxAge {
      noteDraftRemoval(draft.version)
    }
    authored.drafts.removeAll {
      $0.key == key || now.timeIntervalSince($0.updatedAt) > ConsoleBounds.maxAge
    }
    if !text.isEmpty {
      authored.drafts.append(
        .init(key: key, text: String(text.prefix(32_768)), version: UUID(), updatedAt: now))
    }
    authored.drafts = Array(authored.drafts.suffix(40))
    authoredChanged()
  }
  public func setDataMode(_ mode: DataMode) {
    dataMode = mode
    authored.dataMode = mode
    authoredChanged()
    if effectiveDataMode == .full { publishAll() }
  }
  /// Reachability never declares the console healthy. It only nudges a waiting stream.
  public func networkChanged(reachable: Bool, constrained: Bool) async {
    isConstrained = constrained
    if effectiveDataMode == .full { publishAll() }
    if reachable && !backgrounded && connection == .waiting { await connectStream() }
  }
  func observe(_ id: String) {
    observation &+= 1
    observations[id] = observation
    observedOrder.removeAll { $0 == id }
    observedOrder.append(id)
    while observedOrder.count > 256 { observations[observedOrder.removeFirst()] = nil }
    conversations[id]?.freshness = .stale
  }
  func noteSummary(_ thread: WebThread) {
    confirmedSummaryIDs.insert(thread.id)
    let marked = authored.seen.first { $0.id == thread.id }?.revision
    let target = max(marked ?? thread.revision, thread.readRevision ?? 0)
    if marked != target { setSeen(thread.id, revision: target) }
    if visible && selectedThreadID == thread.id { noteRead(thread) }
  }
  func noteRead(_ thread: WebThread) {
    let marked = authored.seen.first { $0.id == thread.id }?.revision ?? -1
    if thread.revision > marked { setSeen(thread.id, revision: thread.revision) }
  }
  func setSeen(_ id: String, revision: Int) {
    authored.seen.removeAll { $0.id == id }
    authored.seen.append(.init(id: id, revision: revision))
    authored.seen = Array(authored.seen.suffix(200))
    authoredChanged()
  }
  func authoredChanged() {
    // Assigning the value is required because the I/O record itself is observation-ignored.
    authoredRevision &+= 1
    draftTask?.cancel()
    let generation = epoch
    draftTask = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: 0.5) } catch { return }
      guard let self, self.epoch == generation, !Task.isCancelled else { return }
      await self.flushAuthored()
    }
  }
  /// Observation dependency for drafts/unread stored in a private I/O record.
  var authoredRevision: UInt64 = 0
  var journalRevision: UInt64 = 0
  func hold(_ entry: CachedConversation, fromDevice: Bool = false) {
    guard !tombstones.keys.contains(entry.thread.id) else { return }
    let state = conversations[entry.thread.id] ?? ConversationState(entry)
    state.record = entry
    state.runningConfirmed = !fromDevice
    state.publish()
    conversations[entry.thread.id] = state
    touch(entry.thread.id)
  }
  func touch(_ id: String) {
    lru.removeAll { $0 == id }
    lru.append(id)
    while lru.count > ConsoleBounds.memoryConversations {
      let victim = lru.first { $0 != selectedThreadID } ?? lru[0]
      lru.removeAll { $0 == victim }
      conversations[victim] = nil
    }
  }
  func publishAll() {
    publicationTask?.cancel()
    publicationTask = nil
    for state in conversations.values { state.publish() }
  }
  func publish(_ state: ConversationState, terminal: Bool = false) {
    if effectiveDataMode == .full || terminal {
      state.publish()
      return
    }
    guard publicationTask == nil else { return }
    let generation = epoch
    publicationTask = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: 1) } catch { return }
      guard let self, self.epoch == generation, !Task.isCancelled else { return }
      self.publishAll()
    }
  }
  public func serverNow() async -> Date {
    await clock.wallNow().addingTimeInterval(serverClockOffset)
  }
  func noteDraftRemoval(_ version: UUID) {
    draftRemovals.removeAll { $0 == version }
    draftRemovals.append(version)
    draftRemovals = Array(draftRemovals.suffix(200))
  }
  public func flushAuthored() async {
    guard hydrated, authoredStorage != .memoryOnly else { return }
    guard enabled else {
      authoredStorage = .superseded
      return
    }
    var changed = authoredRevision
    let removals = Set(draftRemovals)
    authored.revision &+= 1
    var record = authored
    var savingRevision = record.revision
    do {
      var result = try await repository.saveAuthored(record, namespace: namespace)
      guard enabled, authoredRevision == changed, authored.revision == record.revision else {
        return
      }
      if case .superseded = result {
        let disk = try await repository.loadAuthored(namespace)
        guard enabled, authoredRevision == changed, authored.revision == record.revision else {
          return
        }
        record = AuthoredMerge.rebase(
          authored, onto: disk, baseline: authoredBaseline, removedVersions: removals)
        authored = record
        dataMode = record.dataMode
        authoredRevision &+= 1
        changed = authoredRevision
        savingRevision = record.revision
        result = try await repository.saveAuthored(record, namespace: namespace)
      }
      guard enabled, authoredRevision == changed, authored.revision == savingRevision else {
        return
      }
      switch result {
      case .saved:
        authoredStorage = .durable
        authoredBaseline = record
        draftRemovals.removeAll { removals.contains($0) }
      case .superseded: authoredStorage = .superseded
      }
    } catch {
      guard authored.revision == savingRevision else { return }
      authoredStorage = .writeFailed
      errorMessage = "Drafts and read markers are not saved durably."
    }
  }
  public func flushCache() async {
    guard hydrated, storage != .memoryOnly else { return }
    pruneTombstones()
    cacheRevision &+= 1
    var record = CacheRecord()
    record.revision = cacheRevision
    record.bootstrap = bootstrap
    record.bootstrap?.tags = tags
    record.bootstrap?.projects = projects
    record.bootstrap?.activeThreads = activeFleet
    record.buckets = Array(buckets.values)
    record.conversations = conversations.values.map(\.record)
    record.tombstones = tombstones
    do {
      var result = try await repository.saveCache(record, namespace: namespace)
      if case .superseded = result {
        let disk = try await repository.loadCache(namespace)
        guard cacheRevision == record.revision else { return }
        record = CacheMerge.rebase(record, onto: disk, authoritativeAt: authoritativeRows)
        cacheRevision = max(cacheRevision, record.revision)
        bootstrap = record.bootstrap
        result = try await repository.saveCache(record, namespace: namespace)
      }
      guard cacheRevision == record.revision else { return }
      switch result {
      case .saved: storage = .durable
      case .superseded: storage = .superseded
      }
    } catch {
      guard cacheRevision == record.revision else { return }
      storage = .writeFailed
      errorMessage = "Offline cache could not be saved."
    }
  }
  func scheduleCache() {
    guard cacheTask == nil else { return }
    let generation = epoch
    cacheTask = Task { [weak self, clock] in
      do { try await clock.sleep(seconds: 1) } catch { return }
      guard let self, self.epoch == generation, !Task.isCancelled else { return }
      self.cacheTask = nil
      await self.flushCache()
    }
  }
}
