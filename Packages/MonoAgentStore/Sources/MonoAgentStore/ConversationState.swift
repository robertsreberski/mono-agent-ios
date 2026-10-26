// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public struct ConversationTurn: Identifiable, Sendable {
  public var id: String
  public var messageIDs: [String]
  public var runState: WebRunState?
}

/// The UI observes one conversation, not the entire fleet on every token.
@MainActor @Observable
public final class ConversationState {
  public internal(set) var thread: WebThread {
    didSet { if oldValue != thread { onThreadChange?() } }
  }
  @ObservationIgnored var onThreadChange: (() -> Void)?
  /// Compatibility snapshot, assembled only on demand. Never shares the mutable cache buffer.
  public var messages: [WebMessage] { orderedMessageIDs.compactMap { messageStates[$0]?.message } }
  public private(set) var jobItems: [JobShelfItem] = []
  public private(set) var jobParentMessages: [WebMessage] = []
  public private(set) var context = ContextProjection()
  public private(set) var latestReportedAttribution: WebRunAttribution?
  @ObservationIgnored private(set) var messageIndices: [String: Int] = [:]
  @ObservationIgnored var pendingMessageIndices: Set<Int> = []
  @ObservationIgnored var needsFullPublication = false
  @ObservationIgnored private var jobProjection = ProcessJobEvents.Projection()
  @ObservationIgnored private(set) var jobProjectionRevision = 0
  @ObservationIgnored private var shelfOwnedCalls: Set<String> = []
  @ObservationIgnored private var inputs: [String: PresentationInput] = [:]
  private struct PresentationInput: Equatable {
    var status: String
    var role: String
    var jobParts: [WebMessagePart]
    var parentCallsWithChildren: Set<String>
    var eventInput: ProcessJobEvents.Input
    var contextParts: [WebMessagePart]
    var attribution: WebRunAttribution?
    init(_ message: WebMessage) {
      status = message.status
      role = message.role
      eventInput = ProcessJobEvents.Input(message)
      var withChildren = Set<String>()
      jobParts = message.parts.compactMap { part in
        switch part {
        case .processJob, .processJobWake, .steer: return part
        case .toolCall(var call), .subagent(var call):
          let tool = call.toolName ?? call.name ?? ""
          guard ProcessJobEvents.toolNames.contains(tool) || tool.hasSuffix("__PeerAgent")
          else { return nil }
          if call.calls?.isEmpty == false { withChildren.insert(call.toolCallId) }
          // Shelf parent rows do not read child payloads, usage, pricing or route. Keep those
          // live on their own observed transcript row, without re-projecting the conversation.
          call.calls = nil
          call.executionMs = nil
          call.costUsd = nil
          call.knownCostUsd = nil
          call.costUnknown = nil
          call.usage = nil
          call.attribution = nil
          if case .subagent = part { return .subagent(call) }
          return .toolCall(call)
        default: return nil
        }
      }
      parentCallsWithChildren = withChildren
      contextParts = message.parts.filter { if case .telemetry = $0 { true } else { false } }
      attribution = message.attribution
    }
  }
  public internal(set) var freshness: Freshness = .stale
  public internal(set) var runningConfirmed = false
  public internal(set) var nextCursor: String?
  public internal(set) var truncated: Bool
  /// Stable row identity; a token write invalidates only its own observed row.
  public private(set) var orderedMessageIDs: [String] = []
  public private(set) var transcriptMessageIDs: [String] = []
  public private(set) var messageStates: [String: TranscriptMessageState] = [:]
  public var turns: [ConversationTurn] {
    var order: [String] = []
    var groups: [String: [String]] = [:]
    for message in messages {
      guard let id = message.turnId else { continue }
      if groups[id] == nil { order.append(id) }
      groups[id, default: []].append(message.id)
    }
    return order.map { id in
      ConversationTurn(
        id: id, messageIDs: groups[id] ?? [],
        runState: thread.runState.id == id ? thread.runState : nil)
    }
  }
  /// Ephemeral server aggregate; never fabricate a total from a partial transcript.
  public internal(set) var usage: WebThreadUsage?
  public internal(set) var usageRevision: Int?
  @ObservationIgnored var usageRequest: UUID?
  @ObservationIgnored var record: CachedConversation
  @ObservationIgnored var etag: String?
  init(_ record: CachedConversation) {
    self.record = record
    thread = record.thread
    nextCursor = record.nextCursor
    truncated = record.truncated
    publishRows()
    publishDerived(jobs: true, context: true, route: true)
  }
  private func publishRows() {
    let ids = record.messages.map(\.id)
    if orderedMessageIDs != ids {
      orderedMessageIDs = ids
      let retained = Set(ids)
      messageStates = messageStates.filter { retained.contains($0.key) }
    }
    inputs = [:]
    messageIndices = Dictionary(
      record.messages.enumerated().map { ($0.element.id, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    for message in record.messages {
      inputs[message.id] = PresentationInput(message)
      if let row = messageStates[message.id] {
        if row.message != message { row.message = message }
        if row.turnID != message.turnId { row.turnID = message.turnId }
      } else {
        messageStates[message.id] = TranscriptMessageState(message)
      }
    }
  }
  func messageIndex(_ id: String) -> Int? {
    if let index = messageIndices[id], record.messages.indices.contains(index),
      record.messages[index].id == id
    {
      return index
    }
    return record.messages.firstIndex { $0.id == id }
  }
  func publish() {
    if thread != record.thread { thread = record.thread }
    if nextCursor != record.nextCursor { nextCursor = record.nextCursor }
    if truncated != record.truncated { truncated = record.truncated }
    publishRows()
    publishDerived(jobs: true, context: true, route: true)
    pendingMessageIndices.removeAll()
    needsFullPublication = false
  }
  func publishPending() {
    if needsFullPublication {
      publish()
      return
    }
    var jobsChanged = false
    var eventsChanged = false
    var contextChanged = thread != record.thread
    var routeChanged = false
    var visibilityChanged = false
    var previousVisibility: [String: Bool] = [:]
    if thread != record.thread { thread = record.thread }
    for index in pendingMessageIndices where record.messages.indices.contains(index) {
      let message = record.messages[index]
      guard let row = messageStates[message.id] else {
        publish()
        return
      }
      previousVisibility[message.id] = ProcessJobEvents.visible(
        row.message, entries: row.transcriptEntries)
      let next = PresentationInput(message)
      let previous = inputs[message.id]
      visibilityChanged =
        visibilityChanged || previous?.status != next.status
        || previous?.attribution != next.attribution
      eventsChanged = eventsChanged || previous?.eventInput != next.eventInput
      jobsChanged =
        jobsChanged || eventsChanged || previous?.jobParts != next.jobParts
        || previous?.parentCallsWithChildren != next.parentCallsWithChildren
        || previous?.role != next.role
      contextChanged =
        contextChanged || previous?.contextParts != next.contextParts
        || previous?.status != next.status || previous?.role != next.role
      routeChanged = routeChanged || previous?.attribution != next.attribution
      inputs[message.id] = next
      if row.message != message { row.message = message }
      if row.turnID != message.turnId { row.turnID = message.turnId }
    }
    if !jobsChanged {
      for index in pendingMessageIndices where record.messages.indices.contains(index) {
        let message = record.messages[index]
        publishEntries(message)
        let nowVisible = ProcessJobEvents.visible(
          message, entries: messageStates[message.id]?.transcriptEntries ?? [])
        visibilityChanged = visibilityChanged || previousVisibility[message.id] != nowVisible
      }
      if visibilityChanged { publishTranscriptIDs() }
    }
    let changedMessages = pendingMessageIndices.compactMap { index in
      record.messages.indices.contains(index) ? record.messages[index] : nil
    }
    pendingMessageIndices.removeAll()
    publishDerived(
      jobs: jobsChanged, context: contextChanged, route: routeChanged,
      events: eventsChanged, changedMessages: changedMessages)
  }
  private func publishEntries(_ message: WebMessage) {
    guard let row = messageStates[message.id] else { return }
    let entries = ProcessJobEvents.entries(
      for: message, projection: jobProjection, shelfOwnedCalls: shelfOwnedCalls)
    if row.transcriptEntries != entries { row.transcriptEntries = entries }
  }
  private func publishTranscriptIDs() {
    let visible = ProcessJobEvents.orderedMessages(record.messages).filter { message in
      ProcessJobEvents.visible(message, entries: messageStates[message.id]?.transcriptEntries ?? [])
    }.map(\.id)
    if transcriptMessageIDs != visible { transcriptMessageIDs = visible }
  }
  private func publishDerived(
    jobs: Bool, context contextChanged: Bool, route: Bool,
    events: Bool = true, changedMessages: [WebMessage] = []
  ) {
    if jobs {
      let items = JobShelf.items(messages: record.messages)
      if jobItems != items { jobItems = items }
      let parents = record.messages.compactMap { message -> WebMessage? in
        let parts = message.parts.filter {
          switch $0 {
          case .toolCall, .subagent: true
          default: false
          }
        }
        guard !parts.isEmpty else { return nil }
        var value = message
        value.parts = parts
        // JobTimeline reads only identity, role, createdAt and parent calls.
        value.updatedAt = value.createdAt
        value.seq = nil
        value.status = ""
        value.attribution = nil
        return value
      }
      if jobParentMessages != parents { jobParentMessages = parents }
      if events {
        jobProjection = ProcessJobEvents.project(messages: record.messages, threadID: thread.id)
        jobProjectionRevision += 1
      }
      let owned = ProcessJobEvents.shelfOwnedCalls(messages: parents, items: items)
      let allEntriesChanged = events || owned != shelfOwnedCalls
      shelfOwnedCalls = owned
      for message in allEntriesChanged ? record.messages : changedMessages {
        publishEntries(message)
      }
      publishTranscriptIDs()
    }
    if contextChanged {
      let projection = UsagePresentation.context(messages: record.messages, thread: record.thread)
      if context != projection { context = projection }
    }
    if route {
      let latest = record.messages.reversed().compactMap(\.attribution).first {
        [$0.executed?.model, $0.attempted?.model].contains { $0?.isEmpty == false }
      }
      if latestReportedAttribution != latest { latestReportedAttribution = latest }
    }
  }
}

/// Observed separately from the conversation's ordered identity list.
@MainActor @Observable
public final class TranscriptMessageState: Identifiable {
  public nonisolated let id: String
  public internal(set) var message: WebMessage
  public internal(set) var turnID: String?
  public internal(set) var transcriptEntries: [TranscriptEntry] = []
  init(_ message: WebMessage) {
    self.id = message.id
    self.message = message
    self.turnID = message.turnId
  }
}

public enum TranscriptMerge {
  /// Server sequence is authoritative. Digest-valid repaired bodies survive default previews.
  public static func message(_ incoming: WebMessage, held: WebMessage?, repaired: Set<String>)
    -> WebMessage
  {
    guard let held else { return incoming }
    if let old = held.seq {
      guard let seq = incoming.seq, seq >= old else { return held }
      if seq == old && incoming.updatedAt < held.updatedAt { return held }
    }
    var result = incoming
    // Reuse Kit's digest-aware tool restoration for every full read, not only deltas.
    result.parts = incoming.parts.map { part in
      // Restore by tool identity across the whole old message, not by array position.
      // Unknown/malformed parts remain the incoming opaque value, never an old slot.
      (try? DeltaReducer.apply(
        ops: [.set(index: 0, part: part), .truncate(length: 1)],
        to: held.parts, repairedToolCallIds: repaired
      ).first) ?? part
    }
    return result
  }
  /// The authoritative window retains its exact order. Only history outside that window survives.
  public static func window(
    _ incoming: [WebMessage], held: [WebMessage], paged: Set<String>,
    repaired: Set<String>, complete: Bool
  ) -> [WebMessage] {
    let existing = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ids = Set(incoming.map(\.id))
    let oldest = incoming.map(\.createdAt).min()
    let outside = held.filter { row in
      !ids.contains(row.id)
        && (paged.contains(row.id) || (!complete && oldest.map { row.createdAt < $0 } == true))
    }
    if !held.contains(where: { ids.contains($0.id) }) {
      return outside + incoming.map { message($0, held: existing[$0.id], repaired: repaired) }
    }
    let retained = Set(outside.map(\.id))
    let positions = Dictionary(
      incoming.enumerated().map { ($0.element.id, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    var before: [Int: [WebMessage]] = [:]
    var bank: [WebMessage] = []
    for row in held {
      if let position = positions[row.id] {
        before[position, default: []] += bank
        bank.removeAll()
      } else if retained.contains(row.id) {
        bank.append(row)
      }
    }
    var merged: [WebMessage] = []
    for (index, row) in incoming.enumerated() {
      merged += before[index] ?? []
      merged.append(message(row, held: existing[row.id], repaired: repaired))
    }
    return merged + bank
  }
  public static func insert(
    _ incoming: WebMessage, into messages: inout [WebMessage], repaired: Set<String>
  ) {
    if let index = messages.firstIndex(where: { $0.id == incoming.id }) {
      messages[index] = message(incoming, held: messages[index], repaired: repaired)
    } else {
      let index =
        messages.lastIndex(where: { $0.createdAt <= incoming.createdAt }).map { $0 + 1 } ?? 0
      messages.insert(incoming, at: index)
    }
  }
}
