// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum WebMessageDeltaOp: Codable, Sendable, Equatable {
  case append(index: Int, delta: String)
  case set(index: Int, part: WebMessagePart)
  case truncate(length: Int)
  private enum CodingKeys: String, CodingKey { case op, index, delta, part, length }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .op) {
    case "append":
      self = .append(
        index: try c.decode(Int.self, forKey: .index),
        delta: try c.decode(String.self, forKey: .delta))
    case "set":
      self = .set(
        index: try c.decode(Int.self, forKey: .index),
        part: try c.decode(WebMessagePart.self, forKey: .part))
    case "truncate": self = .truncate(length: try c.decode(Int.self, forKey: .length))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .op, in: c, debugDescription: "Unknown delta operation")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .append(let index, let delta):
      try c.encode("append", forKey: .op)
      try c.encode(index, forKey: .index)
      try c.encode(delta, forKey: .delta)
    case .set(let index, let part):
      try c.encode("set", forKey: .op)
      try c.encode(index, forKey: .index)
      try c.encode(part, forKey: .part)
    case .truncate(let length):
      try c.encode("truncate", forKey: .op)
      try c.encode(length, forKey: .length)
    }
  }
}
public struct WebMessageDelta: Codable, Sendable, Equatable {
  public var messageId: String
  public var baseSeq: Int
  public var seq: Int
  public var status: String
  public var updatedAt: String
  public var finishedAt: String?
  public var attribution: WebRunAttribution?
  public var ops: [WebMessageDeltaOp]
  public init(
    messageId: String, baseSeq: Int, seq: Int, status: String, updatedAt: String,
    finishedAt: String? = nil, attribution: WebRunAttribution? = nil, ops: [WebMessageDeltaOp]
  ) {
    self.messageId = messageId
    self.baseSeq = baseSeq
    self.seq = seq
    self.status = status
    self.updatedAt = updatedAt
    self.finishedAt = finishedAt
    self.attribution = attribution
    self.ops = ops
  }
}
public enum DeltaOutcome: Sendable, Equatable { case applied, stale, gap, unknown, unheld }
public struct DeltaResult: Sendable, Equatable {
  public var outcome: DeltaOutcome
  /// Present only for applied. The caller never installs a partially replayed snapshot.
  public var message: WebMessage? = nil
}
public enum DeltaReducer {
  public enum InvalidOperation: Error { case invalid }
  public static func apply(
    _ delta: WebMessageDelta, to message: WebMessage?, threadHeld: Bool,
    repairedToolCallIds: Set<String> = []
  ) -> DeltaResult {
    guard threadHeld else { return .init(outcome: .unheld) }
    guard var message, message.id == delta.messageId else { return .init(outcome: .unknown) }
    guard isReadable(delta) else { return .init(outcome: .gap) }
    if let seq = message.seq, seq >= delta.seq { return .init(outcome: .stale) }
    guard message.seq == delta.baseSeq else { return .init(outcome: .gap) }
    do {
      message.parts = try apply(
        ops: delta.ops, to: message.parts, repairedToolCallIds: repairedToolCallIds)
      message.seq = delta.seq
      message.status = delta.status
      message.updatedAt = delta.updatedAt
      if let finishedAt = delta.finishedAt { message.finishedAt = finishedAt }
      if let attribution = delta.attribution { message.attribution = attribution }
      return .init(outcome: .applied, message: message)
    } catch { return .init(outcome: .gap) }
  }
  static func validAttribution(_ value: WebRunAttribution) -> Bool {
    ["requested", "fallback", "unknown"].contains(value.disposition)
      && value.transitions.count <= 32 && value.retries.count <= 32
      && value.transitions.allSatisfy {
        $0.attemptIndex.map { (0...9_007_199_254_740_991).contains($0) } ?? true
      }
      && value.retries.allSatisfy {
        ($0.retryIndex.map { (0...9_007_199_254_740_991).contains($0) } ?? true)
          && ($0.attempts.map { (0...9_007_199_254_740_991).contains($0) } ?? true)
      }
      && value.truncated != false
  }
  /// Shape validation precedes stale detection; unreadable frames must request repair.
  static func isReadable(_ delta: WebMessageDelta) -> Bool {
    ["running", "complete", "failed", "cancelled", "interrupted"].contains(delta.status)
      && (delta.attribution.map(validAttribution) ?? true)
      && delta.ops.allSatisfy {
        if case .set(_, let part) = $0 { return valid(part) }
        return true
      }
  }
  private static func valid(_ part: WebMessagePart) -> Bool {
    switch part {
    case .unknown: return false
    case .toolCall(let v):
      return v.toolName != nil && ["running", "complete", "failed"].contains(v.status)
    case .subagent(let v):
      return v.name != nil && v.calls != nil
        && ["running", "complete", "failed"].contains(v.status)
        && (v.attribution.map(validAttribution) ?? true)
    case .replyOptions(let v):
      return (2...8).contains(v.options.count) && Set(v.options).count == v.options.count
        && v.options.allSatisfy {
          !$0.isEmpty && $0.utf16.count <= 75
            && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            && !$0.unicodeScalars.contains {
              $0.properties.generalCategory == .control || $0.value == 0x2028
                || $0.value == 0x2029
            }
        }
    case .restartProposal(let v): return !v.id.isEmpty && v.restartable != nil
    case .conversationMarker(let v):
      switch v.kind {
      case "model", "project": return v.before != nil && v.after != nil
      case "resumed": return v.previousMessageAt != nil && v.idleMs != nil
      case "compaction": return v.operationId != nil && v.trigger != nil && v.status != nil
      default: return false
      }
    default: return true
    }
  }
  public static func apply(
    ops: [WebMessageDeltaOp], to parts: [WebMessagePart], repairedToolCallIds: Set<String> = []
  ) throws -> [WebMessagePart] {
    var next = parts
    for op in ops {
      switch op {
      case .truncate(let length):
        guard (0...next.count).contains(length) else { throw InvalidOperation.invalid }
        next = Array(next.prefix(length))
      case .set(let index, let part):
        guard (0...next.count).contains(index) else { throw InvalidOperation.invalid }
        guard valid(part) else { throw InvalidOperation.invalid }
        if index == next.count { next.append(part) } else { next[index] = part }
      case .append(let index, let text):
        guard next.indices.contains(index) else { throw InvalidOperation.invalid }
        switch next[index] {
        case .text(let p): next[index] = .text(.init(type: "text", text: p.text + text))
        case .reasoning(let p):
          next[index] = .reasoning(.init(type: "reasoning", text: p.text + text))
        default: throw InvalidOperation.invalid
        }
      }
    }
    guard !repairedToolCallIds.isEmpty else { return next }
    var held: [String: WebToolCall] = [:]
    for part in parts {
      switch part {
      case .toolCall(let v), .subagent(let v):
        held[v.toolCallId] = v
        for call in v.calls ?? [] { held[call.toolCallId] = call }
      default: break
      }
    }
    func restore(_ incoming: WebToolCall) -> WebToolCall {
      guard repairedToolCallIds.contains(incoming.toolCallId), let old = held[incoming.toolCallId]
      else { return incoming }
      var v = incoming
      if v.resultTruncated == true, old.resultTruncated != true, old.result != nil,
        let digest = old.resultDigest, digest == v.resultDigest
      {
        v.result = old.result
        v.resultTruncated = nil
        v.resultBytes = nil
      }
      if v.argsTruncated == true, old.argsTruncated != true, old.args != nil,
        let digest = old.argsDigest, digest == v.argsDigest
      {
        v.args = old.args
        v.argsTruncated = nil
        v.argsBytes = nil
      }
      return v
    }
    return next.map { part in
      switch part {
      case .toolCall(let v): return .toolCall(restore(v))
      case .subagent(let v):
        var v = restore(v)
        v.calls = v.calls?.map(restore)
        return .subagent(v)
      default: return part
      }
    }
  }
}
