// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Observation
import Testing

@testable import MonoAgentStore

@MainActor
struct ConsoleStoreTests {
  @Test func eventDuringReadCannotRegressSequenceRevisionOrMarkFresh() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    await h.transport.set("/api/v1/threads/thread-example", [.paused])
    let read = Task { await h.store.refreshDetail("thread-example") }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.receive(.event(generation: 1, gap: .initial, try deltaEvent()))
    h.store.patchSummary(try sampleThread(revision: 5))
    await h.transport.release(try detailResponse(messages: [sampleMessage()]))
    await read.value
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 2)
    #expect(h.store.conversations["thread-example"]?.thread.revision == 5)
    #expect(h.store.conversations["thread-example"]?.freshness == .stale)
    await h.store.stop()
  }
  @Test func invalidated304DoesNotConfirmFreshness() async throws {
    let h = Harness()
    try h.seed()
    h.store.conversations["thread-example"]?.etag = "version"
    await h.transport.set("/api/v1/threads/thread-example", [.paused])
    let read = Task { await h.store.refreshDetail("thread-example") }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.observe("thread-example")
    await h.transport.release(HTTPResponse(data: Data(), status: 304))
    await read.value
    #expect(h.store.conversations["thread-example"]?.freshness == .stale)
    await h.store.stop()
  }
  @Test func tombstonesBlockLateReadsAndSurviveRelaunch() async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.transport.set("/api/v1/threads/thread-example", [.paused])
    let read = Task { await h.store.refreshDetail("thread-example") }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.removeThread("thread-example")
    await h.transport.release(try detailResponse())
    await read.value
    #expect(h.store.conversations.isEmpty)
    await h.store.flushCache()
    let again = Harness(profile: h.profile, directory: h.directory)
    await again.store.hydrate()
    #expect(again.store.tombstones.contains("thread-example"))
    await h.store.stop()
    await again.store.stop()
  }
  @Test func pagingPreservesServerOrderAndHistoryAcrossWindowRefresh() async throws {
    let first = try sampleMessage("first")
    let second = try sampleMessage("second")
    let older = try sampleMessage("older")
    let merged = TranscriptMerge.window(
      [second, first], held: [older, first, second], paged: ["older"], repaired: [], complete: false
    )
    #expect(merged.map(\.id) == ["second", "older", "first"])
    let h = Harness()
    try h.seed(messages: [first])
    h.store.selectedThreadID = "thread-example"
    h.store.conversations["thread-example"]?.record.nextCursor = "older-cursor"
    h.store.conversations["thread-example"]?.publish()
    await h.transport.set(
      "/api/v1/threads/thread-example/messages",
      [
        .response(
          try response(
            JSONValue.object([
              "messages": .array([
                try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(older))
              ]), "nextCursor": .null,
            ])))
      ])
    await h.store.loadOlder()
    #expect(h.store.selectedConversation?.messages.map(\.id) == ["older", "first"])
    await h.store.stop()
  }
  @Test func repairsAreSingleFlightWithTrailingInvalidationAndUnheldCostsNothing() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    await h.transport.set(
      "/api/v1/threads/thread-example/messages/message-example",
      [
        .paused,
        .response(
          try response(
            JSONValue.object([
              "message": try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(sampleMessage(seq: 4)))
            ]))),
      ])
    h.store.repairMessage(threadID: "thread-example", messageID: "message-example")
    await eventually { await h.transport.pauseCount() == 1 }
    for _ in 0..<50 {
      h.store.repairMessage(threadID: "thread-example", messageID: "message-example")
    }
    await h.transport.release(
      try response(
        JSONValue.object([
          "message": try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(sampleMessage(seq: 3)))
        ])))
    await eventually { h.store.repairs.isEmpty }
    #expect(await h.transport.count("/api/v1/threads/thread-example/messages/message-example") == 2)
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 4)
    h.store.conversations.removeAll()
    await h.store.receive(.event(generation: 1, gap: .initial, try deltaEvent(base: 20, seq: 21)))
    #expect(await h.transport.count("/api/v1/threads/thread-example/messages/message-example") == 2)
    #expect(h.store.observations["thread-example"] != nil)
    await h.store.stop()
  }
  @Test func leanBatchesForOneSecondButTerminalPassesImmediately() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    h.store.setDataMode(.lean)
    await h.store.receive(.event(generation: 1, gap: .initial, try deltaEvent()))
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 1)
    #expect(h.store.conversations["thread-example"]?.record.messages.first?.seq == 2)
    await eventually { await h.clock.pending() >= 2 }
    await h.clock.advance(1)
    await eventually { h.store.conversations["thread-example"]?.messages.first?.seq == 2 }
    await h.store.receive(.event(generation: 1, gap: .initial, try deltaEvent(base: 2, seq: 3)))
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 2)
    await h.store.receive(
      .event(generation: 1, gap: .initial, try deltaEvent(base: 3, seq: 4, status: "complete")))
    #expect(h.store.conversations["thread-example"]?.messages.first?.seq == 4)
    #expect(h.store.pageLimit == 25)
    #expect(h.store.messagePageLimit == 15)
    await h.store.networkChanged(reachable: false, constrained: true)
    h.store.setDataMode(.auto)
    #expect(h.store.effectiveDataMode == .lean)
    await h.store.networkChanged(reachable: false, constrained: false)
    #expect(h.store.effectiveDataMode == .full)
    #expect(h.store.pageLimit == 50)
    #expect(h.store.messagePageLimit == 30)
    await h.store.stop()
  }
  @Test func generationRejectsOldSelectionAndBackgroundReads() async throws {
    let h = Harness()
    h.store.selectedThreadID = "thread-example"
    await h.transport.set("/api/v1/threads/thread-example", [.paused, .paused])
    let read = Task { await h.store.refreshDetail("thread-example") }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    h.store.selectedThreadID = "other-thread"
    await h.transport.release(try detailResponse())
    await read.value
    #expect(h.store.conversations.isEmpty)
    let old = Task { await h.store.refreshDetail("thread-example") }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.scenePhaseChanged(.background)
    await h.transport.release(try detailResponse())
    await old.value
    #expect(h.store.conversations.isEmpty)
  }
  @Test func unreadFirstSightWatermarksAndVisibility() async throws {
    let h = Harness()
    let first = try sampleThread()
    h.store.noteSummary(first)
    #expect(!h.store.isUnread(first))
    var newer = try sampleThread(revision: 2)
    h.store.noteSummary(newer)
    #expect(h.store.isUnread(newer))
    h.store.hold(.init(thread: newer, messages: [], savedAt: Date()))
    h.store.selectedThreadID = newer.id
    h.store.markVisible(false)
    #expect(h.store.isUnread(newer))
    h.store.markVisible(true)
    #expect(!h.store.isUnread(newer))
    h.store.markVisible(false)
    newer.revision = 4
    newer.readRevision = 4
    h.store.noteSummary(newer)
    #expect(!h.store.isUnread(newer))
    await h.store.stop()
  }
  @Test func draftsAreBoundedVersionedScopedAndPersistMode() async throws {
    let h = Harness()
    await h.store.hydrate()
    for index in 0..<42 { await h.store.setDraft(sourceID: "agent-\(index)", text: "Draft") }
    #expect(h.store.drafts.count == 40)
    await h.store.setDraft(
      sourceID: "agent-example", threadID: "thread-example",
      text: String(repeating: "x", count: 33_000))
    #expect(
      h.store.draft(sourceID: "agent-example", threadID: "thread-example")?.text.count == 32_768)
    h.store.setDataMode(.lean)
    await h.store.flushAuthored()
    let again = Harness(profile: h.profile, directory: h.directory)
    await again.store.hydrate()
    #expect(again.store.drafts.count == 40)
    #expect(again.store.dataMode == .lean)
    let other = Harness(directory: h.directory)
    await other.store.hydrate()
    #expect(other.store.drafts.isEmpty)
    #expect(other.store.namespace != h.store.namespace)
    await h.store.stop()
    await again.store.stop()
    await other.store.stop()
  }
  @Test func coldStartThenReadyAndForegroundReconcileWithoutResubscribeOnOverflow() async throws {
    let h = Harness()
    await h.transport.set(
      "/api/v1/bootstrap", [.response(Scenario.bootstrap), .response(Scenario.bootstrap)])
    await h.store.start()
    #expect(await h.transport.count("/api/v1/bootstrap") == 1)
    #expect(await h.events.count() == 1)
    await h.store.receive(
      .event(
        generation: 1, gap: .initial,
        try event("ready", thread: nil, payload: .object(["version": .number(1)]))))
    await h.store.reconciliationTask?.value
    #expect(await h.transport.count("/api/v1/threads/active") == 1)
    await h.store.receive(.gap(generation: 2, reason: .overflow))
    await h.store.reconciliationTask?.value
    #expect(await h.events.count() == 1)
    #expect(await h.transport.count("/api/v1/bootstrap") == 2)
    await h.store.scenePhaseChanged(.inactive)
    #expect(h.store.connection == .live)
    await h.store.scenePhaseChanged(.background)
    #expect(h.store.connection == .offline)
    await h.store.scenePhaseChanged(.active)
    #expect(await h.events.count() == 2)
    #expect(h.store.needsBootstrap)
    await h.store.stop()
  }
}
