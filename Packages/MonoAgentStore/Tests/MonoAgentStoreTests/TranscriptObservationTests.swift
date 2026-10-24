// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation
import Testing
import os

@testable import MonoAgentStore

@MainActor struct TranscriptObservationTests {
  @Test func tokenWritesPreserveRowIdentityAndOnlyInvalidateChangedRow() throws {
    let first = try sampleMessage("first")
    let second = try sampleMessage("second")
    let state = ConversationState(
      .init(thread: try sampleThread(), messages: [first, second], savedAt: Date()))
    let row = try #require(state.messageStates["first"])
    let untouched = OSAllocatedUnfairLock(initialState: false)
    let orderChanged = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = row.message
    } onChange: {
      untouched.withLock { $0 = true }
    }
    withObservationTracking {
      _ = state.orderedMessageIDs
    } onChange: {
      orderChanged.withLock { $0 = true }
    }
    state.record.messages[1].parts = [.text(.init(text: "A new token"))]
    state.publish()
    #expect(row === state.messageStates["first"])
    #expect(!untouched.withLock { $0 })
    #expect(!orderChanged.withLock { $0 })
    state.record.messages.removeFirst()
    state.publish()
    #expect(state.messageStates["first"] == nil)
    #expect(state.orderedMessageIDs == ["second"])
  }
  @Test func textDeltasHaveNoSpuriousChromeInvalidationAndTerminalIsExact() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    let state = try #require(h.store.conversations["thread-example"])
    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = state.jobItems
      _ = state.jobParentMessages
      _ = state.context
      _ = state.latestReportedAttribution
      _ = state.transcriptMessageIDs
    } onChange: {
      changed.withLock { $0 = true }
    }
    await h.store.apply(try deltaEvent())
    #expect(state.record.messages[0].seq == 2)
    #expect(state.messages[0].seq == 1)
    h.store.publishAll()
    #expect(state.messages[0].seq == 2)
    #expect(!changed.withLock { $0 })
    await h.store.apply(try deltaEvent(base: 2, seq: 3, status: "complete"))
    #expect(state.messages[0].seq == 3)
    #expect(state.messages[0].status == "complete")
  }
  @Test func stopFlushesPendingPublicationBeforeDisablingStore() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    let state = try #require(h.store.conversations["thread-example"])
    await h.store.apply(try deltaEvent())
    #expect(state.messages[0].seq == 1)
    await h.store.stop()
    #expect(state.messages[0].seq == 2)
    #expect(h.store.publicationTask == nil)
  }
  @Test func repeatedGapDoesNotInvalidateAlreadyStaleDetail() throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    let state = try #require(h.store.conversations["thread-example"])
    h.store.markGap(bootstrap: false)
    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = state.freshness
    } onChange: {
      changed.withLock { $0 = true }
    }
    h.store.markGap(bootstrap: false)
    #expect(!changed.withLock { $0 })
  }
  @Test func relevantTelemetryAndJobWritesUpdateProjections() throws {
    var message = try sampleMessage()
    let state = ConversationState(
      .init(thread: try sampleThread(), messages: [message], savedAt: Date()))
    let before = state.context
    let telemetry: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"context_usage","data":{"kind":"context_usage","tokens":{"total":42},"contextWindow":100}}"#
    )
    message.parts.append(.telemetry(telemetry))
    state.record.messages[0] = message
    state.pendingMessageIndices.insert(0)
    state.publishPending()
    #expect(state.context != before)
    #expect(state.context.used == 42)
  }
  @Test func turnGroupingIsStableForLongTranscript() throws {
    var messages: [WebMessage] = []
    for index in 0..<500 {
      var message = try sampleMessage("row-\(index)")
      message.turnId = "turn-\(index / 2)"
      messages.append(message)
    }
    let state = ConversationState(
      .init(thread: try sampleThread(), messages: messages, savedAt: Date()))
    #expect(state.turns.count == 250)
    #expect(state.turns[249].messageIDs == ["row-498", "row-499"])
  }
}
