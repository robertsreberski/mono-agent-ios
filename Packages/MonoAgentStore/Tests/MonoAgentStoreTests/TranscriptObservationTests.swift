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
