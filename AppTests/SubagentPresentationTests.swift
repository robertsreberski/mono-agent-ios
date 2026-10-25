// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

struct SubagentPresentationTests {
  @Test func delegationMetaOmitsRepeatedStateAndUnknownCost() throws {
    var call = try TranscriptFixture.tool(1, full: true)
    call.calls = [try TranscriptFixture.tool(1), try TranscriptFixture.tool(2)]
    call.executionMs = 1200
    call.costUnknown = true
    call.costUsd = nil
    call.knownCostUsd = nil
    call.status = "running"
    #expect(SubagentPresentation.meta(call) == "2 tools · 1.2s")
    call.status = "failed"
    #expect(SubagentPresentation.meta(call) == "2 tools · 1.2s")
    call.costUsd = 0.12
    #expect(SubagentPresentation.meta(call).contains("$0.12"))
  }
  @Test func routeRequiresEvidenceAndUsesTheDelegationsOwnEffectiveRoute() throws {
    var call = try TranscriptFixture.tool(1)
    #expect(SubagentPresentation.route(call) == nil)
    call.attribution = try TranscriptFixture.decode(
      #"{"requested":{"model":"sample:small","effort":"high"},"executed":{"model":"sample:large","effort":"high","effectiveEffort":"low"},"disposition":"fallback","transitions":[],"retries":[]}"#
    )
    #expect(SubagentPresentation.route(call)?.model == "sample:large")
    #expect(SubagentPresentation.route(call)?.effort == "low")
  }
  @Test func reportStripsOnlyTheLeadingHostWrapper() throws {
    var call = try TranscriptFixture.tool(1)
    call.result = .string(
      "<subagent: researcher · instance sample-helper · turn 1>\nA fictional report.")
    #expect(SubagentPresentation.report(call) == "A fictional report.")
    call.result = .string("Quoted below:\n<subagent: researcher>\nA fictional report.")
    #expect(SubagentPresentation.report(call).hasPrefix("Quoted below:\n<subagent:"))
  }
  @Test func runtimeNoteJoinsActivityAndSteerBreaksTheBand() throws {
    let note: TelemetryPart = try TranscriptFixture.decode(
      #"{"type":"telemetry","event":"runtime_warning","data":{"warningKind":"degraded_native_context","message":"Fictional reduced context."}}"#
    )
    let steer: SteerPart = try TranscriptFixture.decode(
      #"{"type":"steer","inputId":"sample-input","messageId":"sample-user","text":"Use the sample API","receivedAt":"2030-01-02T11:59:01.000Z"}"#
    )
    let parts: [WebMessagePart] = [
      .toolCall(try TranscriptFixture.tool(1)), .telemetry(note), .steer(steer),
      .toolCall(try TranscriptFixture.tool(2)),
    ]
    #expect(TranscriptPresentation.isActivity(.telemetry(note)))
    #expect(!TranscriptPresentation.isActivity(.steer(steer)))
    #expect(TranscriptPresentation.activityBands(parts).map { $0.parts.count } == [2, 1, 1])
  }
}
