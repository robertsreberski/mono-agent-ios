// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct AgentRestartTests {
  let source = "agent-example"
  var path: String { "/api/v1/agents/\(source)/restart" }
  func operation(_ id: String = "restart-new", outcome: String? = nil) throws
    -> WebAgentRestartOperation
  {
    var value: WebAgentRestartOperation = try decode(
      #"{"id":"\#(id)","sourceId":"agent-example","stage":"restarting","requestedAt":"2030-01-02T12:00:00Z","deadline":"2030-01-02T12:02:00Z"}"#
    )
    value.outcome = outcome
    if outcome == "success" { value.stage = "back_online" }
    return value
  }
  func latest(_ operation: WebAgentRestartOperation? = nil) throws -> HTTPResponse {
    let value =
      try operation.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
      ?? .null
    return try response(JSONValue.object(["operation": value]))
  }
  func live(_ initial: WebAgentRestartOperation? = nil) async throws -> Harness {
    let h = try await AgentSettingsTests().live()
    h.store.bootstrap?.agents[0].restart = try decode(#"{"supported":true}"#)
    await h.transport.set(path, [.response(try latest(initial))])
    h.store.openAgentRestart(sourceID: source)
    await h.store.agentRestartState(source).latestTask?.value
    return h
  }
  func confirm(_ h: Harness) {
    h.store.requestAgentRestartConfirmation(sourceID: source)
    h.store.confirmAgentRestart(sourceID: source)
  }
  @Test func openingAndCancellingOnlyReadAndEveryPostNeedsConfirmation() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    #expect(state.readState == .ready && state.operation == nil)
    h.store.confirmAgentRestart(sourceID: source)
    h.store.requestAgentRestartConfirmation(sourceID: source)
    #expect(state.confirming)
    h.store.cancelAgentRestartConfirmation(sourceID: source)
    h.store.confirmAgentRestart(sourceID: source)
    #expect(await h.transport.count(path, method: "POST") == 0)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test func singleAdmissionAndGenerationChangeDoNotInvalidateOperation() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    await h.transport.set(path, [.response(try latest()), .paused])
    await h.transport.set(path + "/restart-new", [.paused])
    confirm(h)
    h.store.confirmAgentRestart(sourceID: source)
    await eventually { await h.transport.pauseCount() == 1 }
    let admission = state.admission
    h.store.bootstrap?.agents[0].generation = "replacement-process"
    h.store.reconcileAgentRestarts()
    await h.transport.release(try response(try operation()))
    await admission?.value
    #expect(state.operation?.id == "restart-new")
    #expect(await h.transport.count(path, method: "POST") == 1)
    await eventually { await h.transport.pauseCount() == 1 }
    let poll = state.poll
    await h.transport.release(try response(try operation(outcome: "success")))
    await poll?.value
    #expect(state.outcome == "success" && state.notice?.contains("succeeded") == true)
    #expect(state.restartedThisVisit)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test(arguments: ["old", "empty", "unknown", "same"])
  func ambiguousRecoveryOnlyAdoptsDifferentIDWithKnownBaseline(_ baseline: String) async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    let before: RouteTransport.Reply =
      baseline == "unknown"
      ? .failure
      : .response(
        try latest(baseline == "empty" ? nil : operation("restart-old", outcome: "success")))
    let after = try operation(
      baseline == "same" ? "restart-old" : "restart-new", outcome: "success")
    await h.transport.set(path, [before, .failure, .response(try latest(after))])
    confirm(h)
    await state.admission?.value
    let adopted = baseline == "old" || baseline == "empty"
    #expect((state.operation?.id == after.id) == adopted)
    #expect((state.requestUnknown != nil) == !adopted)
    #expect(state.requestFailure == nil)
    #expect(await h.transport.count(path, method: "POST") == 1)
    #expect(state.notice != nil)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test func definitiveRefusalIsAnnouncedAndDoesNotReadOrRetryAutomatically() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    await h.transport.set(
      path, [.response(try latest()), .response(.init(data: Data(), status: 409))])
    confirm(h)
    await state.admission?.value
    #expect(state.outcome == "failure" && state.requestUnknown == nil)
    #expect(state.notice?.contains("failed") == true)
    h.store.confirmAgentRestart(sourceID: source)
    #expect(await h.transport.count(path, method: "POST") == 1)
    #expect(await h.transport.count(path, method: "GET") == 2)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test(arguments: ["capability", "offline", "background", "close", "generation"])
  func prePostBaselineSuspensionRevalidatesAdmission(_ change: String) async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    await h.transport.set(path, [.paused])
    confirm(h)
    let admission = state.admission
    await eventually { await h.transport.pauseCount() == 1 }
    switch change {
    case "capability": h.store.bootstrap?.agents[0].restart?.supported = false
    case "offline": h.store.connection = .offline
    case "background": await h.store.scenePhaseChanged(.background)
    case "close": h.store.closeAgentRestart(sourceID: source)
    default: h.store.bootstrap?.agents[0].generation = "next-process"
    }
    await h.transport.release(try latest())
    await admission?.value
    #expect(await h.transport.count(path, method: "POST") == 0)
    #expect(!state.requesting && state.operation == nil)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test func knownOperationGetsImmediatelyThenEveryTwoSecondsAndReadFailureIsOnlyWarning()
    async throws
  {
    let h = try await live(try operation())
    let state = h.store.agentRestartState(source)
    // The opening GET is immediate (the default unscripted transport fails closed).
    await eventually {
      let sleeping = await h.clock.hasSleep(2)
      return state.pollWarning != nil && sleeping
    }
    #expect(await h.transport.count(path + "/restart-new") == 1)
    #expect(state.outcome == nil)
    await h.transport.set(
      path + "/restart-new", [.response(try response(try operation(outcome: "not_confirmed")))])
    let poll = state.poll
    await h.clock.advance(2)
    await poll?.value
    #expect(state.outcome == "not_confirmed" && state.pollWarning == nil)
    #expect(state.notice?.contains("not confirmed") == true)
    #expect(await h.transport.count(path, method: "POST") == 0)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test func backgroundCancelsPollDiscardsLateResponseAndForegroundResumesByID() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    state.operation = try operation()
    await h.transport.set(path + "/restart-new", [.paused])
    h.store.resumeAgentRestart(state)
    await eventually { await h.transport.pauseCount() == 1 }
    let oldPoll = state.poll
    await h.store.scenePhaseChanged(.background)
    await h.transport.release(try response(try operation(outcome: "failure")))
    await oldPoll?.value
    #expect(state.outcome == nil)
    // Model the stream-ready transition used by scene foreground, without a live stream.
    h.store.backgrounded = false
    h.store.connection = .live
    await h.transport.set(
      path + "/restart-new", [.response(try response(try operation(outcome: "success")))])
    h.store.resumeAgentRestart(state)
    await state.poll?.value
    #expect(state.outcome == "success")
    #expect(await h.transport.count(path, method: "POST") == 0)
    h.store.closeAgentRestart(sourceID: source)
  }
  @Test func closeAndReopenRejectsLateLatestAndAdmission() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    await h.transport.set(path, [.response(try latest()), .paused])
    confirm(h)
    let admission = state.admission
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.closeAgentRestart(sourceID: source)
    h.store.openAgentRestart(sourceID: source)
    await h.transport.release(try response(try operation(outcome: "success")))
    await admission?.value
    #expect(state.operation == nil && state.resumeID == nil)
    h.store.closeAgentRestart(sourceID: source)
    await h.transport.set(path, [.paused])
    h.store.openAgentRestart(sourceID: source)
    let latestTask = state.latestTask
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.closeAgentRestart(sourceID: source)
    await h.transport.release(try latest(try operation(outcome: "failure")))
    await latestTask?.value
    #expect(state.operation == nil)
  }
  @Test func initialReadFailureCanRetryWithoutPosting() async throws {
    let h = try await live()
    let state = h.store.agentRestartState(source)
    await h.transport.set(path, [.failure, .response(try latest())])
    h.store.loadLatestAgentRestart(sourceID: source)
    await state.latestTask?.value
    #expect(state.readState == .error && state.notice != nil)
    h.store.requestAgentRestartConfirmation(sourceID: source)
    #expect(!state.confirming)
    h.store.loadLatestAgentRestart(sourceID: source)
    await state.latestTask?.value
    #expect(state.readState == .ready)
    #expect(await h.transport.count(path, method: "POST") == 0)
    h.store.closeAgentRestart(sourceID: source)
  }
}

extension ManualStoreClock {
  fileprivate func hasSleep(_ seconds: TimeInterval) -> Bool {
    waiters.values.contains { $0.deadline == time + seconds }
  }
}
