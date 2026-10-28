// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore

  enum CronRunsFixture {
    static let importedID = "thread-imported-cron"
    static func run(_ sequence: Int = 4) throws -> WebCronRunSummary {
      try AgentSettingsFixture.decode(
        ####"{"runId":"run-sample\####(sequence == 4 ? "" : "-older")","jobId":"sample-digest","sequence":\####(sequence),"trigger":"scheduled","status":"failed","scheduledAt":"2030-01-02T09:00:00Z","orderedAt":"2030-01-02T09:00:00Z","completedAt":"2030-01-02T09:01:00Z","eventCount":2,"fieldsTruncated":["text"],"eventsTruncated":true,"projection":"summary"}"####
      )
    }
    static func message(detail: Bool = false) throws -> WebMessage {
      var message = try AutomationsFixture.message()
      message.parts[0] = try AgentSettingsFixture.decode(
        ####"{"type":"telemetry","event":"cron_run","data":{"runId":"run-sample","jobId":"sample-digest","sequence":4,"status":"failed","trigger":"scheduled","orderedAt":"2030-01-02T09:00:00Z","artifactRunId":"artifact-sample","conversationId":"session-sample","eventCount":2,"activityLoaded":\####(detail),"fieldsTruncated":["text"],"eventsTruncated":true}}"####
      )
      message.parts[1] = try AgentSettingsFixture.decode(
        detail
          ? ####"{"type":"text","text":"### Retained activity\n\nThe sample digest could not finish. The fictional service was unavailable.\n\n- Read sample input\n- Retained partial output\n\nRetry is an explicit operator action."}"####
          : ####"{"type":"text","text":"The fictional digest could not finish. A compact result is available."}"####
      )
      return message
    }
    static func context() throws -> WebCronReplyContextPart {
      try AgentSettingsFixture.decode(
        ####"{"type":"cron-reply-context","schema":"mono-agent.web.cron-reply-context.v1","untrusted":true,"source":{"sourceId":"agent-atlas","jobId":"sample-digest","runId":"run-sample"},"run":{"sequence":4,"trigger":"scheduled","status":"failed","scheduledAt":"2030-01-02T09:00:00Z","orderedAt":"2030-01-02T09:00:00Z","startedAt":"2030-01-02T09:00:03Z","completedAt":"2030-01-02T09:01:00Z","queueDepth":0},"snapshot":{"capturedAt":"2030-01-02T12:00:00Z","kind":"summary","sourceTruncationKnown":true,"sourceFieldsTruncated":["text"],"maxBytes":4096,"originalErrorBytes":80,"retainedErrorBytes":42,"originalResultBytes":640,"retainedResultBytes":120,"truncatedFields":["failure.message","result.text"]},"result":{"text":"### Sample digest\n\nThe fictional service did not respond.\n\n- Partial output retained\n- No follow-up was sent"},"failure":{"code":"sample_unavailable","message":"The fictional service was unavailable."},"prefix":"Imported cron result","rawJson":"{\"jobId\":\"sample-digest\",\"status\":\"failed\"}","rawText":"Fictional imported result"}"####
      )
    }
    static func importedThread() throws -> WebThread {
      var thread = try AutomationsFixture.thread()
      thread.id = importedID
      thread.title = "Reply to sample-digest · Run 4"
      thread.trigger = nil
      thread.canSend = true
      thread.canUpload = true
      return thread
    }
    static func importedMessage() throws -> WebMessage {
      var message = try AutomationsFixture.message()
      message.id = "message-imported-cron"
      message.threadId = importedID
      message.parts = [.cronReplyContext(try context())]
      return message
    }
  }
#endif
