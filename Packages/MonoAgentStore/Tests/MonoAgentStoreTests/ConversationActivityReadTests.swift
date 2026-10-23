// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor struct ConversationActivityReadTests {
  private let jobPath = "/api/v1/threads/thread-example/jobs/sample-job"
  private let usagePath = "/api/v1/threads/thread-example/usage"
  private func live() async throws -> Harness {
    let h = Harness()
    await h.transport.set("/api/v1/bootstrap", [.response(Scenario.bootstrap)])
    await h.store.start()
    var message = try sampleMessage()
    let job = try sampleJob()
    let part: ProcessJobPart = try JSONDecoder().decode(
      ProcessJobPart.self,
      from: JSONEncoder().encode(
        JSONValue.object([
          "type": .string("process-job"),
          "job": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(job)),
        ])))
    message.parts = [.processJob(part)]
    try h.seed(messages: [message])
    return h
  }
  private func jobResponse(_ job: ProcessJobProjection) throws -> HTTPResponse {
    try response(
      JSONValue.object([
        "job": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(job))
      ]))
  }
  private func usageResponse() throws -> HTTPResponse {
    try response(
      JSONValue.object([
        "usage": .object([
          "total": .object(["costUnknown": .bool(true)]), "byModel": .array([]),
          "computedAt": .string("2030-01-02T12:00:00Z"),
        ])
      ]))
  }
  @Test func exactJobReadPublishesMonotonicProjectionAndUsageRemainsUnknown() async throws {
    let h = try await live()
    var job = try sampleJob(state: "succeeded")
    job.durationMs = 1200
    await h.transport.set(
      jobPath, [.response(try jobResponse(job)), .response(try jobResponse(sampleJob()))])
    #expect(try await h.store.refreshJob(threadID: "thread-example", jobID: "sample-job"))
    #expect(!(try await h.store.refreshJob(threadID: "thread-example", jobID: "sample-job")))
    let state = try #require(h.store.conversations["thread-example"])
    #expect(JobShelf.items(messages: state.messages).first?.newest.state == "succeeded")
    #expect(await h.transport.count(jobPath, method: "GET") == 2)
    await h.transport.set(usagePath, [.response(try usageResponse())])
    #expect(try await h.store.refreshUsage(threadID: "thread-example"))
    #expect(state.usage?.total.costUnknown == true)
    #expect(state.usageRevision == state.thread.revision)
    #expect(await h.transport.count(usagePath, method: "GET") == 1)
    await h.store.stop()
  }
  @Test func unavailableStoresMakeNoActivityRequests() async throws {
    let h = Harness()
    await h.store.hydrate()
    await #expect(throws: ConversationActivityReadError.unavailable) {
      try await h.store.refreshJob(threadID: "thread-example", jobID: "sample-job")
    }
    let live = try await live()
    await live.store.scenePhaseChanged(.background)
    await #expect(throws: ConversationActivityReadError.unavailable) {
      try await live.store.refreshUsage(threadID: "thread-example")
    }
    #expect(await h.transport.count(jobPath) == 0)
    #expect(await live.transport.count(usagePath) == 0)
    await live.store.stop()
  }
  @Test func lateJobAfterStopAndUsageAfterNewRevisionAreDiscarded() async throws {
    let h = try await live()
    await h.transport.set(jobPath, [.paused])
    let read = Task {
      try await h.store.refreshJob(threadID: "thread-example", jobID: "sample-job")
    }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.stop()
    await h.transport.release(try jobResponse(sampleJob(state: "succeeded")))
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(
      JobShelf.items(messages: h.store.conversations["thread-example"]?.messages ?? []).first?
        .newest.state == "running")
    let next = try await live()
    await next.transport.set(usagePath, [.paused])
    let usage = Task { try await next.store.refreshUsage(threadID: "thread-example") }
    await eventually { await next.transport.pauseCount() == 1 }
    next.store.conversations["thread-example"]?.thread.revision += 1
    await next.transport.release(try usageResponse())
    await #expect(throws: CancellationError.self) { try await usage.value }
    #expect(next.store.conversations["thread-example"]?.usage == nil)
    await next.store.stop()
  }
  @Test func mismatchedJobIdentityCannotPatchHeldTranscript() async throws {
    let h = try await live()
    await h.transport.set(jobPath, [.response(try jobResponse(sampleJob("wrong")))])
    await #expect(throws: ConversationActivityReadError.identityMismatch) {
      try await h.store.refreshJob(threadID: "thread-example", jobID: "sample-job")
    }
    #expect(
      JobShelf.items(messages: h.store.conversations["thread-example"]?.messages ?? []).first?
        .newest.jobId == "sample-job")
    await h.store.stop()
  }
}
