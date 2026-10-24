// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation
import Testing
import os

@testable import MonoAgentStore

@MainActor struct DashboardProjectionTests {
  @Test func unreadCountsDeduplicateAndFollowReadMarkers() throws {
    let h = Harness()
    let thread = try sampleThread(revision: 4)
    let key = BucketKey(sourceID: thread.sourceId)
    h.store.setSeen(thread.id, revision: 2)
    h.store.buckets[key] = .init(key: key, threads: [thread, thread], savedAt: Date())
    #expect(h.store.unreadCounts[thread.sourceId] == 1)
    h.store.setSeen(thread.id, revision: 4)
    #expect(h.store.unreadCounts.isEmpty)
  }
  @Test func existingHoldDoesNotInvalidateRegistryAndSummaryTracksThread() throws {
    let h = Harness()
    try h.seed(messages: [sampleMessage()])
    let state = try #require(h.store.conversations["thread-example"])
    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = h.store.conversations
    } onChange: {
      changed.withLock { $0 = true }
    }
    h.store.hold(state.record)
    #expect(!changed.withLock { $0 })
    state.record.thread.title = "Updated sample title"
    state.publish()
    #expect(h.store.cachedThreads.first?.title == "Updated sample title")
  }
}
