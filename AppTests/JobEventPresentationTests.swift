// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

struct JobEventPresentationTests {
  @MainActor @Test func openBandSurvivesAnOrdinaryLaunchFoldingAfterAJobRefresh() throws {
    var job = try JobFixture.job("sample-transition", state: "queued")
    var source = try TranscriptFixture.message(id: "launch", role: "assistant", text: "")
    job.origin.conversationId = "web:" + source.threadId
    var call = try TranscriptFixture.tool(1, full: true)
    call.toolName = job.tool
    call.status = "complete"
    call.structuredResult = .object([
      "schema": .string(ProcessJobEvents.receiptSchema), "jobId": .string(job.jobId),
      "tool": .string(job.tool), "state": .string("queued"), "startedAt": .null,
    ])
    source.parts = [.toolCall(call)]
    func entries(_ job: ProcessJobProjection) throws -> [TranscriptEntry] {
      let part: ProcessJobPart = try TranscriptFixture.decode(
        "{\"type\":\"process-job\",\"job\":"
          + String(decoding: JSONEncoder().encode(job), as: UTF8.self) + "}")
      var carrier = source
      carrier.id = "carrier"
      carrier.parts = [.processJob(part)]
      let projection = ProcessJobEvents.project(
        messages: [source, carrier], threadID: source.threadId)
      return ProcessJobEvents.entries(for: source, projection: projection)
    }
    let before = try entries(job)
    let beforeBand = try #require(TranscriptPresentation.activityBands(before).first)
    let disclosures = TranscriptDisclosures()
    let key = source.id + "#band-" + beforeBand.id
    disclosures.choose(key, open: true, running: false)
    #expect(before.first?.id == "part-0")
    job.state = "running"
    job.timestamps.startedAt = "2030-01-02T11:59:00.000Z"
    let after = try entries(job)
    #expect(after.first?.id == "part-0:started")
    let afterBand = try #require(TranscriptPresentation.activityBands(after).first)
    #expect(beforeBand.id == afterBand.id)
    #expect(disclosures.isOpen(source.id + "#band-" + afterBand.id, running: false))
  }
}
