// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct ProjectTests {
  func live() async throws -> Harness {
    let h = try await ConversationActionTests().live()
    h.store.projects = h.store.bootstrap!.projects
    return h
  }
  @Test func createAndEditPublishOnlyConfirmedValuesAndFailureKeepsPrevious() async throws {
    let h = try await live()
    var project = h.store.projects[0]
    project.id = "garden"
    project.name = "Garden planner"
    project.context = "Fictional garden briefing"
    await h.transport.set(
      "/api/v1/projects", [.response(try response(["project": project], status: 201))])
    let created = try await h.store.createProject(
      sourceID: project.sourceId, name: "Garden planner", color: "blue", context: project.context)
    #expect(created == project)
    project.name = "Research"
    project.revision += 1
    await h.transport.set("/api/v1/projects/garden", [.paused, .failure])
    let task = Task {
      try await h.store.updateProject(
        id: project.id, name: "Research", color: "purple", context: "Briefing")
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.projects.first { $0.id == "garden" }?.name == "Garden planner")
    await h.transport.release(try response(["project": project]))
    try await task.value
    #expect(h.store.projects.first { $0.id == "garden" }?.name == "Research")
    await #expect(throws: OrganizeError.self) {
      try await h.store.updateProject(id: "garden", name: "Refused", color: "blue", context: "")
    }
    #expect(h.store.projects.first { $0.id == "garden" }?.name == "Research")
    #expect(h.store.errorMessage != nil)
    await h.store.stop()
  }

  @Test func projectDeletionRequiresConfirmationAndDetachesWithoutDeletingConversations()
    async throws
  {
    let h = try await live()
    let project = h.store.projects[0]
    h.store.conversations["thread-example"]?.thread.projectId = project.id
    h.store.conversations["thread-example"]?.record.thread.projectId = project.id
    h.store.requestProjectConfirmation(id: project.id)
    let cancelled = try #require(h.store.projectConfirmation)
    h.store.cancelProjectConfirmation()
    await #expect(throws: CancellationError.self) {
      try await h.store.confirmProjectAction(cancelled.id)
    }
    #expect(await h.transport.count("/api/v1/projects/" + project.id) == 0)
    await h.transport.set(
      "/api/v1/projects/" + project.id, [.failure, .response(.init(data: Data(), status: 204))])
    for fail in [true, false] {
      h.store.requestProjectConfirmation(id: project.id)
      let request = try #require(h.store.projectConfirmation)
      do { try await h.store.confirmProjectAction(request.id) } catch { #expect(fail) }
      #expect(h.store.projects.contains { $0.id == project.id } == fail)
      #expect((h.store.conversations["thread-example"]?.thread.projectId != nil) == fail)
    }
    #expect(h.store.conversations["thread-example"] != nil)
    #expect(await h.transport.count("/api/v1/threads/thread-example", method: "DELETE") == 0)
    await h.store.stop()
  }

  @Test func assignmentAndUnassignmentAreSerializedAndFailureKeepsMembership() async throws {
    let h = try await live()
    var project = h.store.projects[0]
    project.sourceId = h.store.conversations["thread-example"]!.thread.sourceId
    h.store.projects = [project]
    var thread = h.store.conversations["thread-example"]!.thread
    let original = thread.projectId
    thread.projectId = project.id
    thread.revision += 1
    await h.transport.set("/api/v1/threads/thread-example", [.paused, .failure])
    let task = Task {
      try await h.store.assignConversationProject(threadID: thread.id, projectID: project.id)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.conversations[thread.id]?.thread.projectId == original)
    await h.transport.release(try response(["thread": thread]))
    try await task.value
    h.store.setConversationProject(threadID: thread.id, projectID: nil)
    do { try await h.store.settleThreadWrites(thread.id) } catch {}
    #expect(h.store.conversations[thread.id]?.thread.projectId == project.id)
    await h.store.stop()
  }

  @Test(arguments: 0..<5)
  func projectCommandsGuardEntryAndDiscardLateResults(change: Int) async throws {
    let h = try await live()
    let project = h.store.projects[0]
    await h.transport.set("/api/v1/projects/" + project.id, [.paused])
    let task = Task {
      try await h.store.updateProject(id: project.id, name: "Late", color: "blue", context: "")
    }
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case 0: h.store.connection = .offline
    case 1: h.store.backgrounded = true
    case 2: h.store.started = false
    case 3: h.store.stopped = true
    default: h.store.selection += 1
    }
    var saved = project
    saved.name = "Late"
    saved.revision += 1
    await h.transport.release(try response(["project": saved]))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(h.store.projects[0] == project)
    if change != 4 {
      await #expect(throws: OrganizeError.self) {
        _ = try await h.store.createProject(
          sourceID: project.sourceId, name: "Blocked", color: "blue", context: "")
      }
      #expect(await h.transport.count("/api/v1/projects") == 0)
    }
    await h.store.stop()
  }

  @Test(arguments: [false, true])
  func lateCreateOrDeleteCannotPublishAfterSelectionChange(deleting: Bool) async throws {
    let h = try await live()
    var project = h.store.projects[0]
    project.id = deleting ? project.id : "late-project"
    let route = "/api/v1/projects" + (deleting ? "/" + project.id : "")
    await h.transport.set(route, [.paused])
    let task = Task {
      if deleting {
        h.store.requestProjectConfirmation(id: project.id)
        try await h.store.confirmProjectAction(try #require(h.store.projectConfirmation).id)
      } else {
        _ = try await h.store.createProject(
          sourceID: project.sourceId, name: "Late", color: "blue", context: "")
      }
    }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    await h.transport.release(
      deleting
        ? HTTPResponse(data: Data(), status: 204) : try response(["project": project], status: 201))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(h.store.projects.contains { $0.id == project.id } == deleting)
    await h.store.stop()
  }

  @Test func projectPageUsesFilteredServerPaginationAndDropsSelectionChangedRead() async throws {
    let h = try await live()
    let project = h.store.projects[0]
    var row = try sampleThread()
    row.projectId = project.id
    let first: JSONValue = .object([
      "threads": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([row])),
      "nextCursor": .string("older"),
    ])
    await h.transport.set("/api/v1/threads", [.response(try response(first)), .paused])
    await h.store.loadProjectMembers(id: project.id)
    #expect(h.store.projectMembers[project.id]?.threads.map(\.id) == [row.id])
    #expect(h.store.projectMembers[project.id]?.nextCursor == "older")
    let task = Task { await h.store.loadProjectMembers(id: project.id, older: true) }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    row.id = "late-row"
    await h.transport.release(
      try response(
        JSONValue.object([
          "threads": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([row])),
          "nextCursor": .null,
        ])))
    await task.value
    #expect(h.store.projectMembers[project.id]?.threads.map(\.id) != ["late-row"])
    await h.store.stop()
  }
}
