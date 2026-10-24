// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor
struct TagTests {
  func live() async throws -> Harness {
    let h = try await ConversationActionTests().live()
    h.store.tags = h.store.bootstrap!.tags
    return h
  }
  @Test func createEditAndFailurePublishConfirmedDataOnly() async throws {
    let h = try await live()
    var tag = h.store.tags[0]
    tag.id = "research"
    tag.name = "Research"
    await h.transport.set("/api/v1/tags", [.response(try response(["tag": tag], status: 201))])
    let created = try await h.store.createTag(
      sourceID: tag.sourceId, name: "Research", color: "green")
    #expect(created == tag)
    tag.name = "Planning"
    tag.revision += 1
    await h.transport.set("/api/v1/tags/research", [.paused, .failure])
    let task = Task { try await h.store.updateTag(id: tag.id, name: tag.name, color: "blue") }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.tags.first { $0.id == tag.id }?.name == "Research")
    await h.transport.release(try response(["tag": tag]))
    try await task.value
    await #expect(throws: OrganizeError.self) {
      try await h.store.updateTag(id: tag.id, name: "Refused", color: "blue")
    }
    #expect(h.store.tags.first { $0.id == tag.id }?.name == "Planning")
    #expect(h.store.errorMessage != nil)
    await h.store.stop()
  }

  @Test func deletionConsumesConfirmationAndFailureKeepsTagsAndConversation() async throws {
    let h = try await live()
    let tag = h.store.tags[0]
    h.store.conversations["thread-example"]?.thread.tagIds = [tag.id]
    h.store.conversations["thread-example"]?.record.thread.tagIds = [tag.id]
    h.store.requestTagDeletion(id: tag.id)
    let cancelled = try #require(h.store.tagDeletionConfirmation)
    h.store.cancelTagDeletion()
    await #expect(throws: CancellationError.self) {
      try await h.store.confirmTagDeletion(cancelled.id)
    }
    #expect(await h.transport.count("/api/v1/tags/" + tag.id) == 0)
    await h.transport.set(
      "/api/v1/tags/" + tag.id, [.failure, .response(.init(data: Data(), status: 204))])
    for failed in [true, false] {
      h.store.requestTagDeletion(id: tag.id)
      let request = try #require(h.store.tagDeletionConfirmation)
      do { try await h.store.confirmTagDeletion(request.id) } catch { #expect(failed) }
      #expect(h.store.tags.contains { $0.id == tag.id } == failed)
      #expect(h.store.conversations["thread-example"]?.thread.tagIds.contains(tag.id) == failed)
    }
    #expect(h.store.conversations["thread-example"] != nil)
    await h.store.stop()
  }

  @Test func assignmentIsQueuedDeduplicatedAndFailureKeepsConfirmedTags() async throws {
    let h = try await live()
    var row = h.store.conversations["thread-example"]!.thread
    var tag = h.store.tags[0]
    tag.sourceId = row.sourceId
    h.store.tags = [tag]
    let baseline = row.tagIds
    row.tagIds = [tag.id]
    row.revision += 1
    await h.transport.set("/api/v1/threads/thread-example", [.paused, .failure])
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: row.id) { await gate.wait() }
    await eventually { await gate.ready() }
    let task = Task {
      try await h.store.setConversationTags(threadID: row.id, tagIDs: [tag.id, tag.id])
    }
    await eventually { h.store.pendingConversationActions[row.id] != nil }
    #expect(await h.transport.count("/api/v1/threads/thread-example") == 0)
    #expect(h.store.conversations[row.id]?.thread.tagIds == baseline)
    await gate.release()
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(try response(["thread": row]))
    try await task.value
    await #expect(throws: SubmissionError.self) {
      try await h.store.setConversationTags(threadID: row.id, tagIDs: [])
    }
    #expect(h.store.conversations[row.id]?.thread.tagIds == [tag.id])
    await h.store.stop()
  }

  @Test(arguments: 0..<5)
  func tagWritesGuardUnavailableLifetimesAndDropLateEdit(change: Int) async throws {
    let h = try await live()
    let tag = h.store.tags[0]
    let route = "/api/v1/tags/" + tag.id
    await h.transport.set(route, [.paused])
    let task = Task { try await h.store.updateTag(id: tag.id, name: "Late", color: "blue") }
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case 0: h.store.connection = .offline
    case 1: h.store.backgrounded = true
    case 2: h.store.stopped = true
    case 3: h.store.stopping = true
    default: h.store.selection += 1
    }
    var saved = tag
    saved.name = "Late"
    saved.revision += 1
    await h.transport.release(try response(["tag": saved]))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(h.store.tags[0] == tag)
    if change != 4 {
      await #expect(throws: OrganizeError.self) {
        _ = try await h.store.createTag(sourceID: tag.sourceId, name: "Blocked", color: "blue")
      }
      await #expect(throws: OrganizeError.self) {
        try await h.store.setConversationTags(threadID: "thread-example", tagIDs: [])
      }
      #expect(await h.transport.count("/api/v1/tags") == 0)
    }
    await h.store.stop()
  }

  @Test(arguments: [false, true])
  func lateCreateOrDeleteDoesNotPublish(deleting: Bool) async throws {
    let h = try await live()
    var tag = h.store.tags[0]
    tag.id = deleting ? tag.id : "late-tag"
    let route = "/api/v1/tags" + (deleting ? "/" + tag.id : "")
    await h.transport.set(route, [.paused])
    let task = Task {
      if deleting {
        h.store.requestTagDeletion(id: tag.id)
        try await h.store.confirmTagDeletion(try #require(h.store.tagDeletionConfirmation).id)
      } else {
        _ = try await h.store.createTag(sourceID: tag.sourceId, name: "Late", color: "blue")
      }
    }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    await h.transport.release(
      deleting ? HTTPResponse(data: Data(), status: 204) : try response(["tag": tag], status: 201))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(h.store.tags.contains { $0.id == tag.id } == deleting)
    await h.store.stop()
  }

  @Test func registryRefreshDoesNotOverwriteInterveningMutationOrOtherAgents() async throws {
    let h = try await live()
    let original = h.store.tags[0]
    var other = original
    other.id = "other-tag"
    other.sourceId = "other-agent"
    h.store.tags.append(other)
    var created = original
    created.id = "created-tag"
    created.name = "Planning"
    await h.transport.set(
      "/api/v1/tags", [.paused, .response(try response(["tag": created], status: 201))])
    await h.transport.set(
      "/api/v1/projects", [.response(try response(["projects": h.store.bootstrap!.projects]))])
    let refresh = Task { await h.store.refreshOrganizeLabels(sourceID: original.sourceId) }
    await eventually { await h.transport.pauseCount() == 1 }
    _ = try await h.store.createTag(sourceID: original.sourceId, name: "Planning", color: "blue")
    await h.transport.release(try response(["tags": [original]]))
    await refresh.value
    #expect(h.store.tags.contains { $0.id == created.id })
    #expect(h.store.tags.contains { $0.id == other.id })
    await h.store.stop()
  }

  @Test func registryRefreshDropsSelectionChangedResultAndRefusesOffline() async throws {
    let h = try await live()
    let original = h.store.tags[0]
    await h.transport.set("/api/v1/tags", [.paused])
    let task = Task { await h.store.refreshOrganizeLabels(sourceID: original.sourceId) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    await h.transport.release(try response(["tags": [WebTag]()]))
    await task.value
    #expect(h.store.tags == [original])
    #expect(await h.transport.count("/api/v1/projects") == 0)
    h.store.connection = .offline
    await h.store.refreshOrganizeLabels(sourceID: original.sourceId)
    #expect(await h.transport.count("/api/v1/tags") == 1)
    await h.store.stop()
  }

  @Test func invalidNamesRefuseBeforeDispatch() async throws {
    let h = try await live()
    for name in [" ", "bad\nname", String(repeating: "x", count: 121)] {
      await #expect(throws: OrganizeError.self) {
        _ = try await h.store.createTag(sourceID: "agent-example", name: name, color: "blue")
      }
      await #expect(throws: OrganizeError.self) {
        _ = try await h.store.createProject(
          sourceID: "agent-example", name: name, color: "blue", context: "")
      }
    }
    #expect(await h.transport.count("/api/v1/tags") == 0)
    #expect(await h.transport.count("/api/v1/projects") == 0)
    await h.store.stop()
  }

  @Test func dashboardTagEditLoadsUnheldDetailAndLateAssignmentCannotPublish() async throws {
    let h = try await live()
    var row = h.store.conversations["thread-example"]!.thread
    h.store.conversations[row.id] = nil
    await h.transport.set(
      "/api/v1/threads/thread-example", [.response(try detailResponse(thread: row)), .paused])
    let task = Task { try await h.store.setConversationTags(threadID: row.id, tagIDs: []) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    row.tagIds = []
    row.revision += 1
    await h.transport.release(try response(["thread": row]))
    await #expect(throws: Error.self) { try await task.value }
    #expect(h.store.conversations[row.id]?.thread.revision != row.revision)
    await h.store.stop()
  }
}
