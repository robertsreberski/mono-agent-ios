// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

struct UsagePresentationTests {
  @Test func unknownAndPartialValuesNeverBecomeZero() throws {
    #expect(UsagePresentation.tokens(nil) == "Not reported")
    #expect(UsagePresentation.tokens(.nan) == "Not reported")
    #expect(UsagePresentation.tokens(0) == "0")
    #expect(UsagePresentation.tokens(1200) == "1.2k")
    #expect(UsagePresentation.tokens(1_000_000) == "1M")
    #expect(UsagePresentation.usd(nil) == "Unknown")
    #expect(UsagePresentation.usd(0) == "$0.00")
    #expect(UsagePresentation.usd(0.0012) == "$0.0012")
    let usage: WebThreadUsage = try decode(
      #"{"total":{"costUnknown":true,"knownCostUsd":0.4},"subagents":{"tokens":{"input":10,"cacheWrite":2,"cacheRead":20,"output":3},"costUsd":0.12,"tokensPartial":true,"costPartial":true},"byModel":[],"computedAt":"2030-01-02T12:00:00Z"}"#
    )
    let rows = UsagePresentation.rows(usage)
    #expect(rows.contains(.init("Total · Tokens", "Not reported")))
    #expect(rows.contains(.init("Total · Estimated cost", "Unknown · Known cost $0.40")))
    #expect(rows.contains(.init("incl. subagents · Input (incl. cache writes)", "≥12")))
    #expect(rows.contains(.init("incl. subagents · Estimated cost", "≥$0.12")))
    #expect(UsagePresentation.rows(nil).allSatisfy { $0.value == "Not reported" })
  }
  @Test func onlyContextTelemetryMeasuresOccupancyAndFailedSnapshotsAreExcluded() throws {
    var thread = try sampleThread()
    thread.runState.status = "complete"
    thread.runModel = nil
    var message = try sampleMessage()
    message.status = "complete"
    var telemetry: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"usage","data":{"total":4000,"contextWindow":200000}}"#)
    message.parts = [.telemetry(telemetry)]
    #expect(UsagePresentation.context(messages: [message], thread: thread).used == nil)
    telemetry.event = "runtime"
    telemetry.data = .object([
      "kind": .string("context_usage"),
      "data": .object(["context": .object(["used": .number(84000), "window": .number(200000)])]),
    ])
    message.parts = [.telemetry(telemetry)]
    var projection = UsagePresentation.context(messages: [message], thread: thread)
    #expect(projection.used == 84000)
    #expect(projection.percent == 42)
    #expect(projection.badge == "42%")
    #expect(projection.figure == "84k / 200k tokens")
    message.status = "failed"
    #expect(UsagePresentation.context(messages: [message], thread: thread).used == nil)
    message.status = "complete"
    thread.runState.status = "running"
    #expect(UsagePresentation.context(messages: [message], thread: thread).status == "Updating")
    thread.runState.status = "failed"
    #expect(
      UsagePresentation.context(messages: [message], thread: thread).status == "Last measured")
    projection.window = nil
    #expect(projection.badge == "—")
    projection.used = 0
    projection.window = 100
    #expect(projection.badge == "0%")
  }
  @Test func compactionInvalidatesExactMeasurementAndTimestampWinsOverPageOrder() throws {
    var thread = try sampleThread()
    thread.runState.status = "complete"
    thread.runModel = nil
    var message = try sampleMessage()
    message.status = "complete"
    let exact: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"context_usage","data":{"timestamp":2000,"total":10000,"contextWindow":200000}}"#
    )
    let compact: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"context_compaction","data":{"timestamp":3000,"status":"succeeded","tokensAfter":2000}}"#
    )
    message.parts = [.telemetry(compact), .telemetry(exact)]
    let projection = UsagePresentation.context(messages: [message], thread: thread)
    #expect(projection.estimated)
    #expect(projection.used == 2000)
    #expect(projection.badge == "≈1%")
    #expect(projection.note != nil)
  }
}
