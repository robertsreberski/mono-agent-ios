// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation
import Testing
import os

@testable import MonoAgentStore

@MainActor
struct TagPublicationTests {
  @Test(arguments: [DataMode.full, .lean])
  func confirmedSummaryInvalidatesHeaderInputInSameTurn(mode: DataMode) async throws {
    let h = try await TagTests().live()
    h.store.setDataMode(mode)
    let state = try #require(h.store.conversations["thread-example"])
    var tag = try #require(h.store.tags.first)
    tag.id = "sample-label"
    tag.name = "Sample label"
    tag.sourceId = state.thread.sourceId
    h.store.tags = [tag]
    var saved = state.thread
    saved.tagIds = [tag.id]
    saved.revision += 1
    #expect(state.thread.tagIds != saved.tagIds)
    let invalidated = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      // Match ConversationScreen's held-thread read, not the transcript publication cache.
      _ = h.store.conversations[saved.id]?.thread.tagIds
    } onChange: {
      invalidated.withLock { $0 = true }
    }

    h.store.patchSummary(saved)

    // No suspension, timer advancement or explicit transcript flush after the patch.
    #expect(invalidated.withLock { $0 })
    #expect(h.store.conversations[saved.id] === state)
    #expect(state.thread.tagIds == [tag.id])
    #expect(state.record.thread.tagIds == [tag.id])
    #expect(h.store.publicationTask == nil)
    #expect(
      h.store.tags.filter { state.thread.tagIds.contains($0.id) }.map(\.name).joined(
        separator: ", ") == "Sample label")
    await h.store.stop()
  }

  @Test(arguments: [DataMode.full, .lean])
  func assignmentPublishesConfirmedTagsBeforeReturningWithoutDeltaTimer(mode: DataMode) async throws
  {
    let h = try await TagTests().live()
    h.store.setDataMode(mode)
    let state = try #require(h.store.conversations["thread-example"])
    var tag = try #require(h.store.tags.first)
    tag.id = "sample-label"
    tag.sourceId = state.thread.sourceId
    h.store.tags = [tag]
    let baseline = state.thread.tagIds
    var saved = state.thread
    saved.tagIds = [tag.id]
    saved.revision += 1
    #expect(baseline != saved.tagIds)
    await h.transport.set("/api/v1/threads/thread-example", [.paused])
    let task = Task { try await h.store.setConversationTags(threadID: saved.id, tagIDs: [tag.id]) }
    await eventually { await h.transport.pauseCount() == 1 }
    // Organize assignments are confirmed-only, not optimistic, even before coalescing.
    #expect(state.thread.tagIds == baseline)
    #expect(h.store.publicationTask == nil)
    await h.transport.release(try response(["thread": saved]))
    try await task.value
    #expect(state.thread.tagIds == [tag.id])
    #expect(state.record.thread.tagIds == [tag.id])
    #expect(h.store.publicationTask == nil)
    await h.store.stop()
  }
}
