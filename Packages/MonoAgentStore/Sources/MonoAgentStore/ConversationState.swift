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
  public internal(set) var thread: WebThread
  public internal(set) var messages: [WebMessage]
  public internal(set) var freshness: Freshness = .stale
  public internal(set) var runningConfirmed = false
  public internal(set) var nextCursor: String?
  public internal(set) var truncated: Bool
  public var turns: [ConversationTurn] {
    var seen: Set<String> = []
    return messages.compactMap(\.turnId).filter { seen.insert($0).inserted }.map { id in
      ConversationTurn(
        id: id, messageIDs: messages.filter { $0.turnId == id }.map(\.id),
        runState: thread.runState.id == id ? thread.runState : nil)
    }
  }
  @ObservationIgnored var record: CachedConversation
  @ObservationIgnored var etag: String?
  init(_ record: CachedConversation) {
    self.record = record
    thread = record.thread
    messages = record.messages
    nextCursor = record.nextCursor
    truncated = record.truncated
  }
  func publish() {
    thread = record.thread
    messages = record.messages
    nextCursor = record.nextCursor
    truncated = record.truncated
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
