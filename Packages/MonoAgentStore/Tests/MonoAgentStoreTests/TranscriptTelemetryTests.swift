// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

struct TranscriptTelemetryTests {
  private func part(_ event: String = "other", _ data: JSONValue = .null) throws -> TelemetryPart {
    let object: JSONValue = .object([
      "type": .string("telemetry"), "event": .string(event), "data": data,
    ])
    return try JSONDecoder().decode(TelemetryPart.self, from: JSONEncoder().encode(object))
  }
  @Test func warningRequiresExactKindObjectAndNonblankText() throws {
    let good: JSONValue = .object([
      "warningKind": .string("degraded_native_context"), "message": .string(" A sample warning "),
    ])
    #expect(
      TranscriptTelemetry.presentation(try part("runtime_warning", good))
        == .note(" A sample warning "))
    #expect(TranscriptTelemetry.presentation(try part("other", good)) == .hidden)
    for data: JSONValue in [
      .null, .array([good]),
      .object(["warningKind": .string("other"), "message": .string("Text")]),
      .object(["warningKind": .string("degraded_native_context"), "message": .string(" \n")]),
    ] {
      #expect(TranscriptTelemetry.presentation(try part("runtime_warning", data)) == .hidden)
    }
  }
  @Test func compactionAndBoundaryMatchWebEightLayerLimit() throws {
    #expect(TranscriptTelemetry.presentation(try part("context_compaction")) == .compaction)
    for key in ["kind", "type"] {
      var data: JSONValue = .object([key: .string("context_compaction")])
      for _ in 0..<7 { data = .object(["data": data]) }
      #expect(TranscriptTelemetry.presentation(try part("other", data)) == .compaction)
      #expect(
        TranscriptTelemetry.presentation(try part("other", .object(["data": data]))) == .hidden)
    }
    for kind in ["assistant_message_boundary", "context_usage"] {
      let data: JSONValue = .object(["data": .object(["kind": .string(kind)])])
      #expect(TranscriptTelemetry.presentation(try part("cron_run", data)) == .hidden)
    }
    #expect(TranscriptTelemetry.presentation(try part("context-compaction")) == .hidden)
    #expect(TranscriptTelemetry.presentation(try part("context_usage")) == .hidden)
  }
  @Test func cronIsReadOnlyAndSilentRunsStayInvisible() throws {
    var data: [String: JSONValue] = [
      "runId": .string("sample-run"), "sequence": .number(2), "status": .string("succeeded"),
      "trigger": .string("manual"), "artifactRunId": .string("sample-artifact"),
      "eventCount": .number(3),
    ]
    guard
      case .cron(let run) = TranscriptTelemetry.presentation(try part("cron_run", .object(data)))
    else {
      Issue.record("Expected cron summary")
      return
    }
    #expect(run.title == "Run 2")
    #expect(run.status == "manual · completed")
    #expect(run.details.count == 2)
    data["silent"] = .bool(true)
    #expect(TranscriptTelemetry.presentation(try part("cron_run", .object(data))) == .hidden)
    data["hasVisibleContent"] = .bool(true)
    #expect(TranscriptTelemetry.presentation(try part("cron_run", .object(data))) != .hidden)
    #expect(TranscriptTelemetry.presentation(try part("cron_run")) == .hidden)
  }
  @MainActor @Test func hiddenOnlyMessageHasNoRowButTelemetryRemainsStored() throws {
    var message = try sampleMessage("hidden-sample")
    message.parts = [.telemetry(try part("context_usage"))]
    #expect(!TranscriptTelemetry.visible(message))
    var thread = try sampleThread()
    thread.id = message.threadId
    let state = ConversationState(.init(thread: thread, messages: [message], savedAt: Date()))
    #expect(state.orderedMessageIDs == [message.id])
    #expect(state.transcriptMessageIDs.isEmpty)
    #expect(state.messages[0].parts.count == 1)
    message.parts.append(.text(.init(text: "Visible answer")))
    state.record.messages = [message]
    state.publish()
    #expect(state.transcriptMessageIDs == [message.id])
    #expect(message.parts.filter(TranscriptTelemetry.visible).count == 1)
  }
}
