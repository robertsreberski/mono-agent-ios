// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

func sampleJob(_ id: String = "sample-job", state: String = "running", instance: String? = nil)
  throws -> ProcessJobProjection
{
  var job: ProcessJobProjection = try decode(
    #"{"schema":"mono-agent.process-job.v1","jobId":"sample-job","tool":"Bash","state":"running","summary":"Purpose: Check samples","origin":{"conversationId":"web:thread-example","channel":"web","runId":"sample-run","historyBoundary":"sample-boundary","bucket":null},"timestamps":{"admittedAt":"2030-01-02T11:58:58Z","queueDeadlineAt":"2030-01-02T12:04:00Z","startedAt":"2030-01-02T11:59:00Z","runtimeDeadlineAt":null,"completedAt":null},"limits":{"maxRuntimeMs":1800000,"maxOutputBytes":1000000,"previewChars":4096,"chainDepth":0},"output":{"stdoutBytes":1,"stderrBytes":0,"truncated":false,"preview":"a","stdoutRef":null,"stderrRef":null},"wake":{"state":"pending","attempts":0,"deliveryKey":"sample-delivery","lastAttemptAt":null},"exitCode":null,"signal":null,"durationMs":null,"cancelRequested":false,"lastError":null}"#
  )
  job.jobId = id
  job.state = state
  if let instance {
    job.kind = "internal"
    job.tool = "Agent"
    job.instanceId = instance
  }
  return job
}
func sampleQuestion() throws -> PeerProcessJobQuestion {
  try decode(
    #"{"state":"awaiting_answer","questionId":"sample-question","peer":"sample-peer","thread":"sample-thread","message":"Which sample?","requestedSchema":{},"expiresAt":"2030-01-02T12:01:00Z"}"#
  )
}
struct JobPresentationTests {
  let now = Date(timeIntervalSince1970: 1_893_585_600)
  @Test func everyStateHasNonColorSemanticsAndOverridesAreHonest() throws {
    let states = [
      "queued", "starting", "running", "succeeded", "failed", "cancelled", "interrupted",
      "timed_out", "spawn_failed", "queue_expired",
    ]
    let labels = [
      "Queued", "Starting", "Running", "Done", "Failed", "Cancelled", "Interrupted", "Timed out",
      "Failed to start", "Expired in queue",
    ]
    for (state, label) in zip(states, labels) {
      let job = try sampleJob(state: state)
      let face = JobPresentation.status(job, now: now)
      #expect(face.label == label)
      #expect(!face.symbol.isEmpty)
      #expect(JobPresentation.terminal(job) == !["queued", "starting", "running"].contains(state))
    }
    var job = try sampleJob()
    job.cancelRequested = true
    #expect(JobPresentation.status(job, now: now).label == "Stopping")
    job.state = "succeeded"
    job.peerQuestion = try sampleQuestion()
    #expect(JobPresentation.status(job, now: now).label == "Question pending")
    #expect(!JobPresentation.pending(job, now: now.addingTimeInterval(60)))
    job.peerQuestion?.state = "answered"
    #expect(JobPresentation.status(job, now: now).label == "Done")
    #expect(JobPresentation.title(job) == "Check samples")
  }
  @Test func clockUsesServerSnapshotAndTerminalFactsWithoutInventingRuntime() throws {
    var job = try sampleJob()
    #expect(JobPresentation.elapsed(job, now: now) == 60_000)
    #expect(JobPresentation.elapsed(job, now: now.addingTimeInterval(10)) == 70_000)
    job.state = "succeeded"
    job.durationMs = 1234
    #expect(JobPresentation.elapsed(job, now: .distantFuture) == 1234)
    job.durationMs = nil
    job.timestamps.completedAt = "2030-01-02T11:59:30.000Z"
    #expect(JobPresentation.elapsed(job, now: .distantFuture) == 30_000)
    job.timestamps.startedAt = nil
    #expect(JobPresentation.elapsed(job, now: now) == nil)
    #expect(JobPresentation.duration(nil) == "Unknown duration")
    #expect(JobPresentation.duration(.nan) == "Unknown duration")
    #expect(JobPresentation.duration(-1) == "Unknown duration")
    #expect(JobPresentation.duration(42) == "42ms")
    #expect(JobPresentation.duration(1234) == "1.2s")
    #expect(JobPresentation.duration(61_000) == "1m 1s")
    #expect(JobPresentation.duration(3_661_000) == "1h 1m")
    #expect(!JobPresentation.duration(1e100).isEmpty)
  }
  @Test func previewIsBoundedRedactedAndNeverExecutesTerminalControls() {
    let preview = JobPresentation.preview(
      "\u{1B}[31mAuthorization: Bearer fictional-token\napi_key=fictional-key password=fictional-password https://sample:credential@example.com",
      limit: 1024)
    #expect(!preview.text.contains("fictional-token"))
    #expect(!preview.text.contains("fictional-key"))
    #expect(!preview.text.contains("fictional-password"))
    #expect(!preview.text.contains("credential"))
    #expect(!preview.text.contains("\u{1B}"))
    #expect(!preview.bounded)
    let json = JobPresentation.preview(
      #"{"api_key":"fictional-json-key"} https://example.com/log?signature=fictional-signature&sample=yes"#
    )
    #expect(!json.text.contains("fictional-json-key"))
    #expect(!json.text.contains("fictional-signature"))
    #expect(JobPresentation.preview(String(repeating: "é", count: 3000)).bounded)
    #expect(JobPresentation.preview("sample", limit: 0).text.isEmpty)
    #expect(JobPresentation.preview("(no output)").text == "(no output)")
  }
  @Test func slowPollCannotRegressLifecycleOutputOrIdentity() throws {
    var job = try sampleJob()
    var next = job
    next.state = "succeeded"
    next.durationMs = 1000
    next.exitCode = 0
    job = JobPresentation.merge(job, next)
    next.state = "running"
    next.durationMs = nil
    #expect(JobPresentation.merge(job, next) == job)
    next = job
    next.summary = "Different immutable purpose"
    #expect(JobPresentation.merge(job, next) == job)
    next = job
    next.output.stdoutBytes = 0
    next.output.preview = ""
    #expect(JobPresentation.merge(job, next).output == job.output)
    next = job
    next.durationMs = nil
    next.exitCode = nil
    #expect(JobPresentation.merge(job, next).durationMs == 1000)
    #expect(JobPresentation.merge(job, next).exitCode == 0)
  }
  @Test func groupsCountOnceNewestOutcomeWinsAndPendingQuestionsStayVisible() throws {
    let old = try sampleJob("old", state: "failed", instance: "helper")
    var question = try sampleJob("question", state: "succeeded", instance: "helper")
    question.peerQuestion = try sampleQuestion()
    let current = try sampleJob("new", instance: "helper")
    let command = try sampleJob("command", state: "cancelled")
    var peer = try sampleJob("peer", state: "succeeded", instance: "helper")
    peer.tool = "PeerAgent"
    let items = JobShelf.items(jobs: [old, command, question, current, peer])
    #expect(items.map(\.id) == ["command", "agent:helper", "peer:helper"])
    #expect(items[1].lead(now: now).jobId == "question")
    #expect(items[1].bucket(now: now) == .question)
    #expect(items[1].bucket(now: now.addingTimeInterval(61)) == .active)
    let counts = JobShelf.counts(items, now: now)
    #expect(counts.values.reduce(0, +) == items.count)
    #expect(counts[.cancelled] == 1)
    #expect(
      JobShelf.items(jobs: [old, question])[0].bucket(now: now.addingTimeInterval(61)) == .done)
    let more = try (0..<4).map { try sampleJob("more-\($0)", instance: "helper") }
    let many = JobShelf.items(jobs: [old, question] + more)[0]
    #expect(many.visibleJobs(unfolded: false, now: now).contains(where: { $0.jobId == "question" }))
    #expect(many.visibleJobs(unfolded: true, now: now).count == 6)
    var wake = command
    wake.state = "succeeded"
    wake.wake.state = "failed"
    #expect(JobShelf.items(jobs: [wake])[0].bucket(now: now) == .issue)
  }
  @Test func parentCallsRemainInChildTimelineAndDoNotLeakAcrossFamilies() throws {
    let job = try sampleJob("launched", instance: "helper")
    var message = try sampleMessage()
    let call: WebToolCall = try decode(
      #"{"toolCallId":"launch","toolName":"Agent","args":{"id":"helper","prompt":"A fictional brief"},"status":"complete","structuredResult":{"schema":"mono-agent.process-job-start-receipt.v1","jobId":"launched","tool":"Agent","state":"running","startedAt":"2030-01-02T11:59:00Z"}}"#
    )
    message.parts = [.toolCall(call)]
    let item = JobShelf.items(jobs: [job])[0]
    let steps = JobShelf.timeline(item, messages: [message])
    #expect(steps.map(\.id) == ["call:message-example:launch", "turn:launched"])
    var peer = job
    peer.tool = "PeerAgent"
    #expect(JobShelf.timeline(JobShelf.items(jobs: [peer])[0], messages: [message]).count == 1)
  }
  @Test func longGroupsFoldParentCallsButPinPendingQuestionsAndDoNotInventClose() throws {
    var jobs = try (0..<6).map {
      try sampleJob("turn-\($0)", state: "succeeded", instance: "helper")
    }
    jobs[0].peerQuestion = try sampleQuestion()
    let item = JobShelf.items(jobs: jobs)[0]
    let visible = JobShelf.visibleSteps(item, messages: [], unfolded: false, now: now)
    #expect(visible.map(\.id) == ["turn:turn-0", "turn:turn-4", "turn:turn-5"])
    #expect(JobShelf.visibleSteps(item, messages: [], unfolded: true, now: now).count == 6)
    var message = try sampleMessage()
    message.createdAt = "2030-01-02T12:02:00Z"
    var call: WebToolCall = try decode(
      #"{"toolCallId":"close","toolName":"AgentManage","args":{"id":"helper","close":true},"status":"complete","result":"Requested closure"}"#
    )
    message.parts = [.toolCall(call)]
    #expect(!JobShelf.closed(item, messages: [message]))
    call.result = .string("<subagent: sample · instance helper · turn 3 · closed>")
    message.parts = [.toolCall(call)]
    #expect(JobShelf.closed(item, messages: [message]))
    var generic = jobs[0]
    generic.summary = "Persistent subagent helper"
    call.args = .object(["id": .string("helper"), "message": .string("A fictional follow-up task")])
    message.parts = [.toolCall(call)]
    #expect(
      JobShelf.purpose(JobShelf.items(jobs: [generic])[0], messages: [message])
        == "A fictional follow-up task")
    #expect(JobShelf.items(jobs: [jobs[0], jobs[0]])[0].jobs.count == 1)
  }

}
