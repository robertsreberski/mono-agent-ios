// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentKit

@Test func sharedDeltaVectors() throws {
  let vectors = try JSONDecoder().decode(
    [DeltaVector].self, from: resource("message-delta-vectors.v1"))
  #expect(vectors.count == 11)
  for vector in vectors {
    #expect(
      try DeltaReducer.apply(ops: vector.ops, to: vector.prev) == vector.next, "\(vector.name)")
  }
}
func heldMessage() throws -> WebMessage {
  try #require(
    JSONDecoder().decode(ApiThreadDetail.self, from: fixture("thread-detail")).messages.first)
}
@Test func deltaOutcomesMetadataAndNonConsecutiveSequence() throws {
  var message = try heldMessage()
  message.seq = 4
  let delta = WebMessageDelta(
    messageId: message.id, baseSeq: 4, seq: 12, status: "complete", updatedAt: "later",
    finishedAt: "finished", ops: [.append(index: 0, delta: " tail")])
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: false).outcome == .unheld)
  #expect(DeltaReducer.apply(delta, to: nil, threadHeld: true).outcome == .unknown)
  let applied = DeltaReducer.apply(delta, to: message, threadHeld: true)
  #expect(applied.outcome == .applied)
  let next = try #require(applied.message)
  #expect(next.seq == 12 && next.finishedAt == "finished" && next.status == "complete")
  #expect(DeltaReducer.apply(delta, to: next, threadHeld: true).outcome == .stale)
  message.seq = 3
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: true).outcome == .gap)
  message.seq = nil
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: true).outcome == .gap)
  var noMetadata = delta
  noMetadata.baseSeq = 12
  noMetadata.seq = 13
  noMetadata.finishedAt = nil
  #expect(
    DeltaReducer.apply(noMetadata, to: next, threadHeld: true).message?.finishedAt == "finished")
}
@Test func invalidDeltaNeverPartiallyMutatesAndUnknownPartRequiresRepair() throws {
  let message = try heldMessage()
  let before = message.parts
  let invalid: [[WebMessageDeltaOp]] = [
    [.append(index: 0, delta: "mutated"), .truncate(length: -1)],
    [.append(index: 999, delta: "invalid")], [.set(index: -1, part: .text(.init(text: "x")))],
    [.set(index: 0, part: .unknown(.object(["type": .string("future")])))],
  ]
  for ops in invalid {
    let delta = WebMessageDelta(
      messageId: message.id, baseSeq: message.seq!, seq: message.seq! + 1, status: "running",
      updatedAt: "later", ops: ops)
    let result = DeltaReducer.apply(delta, to: message, threadHeld: true)
    #expect(result.outcome == .gap && result.message == nil)
    #expect(message.parts == before)
  }
}
@Test func repairedToolBodiesSurviveMatchingPreviewDigestsOnlyIncludingChildren() throws {
  let old = try JSONDecoder().decode(
    WebMessagePart.self,
    from: Data(
      #"{"type":"subagent","toolCallId":"parent","name":"fictional","status":"complete","result":"full parent","resultDigest":"same","calls":[{"toolCallId":"child","toolName":"Read","status":"complete","args":{"full":true},"argsDigest":"args"}]}"#
        .utf8))
  let preview = try JSONDecoder().decode(
    WebMessagePart.self,
    from: Data(
      #"{"type":"subagent","toolCallId":"parent","name":"fictional","status":"complete","result":"preview","resultTruncated":true,"resultBytes":99,"resultDigest":"same","calls":[{"toolCallId":"child","toolName":"Read","status":"complete","args":"preview","argsTruncated":true,"argsDigest":"args"}]}"#
        .utf8))
  let ops: [WebMessageDeltaOp] = [.set(index: 0, part: preview)]
  let restored = try DeltaReducer.apply(
    ops: ops, to: [old], repairedToolCallIds: ["parent", "child"])
  #expect(restored == [old])
  #expect(try DeltaReducer.apply(ops: ops, to: [old]) == [preview])
  guard case .subagent(var changed) = preview else { return }
  changed.resultDigest = "different"
  guard
    case .subagent(let failedClosed) = try DeltaReducer.apply(
      ops: [.set(index: 0, part: .subagent(changed))], to: [old], repairedToolCallIds: ["parent"])[
        0]
  else { return }
  #expect(failedClosed.result == .string("preview"))
}

@Test func replyOptionValidationMatchesUTF16AndCcNotCf() throws {
  func part(_ label: String) -> WebMessagePart {
    .replyOptions(
      .init(type: "reply_options", id: "fictional", options: [label, "Another option"]))
  }
  for label in ["Family 👩‍👩‍👧‍👦", "soft\u{00ad}hyphen", String(repeating: "🦉", count: 37) + "a"] {
    #expect(try DeltaReducer.apply(ops: [.set(index: 0, part: part(label))], to: []).count == 1)
  }
  for label in [
    "bad\u{0000}label", "bad\u{007f}label", "bad\u{0085}label", String(repeating: "🦉", count: 38),
  ] {
    #expect(throws: DeltaReducer.InvalidOperation.self) {
      try DeltaReducer.apply(ops: [.set(index: 0, part: part(label))], to: [])
    }
  }
}
@Test func unreadableStatusAndAttributionRequireRepairEvenWhenSequenceIsStale() throws {
  var message = try heldMessage()
  message.seq = 9
  var delta = WebMessageDelta(
    messageId: message.id, baseSeq: 1, seq: 2, status: "future", updatedAt: "later", ops: [])
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: true).outcome == .gap)
  delta.status = "complete"
  var attribution = try JSONDecoder().decode(
    WebRunAttribution.self,
    from: Data(#"{"requested":{},"disposition":"future","transitions":[],"retries":[]}"#.utf8))
  delta.attribution = attribution
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: true).outcome == .gap)
  attribution.disposition = "requested"
  delta.attribution = attribution
  #expect(DeltaReducer.apply(delta, to: message, threadHeld: true).outcome == .stale)
  let subagent = try JSONDecoder().decode(
    WebMessagePart.self,
    from: Data(
      #"{"type":"subagent","toolCallId":"fictional","name":"Example","status":"complete","calls":[],"attribution":{"requested":{},"disposition":"future","transitions":[],"retries":[]}}"#
        .utf8))
  #expect(throws: DeltaReducer.InvalidOperation.self) {
    try DeltaReducer.apply(ops: [.set(index: 0, part: subagent)], to: [])
  }
  guard case .subagent(var excessive) = subagent else { return }
  attribution.transitions = Array(
    repeating: .init(from: "a", to: "b", attemptIndex: nil, reason: nil), count: 33)
  excessive.attribution = attribution
  #expect(throws: DeltaReducer.InvalidOperation.self) {
    try DeltaReducer.apply(ops: [.set(index: 0, part: .subagent(excessive))], to: [])
  }
}
