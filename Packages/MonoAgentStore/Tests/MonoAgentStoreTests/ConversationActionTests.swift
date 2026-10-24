// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor
struct ConversationActionTests {
  let path = "/api/v1/threads/thread-example"

  func live(archived: Bool = false) async throws -> Harness {
    let h = Harness()
    await h.store.hydrate()
    h.store.bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    h.store.bootstrap?.agents[0].supportsManualCompaction = true
    h.store.started = true
    h.store.connection = .live
    var thread = try sampleThread()
    thread.archivedAt = archived ? "2030-01-02T12:00:00Z" : nil
    thread.trigger = nil
    thread.compaction = nil
    thread.runState.status = "idle"
    h.store.hold(.init(thread: thread, messages: [], savedAt: Date()))
    return h
  }

  @Test func renameIsQueuedAndPublishesOnlyConfirmedData() async throws {
    let h = try await live()
    let original = h.store.conversations["thread-example"]!.thread.title
    await h.transport.set(path, [.paused])
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    h.store.renameConversation(threadID: "thread-example", title: "  Garden planner  ")
    #expect(await h.transport.count(path) == 0)
    #expect(h.store.conversations["thread-example"]?.thread.title == original)
    await gate.release()
    await eventually { await h.transport.pauseCount() == 1 }
    var saved = h.store.conversations["thread-example"]!.thread
    saved.title = "Garden planner"
    saved.revision += 1
    await h.transport.release(try response(["thread": saved]))
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.conversations["thread-example"]?.thread.title == "Garden planner")
    #expect(h.store.pendingConversationActions.isEmpty)
    await h.store.stop()
  }

  @Test func failedRenameKeepsConfirmedTitleAndSurfacesError() async throws {
    let h = try await live()
    let before = h.store.conversations["thread-example"]!.thread
    await h.transport.set(path, [.failure])
    h.store.renameConversation(threadID: before.id, title: "Research")
    do { try await h.store.settleThreadWrites(before.id) } catch {}
    await eventually { h.store.pendingConversationActions.isEmpty }
    #expect(h.store.conversations[before.id]?.thread == before)
    #expect(h.store.errorMessage != nil)
    await h.store.stop()
  }

  @Test(arguments: [ConversationAction.archive, .delete])
  func actionsRequireOneShotConfirmationAndCancelNeverWrites(action: ConversationAction)
    async throws
  {
    let h = try await live(archived: action == .delete)
    h.store.requestConversationAction(action, threadID: "thread-example")
    let cancelled = try #require(h.store.conversationActionConfirmation)
    h.store.cancelConversationAction()
    h.store.confirmConversationAction(cancelled.id)
    #expect(h.store.pendingConversationActions.isEmpty)
    #expect(await h.transport.count(path) == 0)
    h.store.requestConversationAction(action, threadID: "thread-example")
    let stale = try #require(h.store.conversationActionConfirmation)
    h.store.selection += 1
    h.store.confirmConversationAction(stale.id)
    #expect(h.store.pendingConversationActions.isEmpty)
    await h.store.stop()
  }

  @Test func deleteOnlyArchivedEligibleThreadsAndPreserveDraftOnFailure() async throws {
    let h = try await live()
    h.store.requestConversationAction(.delete, threadID: "thread-example")
    #expect(h.store.conversationActionConfirmation == nil)
    h.store.conversations["thread-example"]?.thread.archivedAt = "2030-01-02T12:00:00Z"
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "A note")
    await h.transport.set(path, [.failure, .response(.init(data: Data(), status: 204))])
    for failed in [true, false] {
      h.store.requestConversationAction(.delete, threadID: "thread-example")
      let request = try #require(h.store.conversationActionConfirmation)
      h.store.confirmConversationAction(request.id)
      h.store.confirmConversationAction(request.id)
      do { try await h.store.settleThreadWrites("thread-example") } catch {}
      await eventually { h.store.pendingConversationActions.isEmpty }
      #expect((h.store.conversations["thread-example"] != nil) == failed)
      #expect(
        (h.store.draft(sourceID: "agent-example", threadID: "thread-example") != nil) == failed)
    }
    #expect(await h.transport.count(path, method: "DELETE") == 2)
    #expect(h.store.tombstones["thread-example"] != nil)
    await h.store.stop()
  }

  @Test func archiveAndRestoreUsePatchAndArchiveOnlyDeletesConfirmedEmpty() async throws {
    let h = try await live()
    var saved = h.store.conversations["thread-example"]!.thread
    saved.archivedAt = "2030-01-02T12:00:00Z"
    saved.messageCount = 2
    saved.revision += 1
    await h.transport.set(path, [.response(try response(["thread": saved]))])
    h.store.requestConversationAction(.archive, threadID: saved.id)
    h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    try await h.store.settleThreadWrites(saved.id)
    #expect(h.store.conversations[saved.id]?.thread.archivedAt != nil)
    #expect(await h.transport.count(path, method: "DELETE") == 0)
    saved.archivedAt = nil
    saved.revision += 1
    await h.transport.set(path, [.response(try response(["thread": saved]))])
    h.store.restoreConversation(threadID: saved.id)
    try await h.store.settleThreadWrites(saved.id)
    #expect(h.store.conversations[saved.id]?.thread.archivedAt == nil)
    saved.archivedAt = "2030-01-02T12:00:00Z"
    saved.messageCount = 0
    saved.revision += 1
    await h.transport.set(
      path,
      [
        .response(try response(["thread": saved])), .response(.init(data: Data(), status: 204)),
      ])
    h.store.requestConversationAction(.archive, threadID: saved.id)
    h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    try await h.store.settleThreadWrites(saved.id)
    #expect(h.store.conversations[saved.id] == nil)
    #expect(await h.transport.count(path, method: "DELETE") == 1)
    await h.store.stop()
  }

  @Test(arguments: 0..<5)
  func guardsRefuseAtEntryAndAgainAtQueueExecution(change: Int) async throws {
    let h = try await live()
    func block() {
      switch change {
      case 0: h.store.connection = .offline
      case 1: h.store.backgrounded = true
      case 2: h.store.stopped = true
      case 3: h.store.stopping = true
      default: h.store.started = false
      }
    }
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    h.store.renameConversation(threadID: "thread-example", title: "Queued")
    block()
    h.store.restoreConversation(threadID: "thread-example")
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    #expect(await h.transport.count(path) == 0)
    #expect(h.store.pendingConversationActions.isEmpty)
    await h.store.stop()
  }

  @Test(arguments: 0..<4)
  func lateRenameDoesNotReplaceHeldState(change: Int) async throws {
    let h = try await live()
    let original = h.store.conversations["thread-example"]!.thread
    await h.transport.set(path, [.paused])
    h.store.renameConversation(threadID: original.id, title: "Late title")
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case 0: h.store.selection += 1
    case 1: h.store.epoch += 1
    case 2: h.store.backgrounded = true
    default:
      h.store.conversations[original.id] = nil
      h.store.hold(.init(thread: original, messages: [], savedAt: Date()))
    }
    var saved = original
    saved.title = "Late title"
    saved.revision += 1
    await h.transport.release(try response(["thread": saved]))
    await h.store.writeTasks[original.id]?.value
    #expect(h.store.conversations[original.id]?.thread.title == original.title)
    await h.store.stop()
  }

  @Test(arguments: ["delete", "compact"])
  func lateDestructiveOrCompactResponseIsDropped(action: String) async throws {
    let h = try await live(archived: action == "delete")
    let route = action == "compact" ? path + "/compact" : path
    await h.transport.set(route, [.paused])
    if action == "compact" {
      h.store.compactConversation(threadID: "thread-example")
    } else {
      h.store.requestConversationAction(.delete, threadID: "thread-example")
      h.store.confirmConversationAction(try #require(h.store.conversationActionConfirmation).id)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.selection += 1
    let reply =
      action == "delete"
      ? HTTPResponse(data: Data(), status: 204)
      : HTTPResponse(
        data: Data(
          #"{"status":"succeeded","operationId":"compact-example","trigger":"manual"}"#.utf8))
    await h.transport.release(reply)
    await h.store.writeTasks["thread-example"]?.value
    #expect(h.store.conversations["thread-example"] != nil)
    #expect(h.store.manualCompactions["thread-example"] == nil)
    #expect(h.store.tombstones["thread-example"] == nil)
    await h.store.stop()
  }

  @Test func queuedDeadlineDoesNotDispatchOrLeavePendingState() async throws {
    let h = try await live()
    let gate = WriteGate()
    h.store.enqueueThreadWrite(threadID: "thread-example") { await gate.wait() }
    await eventually { await gate.ready() }
    h.store.renameConversation(threadID: "thread-example", title: "Expired")
    await eventually { await h.clock.pending() >= 2 }
    await h.clock.advance(ConsoleBounds.threadWriteTimeout + 1)
    await gate.release()
    await h.store.writeTasks["thread-example"]?.value
    #expect(await h.transport.count(path) == 0)
    #expect(h.store.pendingConversationActions.isEmpty)
    #expect(h.store.errorMessage != nil)
    await h.store.stop()
  }

  @Test func compactPublishesPendingAndResultWithoutRetry() async throws {
    let h = try await live()
    let compactPath = path + "/compact"
    await h.transport.set(compactPath, [.paused])
    h.store.compactConversation(threadID: "thread-example")
    #expect(h.store.manualCompactions["thread-example"] == .pending)
    await eventually { await h.transport.pauseCount() == 1 }
    let result = try decode(
      #"{"status":"succeeded","operationId":"compact-example","trigger":"manual","tokensBefore":4000,"tokensAfter":2000,"tokenCountsExact":true}"#,
      as: AgentManualCompactionResult.self)
    await h.transport.release(try response(result))
    try await h.store.settleThreadWrites("thread-example")
    #expect(h.store.manualCompactions["thread-example"] == .result(result))
    #expect(await h.transport.count(compactPath, method: "POST") == 1)
    await h.store.stop()
  }
}
