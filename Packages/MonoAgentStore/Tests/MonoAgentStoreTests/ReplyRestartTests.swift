// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor struct ReplyRestartTests {
  private let reference = ReplyPartReference(
    threadId: "thread-example", messageId: "message-example", partId: "restart")
  private let post = "/api/v1/threads/thread-example/messages/message-example/parts/restart/restart"
  private func proposal(_ availability: String = "available", operation: String? = nil) throws
    -> RestartProposalPart
  {
    let link = operation.map { ",\"operationId\":\"\($0)\"" } ?? ""
    return try decode(
      """
      {"type":"restart_proposal","id":"restart","reason":"Apply the sample update.","restartable":{"state":"\(availability)"\(link)}}
      """)
  }
  private func live(_ availability: String = "available", operation: String? = nil) async throws
    -> Harness
  {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    var message = try sampleMessage()
    message.parts = [.restartProposal(try proposal(availability, operation: operation))]
    try h.seed(messages: [message])
    h.store.selectedThreadID = reference.threadId
    return h
  }
  private func operation(_ h: Harness, outcome: String? = nil) throws -> WebAgentRestartOperation {
    var value: WebAgentRestartOperation = try decode(
      #"{"id":"restart-operation","sourceId":"sample","stage":"restarting","requestedAt":"2030-01-02T12:00:00Z","deadline":"2030-01-02T12:02:00Z"}"#
    )
    value.sourceId = try #require(h.store.conversations[reference.threadId]?.thread.sourceId)
    value.outcome = outcome
    if outcome != nil { value.stage = "back_online" }
    return value
  }
  private func status(_ h: Harness) throws -> String {
    "/api/v1/agents/" + (try operation(h)).sourceId + "/restart"
  }

  @Test func renderConfirmCancelAndUnavailableNeverPost() async throws {
    for availability in ["available", "unavailable", "used"] {
      let h = try await live(availability)
      let state = h.store.restartProposalState(reference)
      #expect(!state.confirming && !state.requesting && state.operationID == nil)
      await h.store.confirmRestart(reference)
      h.store.requestRestartConfirmation(reference)
      #expect(state.confirming == (availability == "available"))
      h.store.cancelRestartConfirmation(reference)
      await h.store.confirmRestart(reference)
      #expect(await h.transport.count(post, method: "POST") == 0)
      await h.store.stop()
    }
  }
  @Test func confirmedRestartPostsOnceThenPollsPendingWarningAndSuccess() async throws {
    let h = try await live()
    let state = h.store.restartProposalState(reference)
    await h.transport.set(post, [.response(try response(operation(h)))])
    h.store.requestRestartConfirmation(reference)
    await h.store.confirmRestart(reference)
    await h.store.confirmRestart(reference)
    #expect(await h.transport.count(post, method: "POST") == 1)
    #expect(state.operationID == "restart-operation" && state.stage == "restarting")
    let path = try status(h) + "/restart-operation"
    await h.transport.set(
      path,
      [
        .response(try response(operation(h))), .failure,
        .response(try response(operation(h, outcome: "success"))),
      ])
    let poll = Task { await h.store.pollRestartProposal(reference) }
    await eventually {
      let count = await h.transport.count(path)
      let pending = await h.clock.hasRestartPollSleep()
      return count == 1 && pending
    }
    await h.clock.advance(2)
    await eventually {
      let pending = await h.clock.hasRestartPollSleep()
      return state.pollWarning != nil && pending
    }
    #expect(state.outcome == nil)
    await h.clock.advance(2)
    await poll.value
    #expect(state.outcome == "success" && state.pollWarning == nil)
    await h.store.stop()
  }
  @Test func usedProposalRestoresOnlyReadsAndFailureOutcomeIsHonest() async throws {
    let h = try await live("used", operation: "restart-operation")
    let path = try status(h) + "/restart-operation"
    await h.transport.set(path, [.response(try response(operation(h, outcome: "failure")))])
    await h.store.pollRestartProposal(reference)
    #expect(h.store.restartProposalState(reference).outcome == "failure")
    #expect(await h.transport.count(post) == 0)
    await h.store.stop()
  }
  @Test func definitiveRefusalAndLostResponseDoNotAutomaticallyRetry() async throws {
    let h = try await live()
    await h.transport.set(
      post,
      [
        .response(
          .init(
            data: Data(#"{"error":{"code":"restart_unavailable","message":"No"}}"#.utf8),
            status: 409))
      ])
    h.store.requestRestartConfirmation(reference)
    await h.store.confirmRestart(reference)
    #expect(h.store.restartProposalState(reference).outcome == "failure")
    #expect(await h.transport.count(post) == 1)
    await h.store.stop()
    let lost = try await live()
    await lost.transport.set(post, [.failure])
    await lost.transport.set(
      try status(lost),
      [
        .response(
          try response(
            JSONValue.object([
              "operation": try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(operation(lost)))
            ])))
      ])
    // An old unrelated latest operation must not be adopted by this proposal.
    let message = try sampleMessage()
    await lost.transport.set(
      "/api/v1/threads/thread-example/messages/message-example",
      [
        .response(
          try response(
            JSONValue.object([
              "message": try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(message))
            ])))
      ])
    lost.store.requestRestartConfirmation(reference)
    await lost.store.confirmRestart(reference)
    let state = lost.store.restartProposalState(reference)
    #expect(state.operationID == nil && state.outcome == nil && state.requestUnknown != nil)
    #expect(await lost.transport.count(post) == 1)
    await lost.store.stop()
  }
  @Test func stoppedOrCancelledPollingDiscardsLateResults() async throws {
    let h = try await live("used", operation: "restart-operation")
    let path = try status(h) + "/restart-operation"
    await h.transport.set(path, [.paused])
    let state = h.store.restartProposalState(reference)
    let poll = Task { await h.store.pollRestartProposal(reference) }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.stop()
    poll.cancel()
    await h.transport.release(try response(operation(h, outcome: "success")))
    await poll.value
    #expect(state.outcome == nil)
  }
}

extension ManualStoreClock {
  fileprivate func hasRestartPollSleep() -> Bool {
    waiters.values.contains { $0.deadline == time + 2 }
  }
}
