// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

struct TranscriptPresentationTests {
  @Test func adjacentSameToolClustersAndChronologySurvives() throws {
    let a = WebMessagePart.toolCall(try TranscriptFixture.tool(1))
    let b = WebMessagePart.toolCall(try TranscriptFixture.tool(2))
    let text = WebMessagePart.text(.init(text: "Between calls"))
    let rows = TranscriptPresentation.clusters([a, b, text, a])
    #expect(rows.map(\.id) == [0, 2, 3])
    #expect(rows.map { $0.parts.count } == [2, 1, 1])
    var ask = try TranscriptFixture.tool(1)
    ask.toolName = "AskUser"
    #expect(TranscriptPresentation.clusters([.toolCall(ask), .toolCall(ask)]).count == 2)
    #expect(TranscriptPresentation.failed(try TranscriptFixture.tool(2)))
  }
  @Test func previewsDoNotConfusePathsCommandsOrDates() throws {
    var call = try TranscriptFixture.tool(1)
    call.args = .object(["file_path": .string("docs/sample.md")])
    #expect(TranscriptPresentation.preview(call) == "docs/sample.md")
    #expect(TranscriptPresentation.clusterSummary([call, call]) == "sample.md")
    call.toolName = "Bash"
    call.args = .object(["command": .string("cd '/tmp/sample dir' && git status")])
    #expect(TranscriptPresentation.preview(call) == "git status")
    #expect(!TranscriptPresentation.pathLike("2030/01/02"))
    #expect(!TranscriptPresentation.pathLike("git clone https://example.com/repo"))
    #expect(TranscriptPresentation.verb("memory_search") == "Memory search")
    call.args = .string(String(repeating: "x", count: 200))
    #expect(TranscriptPresentation.preview(call).count == 72)
  }
  @Test func durationsAndCostsNeverInventZero() {
    #expect(TranscriptPresentation.duration(nil) == nil)
    #expect(TranscriptPresentation.duration(.nan) == nil)
    #expect(TranscriptPresentation.duration(-1) == nil)
    #expect(TranscriptPresentation.duration(42) == "42ms")
    #expect(TranscriptPresentation.duration(1240) == "1.2s")
    #expect(TranscriptPresentation.cost(.unknown(knownSpend: nil)) == "Cost unknown")
    #expect(TranscriptPresentation.cost(.known(0)) == "$0.0000")
    #expect(TranscriptPresentation.cost(.unknown(knownSpend: 0.25)).contains("unknown"))
  }
  @Test func markersKeepServerOrderEvenWithReversedTimestamps() throws {
    let a: WebConversationMarkerPart = try TranscriptFixture.decode(
      #"{"type":"conversation-marker","at":"2030-01-02T12:00:00Z","kind":"compaction","status":"skipped","trigger":"manual","reason":"nothing_to_compact"}"#
    )
    var b = a
    b.kind = "resumed"
    b.at = "2030-01-01T12:00:00Z"
    let labels = TranscriptPresentation.markerLabels([
      .conversationMarker(a), .text(.init(text: "hello")), .conversationMarker(b),
    ])
    #expect(labels[0].contains("skipped"))
    #expect(labels[1].contains("Resumed"))
    b.kind = "compaction"
    b.status = "succeeded"
    b.tokensBefore = 1e100
    b.tokensAfter = 1e90
    #expect(!TranscriptPresentation.marker(b).isEmpty)
  }
  @Test func manualCompactionUsesNestedEvidenceAndFencesOlderOrAutomaticResults() throws {
    var message = try TranscriptFixture.message(
      id: "compaction-result", role: "assistant", text: "")
    var telemetry: TelemetryPart = try TranscriptFixture.decode(
      #"{"type":"telemetry","event":"runtime","data":{"kind":"context_compaction","data":{"status":"succeeded","trigger":"manual","timestamp":1893585600000,"tokensBefore":12000,"tokensAfter":2000}}}"#
    )
    #expect(
      TranscriptPresentation.compaction(telemetry, running: false)?.contains("12000 → ≈2000")
        == true)
    message.parts = [.telemetry(telemetry)]
    #expect(
      TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T11:59:00.000Z"))
    #expect(
      !TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T12:01:00Z"))
    telemetry.data = .object([
      "kind": .string("context_compaction"),
      "data": .object([
        "status": .string("running"), "trigger": .string("automatic"),
        "timestamp": .number(1_893_585_600_000),
      ]),
    ])
    message.parts = [.telemetry(telemetry)]
    #expect(
      !TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T11:59:00Z"))
    #expect(
      TranscriptPresentation.compaction(telemetry, running: false)?.contains("interrupted") == true)
  }
  @Test func requestedOnlyDoesNotClaimExecutionAndFallbackStaysFlagged() throws {
    var value: WebRunAttribution = try TranscriptFixture.decode(
      #"{"requested":{"model":"sample:small","effort":"none"},"executed":{},"disposition":"requested","transitions":[],"retries":[]}"#
    )
    #expect(
      TranscriptPresentation.attribution(value, status: "complete").contains("not a confirmed run"))
    value.disposition = "fallback"
    #expect(TranscriptPresentation.attribution(value, status: "running").hasPrefix("Fallback:"))
  }
  @Test func scrollFollowRequiresUserProximityAndPagingNeverFollows() {
    var policy = TranscriptFollowPolicy()
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 0), userDriven: false)
    #expect(policy.shouldFollowWrite)
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 0), userDriven: true)
    #expect(!policy.shouldFollowWrite)
    policy.jump()
    policy.paging = true
    #expect(!policy.shouldFollowWrite)
    policy.paging = false
    #expect(policy.shouldFollowWrite)
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 960), userDriven: true)
    #expect(policy.following)
  }
  @Test func unreadablePartsAndFixtureDeltasDecodeWithoutWholeMessageFailure() throws {
    let part: WebMessagePart = try TranscriptFixture.decode(#"{"type":"text","text":42}"#)
    #expect(part.decodingDiagnostic == .unreadableKnownKind("text"))
    for index in 1...8 {
      let event = try TranscriptFixture.delta(index)
      #expect(event.event.name == "message.delta")
    }
  }
  @Test func longFixtureHasFiveHundredRowsAndSeparateOlderPage() throws {
    #expect(try TranscriptFixture.messages(.conversationLong).count == 500)
    #expect(try TranscriptFixture.messages(.conversationLong, older: true).count == 40)
  }
}
