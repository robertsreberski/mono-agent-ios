// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

/// Fictional equivalents of the web runtime's job projection / launch-fold cases.
struct ProcessJobEventsTests {
  private func job(_ state: String = "succeeded") throws -> ProcessJobProjection {
    var value = try sampleJob(state: state)
    value.timestamps.startedAt = "2030-01-02T11:59:00.000Z"
    value.timestamps.completedAt = "2030-01-02T11:59:02.000Z"
    value.durationMs = 2000
    value.exitCode = 0
    return value
  }
  private func message(_ id: String, _ parts: [WebMessagePart], role: String = "assistant") throws
    -> WebMessage
  {
    var value: WebMessage = try decode(
      #"{"id":"sample","threadId":"thread-example","turnId":"turn-example","role":"assistant","parts":[],"attachments":[],"createdAt":"2030-01-02T11:59:00.000Z","updatedAt":"2030-01-02T11:59:02.000Z","status":"complete"}"#
    )
    value.id = id
    value.role = role
    value.parts = parts
    return value
  }
  private func carrier(_ job: ProcessJobProjection) throws -> WebMessage {
    let data = try JSONEncoder().encode(job)
    let part: ProcessJobPart = try decode(
      "{\"type\":\"process-job\",\"job\":" + String(decoding: data, as: UTF8.self) + "}")
    return try message("carrier-" + job.jobId, [.processJob(part)])
  }
  private func launch(_ job: ProcessJobProjection, id: String = "launch") throws -> WebToolCall {
    var call: WebToolCall = try decode(
      #"{"type":"tool-call","toolCallId":"launch","toolName":"Bash","args":{"command":"sample-check","description":"Check fictional samples"},"status":"complete"}"#
    )
    call.toolCallId = id
    call.toolName = job.tool
    call.structuredResult = .object([
      "schema": .string(ProcessJobEvents.receiptSchema), "jobId": .string(job.jobId),
      "tool": .string(job.tool),
      "state": .string(job.timestamps.startedAt == nil ? "queued" : "running"),
      "startedAt": job.timestamps.startedAt.map(JSONValue.string) ?? .null,
      "maxRuntimeMs": .number(1_800_000),
    ])
    return call
  }
  private func project(_ messages: [WebMessage], thread: String? = "thread-example")
    -> ProcessJobEvents.Projection
  {
    ProcessJobEvents.project(messages: messages, threadID: thread)
  }
  @Test func extractsJobOnlyCarriersWithoutMutatingRawMessages() throws {
    let source = try carrier(job())
    let projection = project([source])
    let entries = ProcessJobEvents.entries(for: source, projection: projection)
    #expect(entries.isEmpty)
    #expect(!ProcessJobEvents.visible(source, entries: entries))
    #expect(source.parts.count == 1)
    #expect(projection.jobsByID.count == 1)
  }
  @Test func retainsExceptionalAttributionFailuresAttachmentsAndRichSiblings() throws {
    var source = try carrier(job())
    source.attribution = try decode(
      #"{"requested":{"model":"sample:large"},"disposition":"requested","transitions":[],"retries":[]}"#
    )
    #expect(!ProcessJobEvents.visible(source, entries: []))
    source.attribution?.disposition = "fallback"
    #expect(ProcessJobEvents.visible(source, entries: []))
    source.attribution = nil
    source.status = "failed"
    #expect(ProcessJobEvents.visible(source, entries: []))
    source.status = "complete"
    source.parts.append(.text(.init(text: "The fictional report is ready.")))
    let entries = ProcessJobEvents.entries(for: source, projection: project([source]))
    #expect(entries.count == 1)
    #expect(ProcessJobEvents.visible(source, entries: entries))
  }
  @Test func mergesMonotonicallyWithoutRegressingTerminalFacts() throws {
    let settled = try job()
    var running = settled
    running.state = "running"
    running.timestamps.completedAt = nil
    running.durationMs = nil
    running.exitCode = nil
    let projection = project(try [carrier(running), carrier(settled), carrier(running)])
    #expect(projection.jobsByID[settled.jobId]?.state == "succeeded")
    #expect(projection.jobsByID[settled.jobId]?.durationMs == 2000)
  }
  @Test func dropsBlankAndTransportOnlySiblingsButRetainsVisibleTelemetry() throws {
    var source = try carrier(job())
    source.parts.append(.text(.init(text: "  ")))
    let transport: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"runtime","data":{"kind":"context_usage"}}"#)
    source.parts.append(.telemetry(transport))
    #expect(
      !ProcessJobEvents.visible(
        source, entries: ProcessJobEvents.entries(for: source, projection: project([source]))))
    let compaction: TelemetryPart = try decode(
      #"{"type":"telemetry","event":"context_compaction","data":{}}"#)
    source.parts.append(.telemetry(compaction))
    #expect(
      ProcessJobEvents.visible(
        source, entries: ProcessJobEvents.entries(for: source, projection: project([source]))))
  }
  @Test func attributesStartAndTerminalOnlyToExactReceiptBearingResponse() throws {
    let job = try job()
    let origin = try message("origin", [.toolCall(launch(job))])
    let projection = project(try [origin, carrier(job)])
    let events = try #require(projection.eventsByMessageID[origin.id])
    #expect(events.map(\.phase) == [.started, .terminal])
    #expect(events.map(\.occurredAt) == [job.timestamps.startedAt, job.timestamps.completedAt])
    #expect(events.last?.durationMs == 2000)
    #expect(events.last?.exitCode == 0)
    #expect(projection.eventsByMessageID.count == 1)
  }
  @Test func movesTerminalToChronologicalWakeAndDropsUnknownWake() throws {
    let job = try job()
    let wake: ProcessJobWakePart = try decode(
      #"{"type":"process-job-wake","jobId":"sample-job","deliveryKey":"sample-delivery","disposition":"follow_up"}"#
    )
    let origin = try message("origin", [.toolCall(launch(job))])
    let delivery = try message("wake", [.processJobWake(wake)])
    let projection = project(try [origin, delivery, carrier(job)])
    #expect(projection.eventsByMessageID[origin.id]?.map(\.phase) == [.started])
    let item = try #require(ProcessJobEvents.items(for: delivery, projection: projection).first)
    guard case .jobEvent(let event) = item else {
      Issue.record("Expected terminal event")
      return
    }
    #expect(event.phase == .terminal)
    #expect(event.state == "succeeded")
    #expect(event.toolCallId == wake.deliveryKey)
    #expect(ProcessJobEvents.items(for: delivery, projection: .init()).isEmpty)
  }
  @Test(arguments: [
    "succeeded", "failed", "timed_out", "cancelled", "spawn_failed", "queue_expired", "interrupted",
  ])
  func derivesTerminalWithoutInventingMissingTimes(state: String) throws {
    var job = try job(state)
    job.timestamps.startedAt = nil
    job.timestamps.completedAt = nil
    job.durationMs = nil
    job.exitCode = nil
    let origin = try message("origin", [.toolCall(launch(job))])
    let events = project(try [origin, carrier(job)]).eventsByMessageID[origin.id]
    #expect(events?.count == 1)
    #expect(events?.first?.phase == .terminal)
    #expect(events?.first?.state == state)
    #expect(events?.first?.occurredAt == nil)
  }
  @Test(arguments: ["queued", "starting"])
  func admissionDoesNotInventAStart(state: String) throws {
    var job = try job(state)
    job.timestamps.startedAt = nil
    let origin = try message("origin", [.toolCall(launch(job))])
    #expect(project(try [origin, carrier(job)]).eventsByMessageID.isEmpty)
  }
  @Test func conflictingStartAndContradictoryCompletionAreSuppressed() throws {
    var job = try job()
    job.timestamps.completedAt = "2030-01-02T11:58:00.000Z"
    var call = try launch(job)
    if case .object(var fields) = call.structuredResult {
      fields["startedAt"] = .string("2030-01-02T11:59:01.000Z")
      call.structuredResult = .object(fields)
    }
    let origin = try message("origin", [.toolCall(call)])
    let events = project(try [origin, carrier(job)]).eventsByMessageID[origin.id]
    #expect(events?.count == 1)
    #expect(events?.first?.phase == .terminal)
    #expect(events?.first?.occurredAt == nil)
  }
  @Test func failsClosedForAmbiguousWrongThreadAndLegacyProseClaims() throws {
    let job = try job()
    let first = try message("one", [.toolCall(launch(job))])
    let second = try message("two", [.toolCall(launch(job, id: "other"))])
    #expect(project(try [first, second, carrier(job)]).eventsByMessageID.isEmpty)
    #expect(project(try [first, carrier(job)], thread: "other-thread").eventsByMessageID.isEmpty)
    #expect(project(try [first, carrier(job)], thread: nil).eventsByMessageID.isEmpty)
    var legacy = try launch(job)
    legacy.structuredResult = nil
    legacy.result = .string("Job sample-job started")
    #expect(
      project(try [message("legacy", [.toolCall(legacy)]), carrier(job)]).eventsByMessageID.isEmpty)
    #expect(
      project(try [message("user", [.toolCall(launch(job))], role: "user"), carrier(job)])
        .eventsByMessageID.isEmpty)
  }
  @Test func receiptRequiresExactSchemaKeysToolAndCanonicalTimes() throws {
    let job = try job()
    let call = try launch(job)
    guard case .object(let original) = call.structuredResult else {
      Issue.record("Missing receipt")
      return
    }
    #expect(ProcessJobEvents.receipt(call.structuredResult, containingTool: "Bash") != nil)
    #expect(ProcessJobEvents.receipt(call.structuredResult, containingTool: "Exec") == nil)
    for (key, value) in [
      ("extra", JSONValue.bool(true)), ("startedAt", .string("2030-01-02T11:59:00Z")),
      ("startedAt", .string("2030-02-30T11:59:00.000Z")), ("schema", .string("untrusted")),
      ("maxRuntimeMs", .number(1.5)), ("maxRuntimeMs", .number(0)), ("jobId", .string("   ")),
    ] {
      var fields = original
      fields[key] = value
      #expect(ProcessJobEvents.receipt(.object(fields), containingTool: "Bash") == nil)
    }
    var fields = original
    fields.removeValue(forKey: "startedAt")
    #expect(ProcessJobEvents.receipt(.object(fields), containingTool: "Bash") == nil)
  }
  @Test func conflictingDuplicateReceiptLimitsAreAmbiguous() throws {
    let job = try job()
    let first = try launch(job)
    var second = first
    if case .object(var fields) = second.structuredResult {
      fields["maxRuntimeMs"] = .number(120000)
      second.structuredResult = .object(fields)
    }
    #expect(
      project(try [message("origin", [.toolCall(first), .toolCall(second)]), carrier(job)])
        .eventsByMessageID.isEmpty)
  }
  @Test func foldsCompleteLaunchInputAndRetainsPreviewRepairMetadata() throws {
    let job = try job()
    var call = try launch(job)
    call.argsTruncated = true
    call.argsBytes = 50000
    let origin = try message("origin", [.toolCall(call)])
    let items = ProcessJobEvents.items(
      for: origin, projection: project(try [origin, carrier(job)]))
    #expect(items.count == 2)
    guard case .jobEvent(let started) = items[0] else {
      Issue.record("Launch did not fold")
      return
    }
    #expect(started.launchArgs == call.args)
    #expect(started.launchArgsTruncated == true)
    #expect(started.launchArgsBytes == 50000)
    guard case .jobEvent(let terminal) = items[1] else {
      Issue.record("Missing terminal")
      return
    }
    #expect(terminal.launchArgs == nil)
  }
  @Test func keepsTerminalOnlyFailedAndUnpairedLaunchRows() throws {
    var job = try job()
    job.timestamps.startedAt = nil
    var call = try launch(job)
    var origin = try message("origin", [.toolCall(call)])
    var items = ProcessJobEvents.items(
      for: origin, projection: project(try [origin, carrier(job)]))
    #expect(items.first == .part(.toolCall(call)))
    #expect(items.count == 2)
    job = try self.job()
    call = try launch(job)
    call.status = "failed"
    origin = try message("origin", [.toolCall(call)])
    items = ProcessJobEvents.items(for: origin, projection: project(try [origin, carrier(job)]))
    #expect(items.first == .part(.toolCall(call)))
    #expect(ProcessJobEvents.items(for: origin, projection: .init()) == [.part(.toolCall(call))])
  }
  @Test func sourceIndicesRemainStableWhenEventsAndCarriersChange() throws {
    var job = try job("running")
    let call = try launch(job)
    var source = try carrier(job)
    var ordinary = call
    ordinary.toolCallId = "ordinary"
    ordinary.structuredResult = nil
    source.parts += [.toolCall(call), .text(.init(text: "Interim prose")), .toolCall(ordinary)]
    let before = ProcessJobEvents.entries(for: source, projection: project([source]))
    job.state = "succeeded"
    let after = ProcessJobEvents.entries(
      for: source, projection: project(try [source, carrier(job)]))
    #expect(before.first?.id == "part-1:started")
    #expect(after.first?.id == before.first?.id)
    #expect(after.last?.id == before.last?.id)
  }
  @Test func inlineSteerSuppressesOnlyItsLoadedStandaloneBubbleAndKeepsPendingBelowTurn() throws {
    let steer: SteerPart = try decode(
      #"{"type":"steer","inputId":"input-sample","messageId":"followup","text":"Check the fictional API","receivedAt":"2030-01-02T11:59:01.000Z"}"#
    )
    var user = try message("followup", [.text(.init(text: steer.text))], role: "user")
    user.liveInputStatus = "applied"
    let assistant = try message("assistant", [.steer(steer)])
    #expect(ProcessJobEvents.orderedMessages([user, assistant]).map(\.id) == ["assistant"])
    #expect(ProcessJobEvents.orderedMessages([user]).map(\.id) == ["followup"])
    let pending = try message("assistant", [.text(.init(text: "Work in progress"))])
    #expect(
      ProcessJobEvents.orderedMessages([user, pending]).map(\.id) == ["assistant", "followup"])
  }
  @Test func suppressesOnlyParentCallsActuallyOwnedByAShelfGroup() throws {
    var job = try self.job()
    job.kind = "internal"
    job.tool = "Agent"
    job.instanceId = "sample-helper"
    var call = try launch(job)
    call.toolName = "AgentManage"
    call.structuredResult = nil
    call.args = .object([
      "id": .string("sample-helper"), "message": .string("Review the fictional zones"),
    ])
    let parent = try message("parent", [.toolCall(call)])
    let messages = try [parent, carrier(job)]
    let shelf = JobShelf.items(messages: messages)
    let owned = ProcessJobEvents.shelfOwnedCalls(messages: messages, items: shelf)
    #expect(owned.contains(ProcessJobEvents.callKey(parent.id, call.toolCallId)))
    let entries = ProcessJobEvents.entries(
      for: parent, projection: project(messages), shelfOwnedCalls: owned)
    #expect(entries.isEmpty)
    #expect(!ProcessJobEvents.visible(parent, entries: entries))
    #expect(ProcessJobEvents.entries(for: parent, projection: project(messages)).count == 1)
    #expect(parent.parts == [.toolCall(call)])
  }
  @MainActor @Test func proseArrivingOnAHiddenCarrierPublishesBeforeTheTurnSettles() throws {
    var source = try carrier(job("running"))
    source.status = "running"
    let state = ConversationState(
      .init(thread: try sampleThread(), messages: [source], savedAt: Date()))
    let row = try #require(state.messageStates[source.id])
    #expect(state.transcriptMessageIDs.isEmpty)
    // An ordinary text delta must update visibility, not wait for a job/tool or terminal write.
    state.record.messages[0].parts.append(.text(.init(text: "Live fictional answer")))
    state.pendingMessageIndices = [0]
    state.publishPending()
    #expect(state.transcriptMessageIDs == [source.id])
    #expect(state.messageStates[source.id] === row)
    #expect(row.message.status == "running")
    #expect(row.transcriptEntries.count == 1)
    // A correction which removes that prose must also remove the now-empty presentation row.
    state.record.messages[0].parts.removeLast()
    state.pendingMessageIndices = [0]
    state.publishPending()
    #expect(state.transcriptMessageIDs.isEmpty)
    #expect(row.transcriptEntries.isEmpty)
  }
  @MainActor @Test func heldRowsUpdateWakeAndLaunchTogetherWithoutChangingIdentity() throws {
    let job = try job()
    let origin = try message("origin", [.toolCall(launch(job))])
    let raw = try carrier(job)
    let thread = try sampleThread()
    var record = CachedConversation(thread: thread, messages: [origin, raw], savedAt: Date())
    record.thread.id = "thread-example"
    let state = ConversationState(record)
    let held = try #require(state.messageStates[origin.id])
    #expect(held.transcriptEntries.count == 2)
    #expect(state.transcriptMessageIDs == [origin.id])
    let wake: ProcessJobWakePart = try decode(
      #"{"type":"process-job-wake","jobId":"sample-job","deliveryKey":"sample-delivery","disposition":"follow_up"}"#
    )
    state.record.messages.append(try message("wake", [.processJobWake(wake)]))
    state.publish()
    #expect(state.messageStates[origin.id] === held)
    #expect(held.transcriptEntries.count == 1)
    #expect(state.messageStates["wake"]?.transcriptEntries.count == 1)
    #expect(state.messages.count == 3)
  }
}
