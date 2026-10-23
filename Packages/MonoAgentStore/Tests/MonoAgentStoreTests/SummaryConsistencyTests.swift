// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct SummaryConsistencyTests {
  @Test func authoritativeDetailUpdatesListAndFleetAndFencesStaleListings() async throws {
    let h = Harness()
    var running = try sampleThread()
    running.runState.status = "running"
    h.store.hold(.init(thread: running, messages: [], savedAt: Date()))
    let key = BucketKey(sourceID: running.sourceId)
    h.store.buckets[key] = .init(key: key, threads: [running], savedAt: Date())
    var fleet: WebActiveThreads = try decode(
      #"{"threads":[],"total":1,"truncated":false,"runningCounts":{}}"#)
    fleet.threads = [running]
    fleet.runningCounts = [running.sourceId: 1]
    h.store.activeFleet = fleet
    var settled = running
    settled.revision += 1
    settled.runState.status = "complete"
    await h.transport.set(
      "/api/v1/threads/thread-example", [.response(try detailResponse(thread: settled))])
    await h.store.refreshDetail(running.id)
    #expect(h.store.conversations[running.id]?.thread.runState.status == "complete")
    #expect(h.store.buckets[key]?.threads.first?.runState.status == "complete")
    #expect(h.store.activeFleet?.threads.first?.runState.status == "complete")
    #expect(h.store.isRunningConfirmed(threadID: running.id))
    #expect(h.store.conversations[running.id]?.runningConfirmed == true)
    // Even a newly encountered listing/fleet cannot reintroduce the older running summary.
    h.store.buckets[key] = nil
    h.store.activeFleet = nil
    h.store.mergeBucket(key, rows: [running], cursor: nil, older: false, fresh: true)
    h.store.applyFleet(fleet)
    #expect(h.store.buckets[key]?.threads.first?.runState.status == "complete")
    #expect(h.store.activeFleet?.threads.first?.runState.status == "complete")
    await h.store.stop()
  }
  @Test func leanTurnMetadataPublishesWithListRowsWithoutWaitingForTranscriptBatch() async throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    let thread = try #require(h.store.conversations["thread-example"]?.thread)
    let key = BucketKey(sourceID: thread.sourceId)
    h.store.buckets[key] = .init(key: key, threads: [thread], savedAt: Date())
    h.store.setDataMode(.lean)
    let turn: JSONValue = .object([
      "id": .string("next-turn"), "status": .string("running"), "model": .string("sample:large"),
    ])
    await h.store.apply(try event("turn.changed", payload: .object(["turn": turn])))
    #expect(h.store.conversations[thread.id]?.thread.runState.status == "running")
    #expect(h.store.conversations[thread.id]?.thread.runState.model == "sample:large")
    #expect(h.store.buckets[key]?.threads.first?.runState.status == "running")
    #expect(h.store.isRunningConfirmed(threadID: thread.id))
    #expect(h.store.conversations[thread.id]?.runningConfirmed == true)
    await h.store.stop()
  }
}
