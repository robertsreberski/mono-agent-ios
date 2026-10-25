// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  enum JobFixture {
    static func matches(_ scenario: StoreScenario) -> Bool {
      [.conversationJobs, .conversationJobStack, .conversationSubagents, .conversationContext]
        .contains(scenario)
    }
    static func job(
      _ id: String, state: String = "running", tool: String = "Bash", instance: String? = nil
    ) throws -> ProcessJobProjection {
      var job: ProcessJobProjection = try TranscriptFixture.decode(
        #"{"schema":"mono-agent.process-job.v1","jobId":"sample-job","tool":"Bash","state":"running","summary":"Purpose: Check the sample catalog","origin":{"conversationId":"web:t-atlas-launch","channel":"web","runId":"turn-transcript","historyBoundary":"sample-boundary","bucket":null},"timestamps":{"admittedAt":"2030-01-02T11:58:58Z","queueDeadlineAt":"2030-01-02T12:04:00Z","startedAt":"2030-01-02T11:59:00Z","runtimeDeadlineAt":"2030-01-02T12:29:00Z","completedAt":null},"limits":{"maxRuntimeMs":1800000,"maxOutputBytes":1000000,"previewChars":4096,"chainDepth":0},"output":{"stdoutBytes":104,"stderrBytes":0,"truncated":false,"preview":"STDOUT:\nChecked 12 sample entries\nReady for the next stage","stdoutRef":null,"stderrRef":null},"wake":{"state":"pending","attempts":0,"deliveryKey":"sample-delivery","lastAttemptAt":null},"exitCode":null,"signal":null,"durationMs":null,"cancelRequested":false,"lastError":null}"#
      )
      job.jobId = id
      job.state = state
      job.tool = tool
      if state != "running" {
        job.summary =
          "Purpose: " + state.replacingOccurrences(of: "_", with: " ").capitalized + " sample check"
      }
      if ["queued", "starting", "spawn_failed", "queue_expired"].contains(state) {
        job.timestamps.startedAt = nil
      }
      if !["queued", "starting", "running"].contains(state) {
        job.timestamps.completedAt = "2030-01-02T11:59:30Z"
        job.durationMs = job.timestamps.startedAt == nil ? nil : 30_000
        job.exitCode = state == "succeeded" ? 0 : state == "failed" ? 1 : nil
        job.wake.state = "delivered"
        job.wake.attempts = 1
      }
      if state == "timed_out" {
        job.signal = "SIGKILL"
        job.output.truncated = true
      }
      if state == "cancelled" {
        job.signal = "SIGTERM"
        job.cancelRequested = true
      }
      if let instance {
        job.kind = "internal"
        job.instanceId = instance
        job.childStillBusy = false
        job.summary = "Review the fictional planting plan"
        job.subagentProgress = try TranscriptFixture.decode(
          #"{"revision":3,"profile":"researcher","label":"Compare sample beds","route":{"requested":{"model":"sample:large","effort":"high"},"executed":{"model":"sample:large","effort":"high"},"disposition":"requested"},"toolCalls":5,"failedCalls":1,"costUnknown":true,"knownCostUsd":0.12,"recent":[{"id":"read-a","toolName":"Read","argsSummary":"garden/north.md","status":"complete","executionMs":22},{"id":"read-b","toolName":"Read","argsSummary":"garden/south.md","status":"complete","executionMs":26},{"id":"test-a","toolName":"Bash","argsSummary":"sample-check","workdir":"garden","status":"failed","executionMs":1200},{"id":"test-b","toolName":"Bash","argsSummary":"sample-check --retry","workdir":"garden","status":"running"}],"answerHead":"The sample planting plan has three zones. The north bed needs a second review.","answerTruncated":true}"#
        )
        job.output.preview = ""
        job.output.stdoutBytes = 0
      }
      return job
    }
    static func question(state: String = "awaiting_answer") throws -> PeerProcessJobQuestion {
      var question: PeerProcessJobQuestion = try TranscriptFixture.decode(
        #"{"state":"awaiting_answer","questionId":"sample-peer-question","peer":"seed-bank","thread":"spring-order","message":"Should I reserve the fictional seed packets now or wait for the member vote?","requestedSchema":{"type":"object","properties":{"decision":{"type":"string","enum":["reserve","wait"]}}},"expiresAt":"2030-01-02T12:20:00Z"}"#
      )
      question.state = state
      return question
    }
    static func jobs(_ scenario: StoreScenario) throws -> [ProcessJobProjection] {
      if scenario == .conversationJobs {
        var jobs = try [
          "running", "succeeded", "failed", "cancelled", "timed_out", "queued", "starting",
          "spawn_failed", "queue_expired", "interrupted",
        ].map { try job($0, state: $0) }
        var stopping = try job("stopping")
        stopping.cancelRequested = true
        jobs.append(stopping)
        var wake = try job("wake-failed", state: "succeeded")
        wake.wake.state = "failed"
        wake.wake.attempts = 3
        jobs.append(wake)
        var redacted = try job("redacted", state: "succeeded")
        redacted.summary = "Bash command (content redacted)"
        redacted.output.preview = "(no output)"
        jobs.append(redacted)
        var silent = try job("silent")
        silent.output.preview = ""
        silent.output.stdoutBytes = 0
        jobs.append(silent)
        var large = try job("large-output", state: "succeeded")
        large.output.preview = String(repeating: "Fictional output line.\n", count: 4000)
        large.output.truncated = true
        jobs.append(large)
        var unknown = try job("wake-unknown", state: "succeeded")
        unknown.wake.state = "unknown"
        jobs.append(unknown)
        return jobs
      }
      if scenario == .conversationJobStack {
        var turns = try (0..<6).map {
          try job(
            "turn-\($0)", state: $0 == 5 ? "running" : $0 == 1 ? "failed" : "succeeded",
            tool: $0 <= 1 ? "Agent" : "AgentManage", instance: "garden-helper")
        }
        turns[0].peerQuestion = try question()
        turns[0].tool = "PeerAgent"
        // A different family with the same instance ID must not absorb the child group.
        turns[0].instanceId = "garden-helper"
        return turns + [try job("stack-command")]
      }
      if scenario == .conversationSubagents {
        var active = try job("child-running", tool: "Agent", instance: "bed-planner")
        active.subagentProgress?.answerHead = nil
        var peer = try job(
          "peer-pending", state: "succeeded", tool: "PeerAgent", instance: "seed-bank")
        peer.peerQuestion = try question()
        var answered = try job(
          "peer-answered", state: "succeeded", tool: "PeerAgent", instance: "seed-bank")
        answered.peerQuestion = try question(state: "answered")
        var child = try job(
          "child-question", state: "succeeded", tool: "Agent", instance: "greenhouse")
        child.subagentQuestion = try TranscriptFixture.decode(
          #"{"question":"Should the fictional heater run overnight?","options":["Overnight","Before sunrise"]}"#
        )
        child.wake.state = "pending"
        var busy = try job("child-busy", state: "cancelled", tool: "Agent", instance: "inventory")
        busy.childStillBusy = true
        var expired = answered
        expired.jobId = "peer-expired"
        expired.peerQuestion?.state = "expired"
        var failed = peer
        failed.jobId = "peer-failed-pending"
        failed.state = "failed"
        failed.instanceId = "sample-failed-peer"
        var cancelled = peer
        cancelled.jobId = "peer-cancelled-pending"
        cancelled.state = "cancelled"
        cancelled.instanceId = "sample-cancelled-peer"
        var unavailable = try job(
          "child-unavailable", state: "succeeded", tool: "AgentSend", instance: "retained-helper")
        unavailable.subagentProgress = nil
        return [active, peer, answered, expired, child, busy, failed, cancelled, unavailable]
      }
      return []
    }
    static func activity(_ scenario: StoreScenario) throws -> WebJobActivity {
      let jobs = try jobs(scenario)
      return try TranscriptFixture.decode(
        "{\"queued\":\(jobs.filter { $0.state == "queued" }.count),\"starting\":\(jobs.filter { $0.state == "starting" }.count),\"running\":\(jobs.filter { $0.state == "running" }.count)}"
      )
    }
    static func messages(_ scenario: StoreScenario) throws -> [WebMessage] {
      var message = try TranscriptFixture.message(
        id: "activity-sample", role: "assistant",
        text:
          "Synthetic background activity. Open Background jobs in the header to inspect the retained cards."
      )
      message.parts += try jobs(scenario).map { job in
        let part: ProcessJobPart = try TranscriptFixture.decode(
          #"{"type":"process-job","job":\#(String(decoding: JSONEncoder().encode(job), as: UTF8.self))}"#
        )
        return .processJob(part)
      }
      if scenario == .conversationContext {
        let telemetry: TelemetryPart = try TranscriptFixture.decode(
          #"{"type":"telemetry","event":"runtime","data":{"kind":"context_usage","data":{"total":84000,"contextWindow":200000,"model":"sample:large"}}}"#
        )
        message.parts = [
          .text(.init(text: "Context and cost for a fictional conversation.")),
          .telemetry(telemetry),
        ]
      }
      if scenario == .conversationJobStack {
        let call: WebToolCall = try TranscriptFixture.decode(
          #"{"type":"tool-call","toolCallId":"launch-garden-helper","toolName":"Agent","args":{"id":"garden-helper","prompt":"Review the sample planting plan","persist":true,"background":true},"structuredResult":{"schema":"mono-agent.process-job-start-receipt.v1","jobId":"turn-1","tool":"Agent","state":"running","startedAt":"2030-01-02T11:59:00Z"},"status":"complete"}"#
        )
        message.parts.insert(.toolCall(call), at: 0)
        // A tall code backdrop exercises the floating shelf/composer over busy web content.
        let code = String(repeating: "let sample = 42 // Fictional planting zone\n", count: 80)
        message.parts.append(.text(.init(text: "## Sample code\n```swift\n" + code + "```")))
      }
      if scenario == .conversationSubagents {
        for status in ["running", "complete", "failed"] {
          var call = try TranscriptFixture.tool(1, full: true)
          call.type = "subagent"
          call.toolCallId = "delegation-" + status
          call.name = "researcher"
          call.toolName = "Agent"
          call.label = "Review sample zones · " + status
          call.status = status
          call.args = .object(["prompt": .string("Compare the fictional planting zones.")])
          call.result = status == "running" ? nil : .string("Three sample zones reviewed.")
          call.attribution = try TranscriptFixture.decode(
            #"{"requested":{"model":"sample:large","effort":"high"},"executed":{"model":"sample:large","effort":"high"},"disposition":"requested","transitions":[],"retries":[]}"#
          )
          call.calls = [
            try TranscriptFixture.tool(1, full: true), try TranscriptFixture.tool(2, full: true),
          ]
          message.parts.append(.subagent(call))
        }
      }
      return [message]
    }
    static func usage() throws -> WebThreadUsage {
      try TranscriptFixture.decode(
        #"{"total":{"tokens":{"input":12000,"cacheWrite":2000,"cacheRead":70000,"output":1200},"costUnknown":true,"knownCostUsd":0.42,"tokensPartial":true},"subagents":{"tokens":{"input":2000,"cacheWrite":0,"cacheRead":1000,"output":200},"costUsd":0.12,"tokensPartial":true,"runs":3,"runsWithTokens":2},"byModel":[{"model":"sample:large","costUnknown":true,"knownCostUsd":0.3},{"model":"sample:small","costUsd":0.12}],"computedAt":"2030-01-02T12:00:00Z","settledAssistantTurns":3}"#
      )
    }
  }
#endif
