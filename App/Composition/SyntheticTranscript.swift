// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore

  /// Fictional, fail-closed transcript scenarios. No contract resources ship in the app.
  enum TranscriptFixture {
    static let markdown = """
      ## A small release
      **Ready** for review, with _native_ text and `inline code`.
      - [x] Read the sample
      - [ ] Publish the draft

      | Item | Status |
      | --- | --- |
      | iPhone | Ready |
      | iPad | Ready |

      > Keep the content readable.

      ```swift
      let greeting = "Hello, sample!"
      print(greeting)
      ```
      [Documentation](https://example.com)
      """
    static func decode<T: Decodable>(_ text: String, as: T.Type = T.self) throws -> T {
      try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    static func thread(_ scenario: StoreScenario) throws -> WebThread {
      var thread = try DashboardFixture.allThreads().first {
        $0.id == DashboardFixture.openThreadID
      }!
      thread.title = "Native transcript sample"
      thread.runModel = "sample:large"
      thread.runEffort = "high"
      thread.runState = try decode(
        #"{"id":"turn-transcript","status":"running","model":"sample:large","effort":"high","startedAt":"2030-01-02T11:59:00Z"}"#
      )
      if scenario != .conversationStreaming { thread.runState.status = "complete" }
      if JobFixture.matches(scenario) { thread.jobActivity = try JobFixture.activity(scenario) }
      thread.messageCount = scenario == .conversationLong ? 540 : 2
      return thread
    }
    static func message(id: String, role: String, text: String, turn: String = "turn-transcript")
      throws -> WebMessage
    {
      var message: WebMessage = try decode(
        #"{"id":"sample","threadId":"t-atlas-launch","turnId":"turn-transcript","role":"assistant","parts":[],"attachments":[],"createdAt":"2030-01-02T11:59:00Z","updatedAt":"2030-01-02T11:59:30Z","finishedAt":"2030-01-02T11:59:30Z","status":"complete","seq":1}"#
      )
      message.id = id
      message.role = role
      message.turnId = turn
      message.parts = [.text(.init(text: text))]
      return message
    }
    static func tool(_ index: Int, full: Bool = false) throws -> WebToolCall {
      var call: WebToolCall = try decode(
        #"{"type":"tool-call","toolCallId":"sample","toolName":"read_file","args":{"file_path":"docs/sample.md"},"result":"Preview of the synthetic output","status":"complete","executionMs":42,"argsDigest":"args-sample","resultDigest":"result-sample","resultTruncated":true,"resultBytes":24000}"#
      )
      call.toolCallId = "sample-tool-\(index)"
      if index == 2 {
        call.status = "failed"
        call.result = .string("Fictional file was unavailable")
      }
      if full {
        call.resultTruncated = false
        call.result = .string(
          "Full synthetic output loaded\n"
            + String(repeating: "Sample line of output.\n", count: 4))
      }
      return call
    }
    static func messages(_ scenario: StoreScenario, older: Bool = false) throws -> [WebMessage] {
      if scenario == .conversationReplyFiles { return try RichReplyFixture.files() }
      if JobFixture.matches(scenario) { return try JobFixture.messages(scenario) }
      if scenario == .conversationLong {
        return try (older ? 0..<40 : 40..<540).map { index in
          var row = try message(
            id: "long-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
            text:
              "Sample message \(index) · A fictional field note for the scrolling performance fixture.",
            turn: "turn-\(index / 2)")
          if index % 100 == 1 {
            var call = try tool(index, full: true)
            call.result = .string(String(repeating: "Large synthetic output line.\n", count: 2000))
            row.parts.insert(.toolCall(call), at: 0)
          }
          return row
        }
      }
      let user = try message(
        id: "sample-user", role: "user", text: "Please review the sample release.")
      var assistant = try message(
        id: "sample-assistant", role: "assistant",
        text: "The sample is ready. **Two checks** passed; one fictional file needs attention.")
      switch scenario {
      case .conversationMarkdown: assistant.parts = [.text(.init(text: markdown))]
      case .conversationTools:
        assistant.parts = [
          .toolCall(try tool(1)), .toolCall(try tool(2)),
          .text(.init(text: "Reviewed two sample files.")),
        ]
      case .conversationStreaming:
        assistant.status = "running"
        assistant.finishedAt = nil
        assistant.parts = [
          .reasoning(.init(type: "reasoning", text: "Checking the synthetic release checklist…")),
          .text(.init(text: "Live sample")),
        ]
      default:
        let marker: WebConversationMarkerPart = try decode(
          #"{"type":"conversation-marker","at":"2030-01-02T11:59:00Z","kind":"model","before":{"model":"sample:small","effort":"low"},"after":{"model":"sample:large","effort":"high"}}"#
        )
        assistant.parts =
          [
            .conversationMarker(marker),
            .reasoning(
              .init(
                type: "reasoning", text: "I compared the fictional checklist with the sample files."
              )), .toolCall(try tool(1)), .toolCall(try tool(2)),
          ] + assistant.parts
        assistant.attribution = try decode(
          #"{"requested":{"model":"sample:small","effort":"high"},"executed":{"model":"sample:large","effort":"high"},"disposition":"fallback","transitions":[{"from":"sample:small","to":"sample:large","reason":"unavailable"}],"retries":[]}"#
        )
      }
      return [user, assistant]
    }
    static func cached(_ scenario: StoreScenario) throws -> CachedConversation {
      .init(
        thread: try thread(scenario), messages: try messages(scenario),
        nextCursor: scenario == .conversationLong ? "transcript-older" : nil,
        savedAt: DashboardFixture.now)
    }
    static func replacingSummary(_ rows: [WebThread], scenario: StoreScenario) throws -> [WebThread]
    {
      try rows.map { $0.id == DashboardFixture.openThreadID ? try thread(scenario) : $0 }
    }
    static func fleet(_ scenario: StoreScenario) throws -> WebActiveThreads {
      var value = try DashboardFixture.fleet()
      value.threads = try replacingSummary(value.threads, scenario: scenario).filter {
        DashboardModel.presentation($0).active
      }
      value.total = value.threads.count
      value.runningCounts = Dictionary(grouping: value.threads, by: \.sourceId).mapValues(\.count)
      return value
    }
    static func bootstrap(_ scenario: StoreScenario, theme: String) throws -> ApiBootstrap {
      var value = try DashboardFixture.bootstrap(theme: theme)
      value.threads = try replacingSummary(value.threads, scenario: scenario)
      let active = try fleet(scenario)
      value.activeThreads = active
      for index in value.agents.indices {
        value.agents[index].runningCount =
          active.runningCounts[value.agents[index].sourceId] ?? 0
      }
      return value
    }
    static func response(_ request: URLRequest, scenario: StoreScenario, theme: String) throws
      -> HTTPResponse?
    {
      guard let url = request.url else { return nil }
      let base = "/api/v1/threads/" + DashboardFixture.openThreadID
      let value: JSONValue
      if url.path == "/api/v1/bootstrap" {
        value = try json(bootstrap(scenario, theme: theme))
      } else if url.path == "/api/v1/threads/active" {
        value = try json(fleet(scenario))
      } else if url.path == "/api/v1/threads",
        let response = try DashboardFixture.response(for: request, empty: false, theme: theme)
      {
        var page = try JSONDecoder().decode(ApiThreadPage.self, from: response.data)
        page.threads = try replacingSummary(page.threads, scenario: scenario)
        value = try json(page)
      } else if url.path == base {
        value = .object([
          "thread": try json(thread(scenario)), "messages": try json(messages(scenario)),
          "messagesNextCursor": scenario == .conversationLong ? .string("transcript-older") : .null,
        ])
      } else if url.path == base + "/usage" {
        value = .object(["usage": try json(JobFixture.usage())])
      } else if url.path.hasPrefix(base + "/jobs/"),
        let job = try JobFixture.jobs(scenario).first(where: { $0.jobId == url.lastPathComponent })
      {
        value = .object(["job": try json(job)])
      } else if url.path == base + "/messages" {
        value = .object([
          "messages": try json(messages(scenario, older: true)), "nextCursor": .null,
        ])
      } else if url.path.contains("/tool-calls/") {
        value = .object(["part": try json(WebMessagePart.toolCall(tool(1, full: true)))])
      } else {
        return nil
      }
      return HTTPResponse(data: try JSONEncoder().encode(value))
    }
    static func terminalTurn() throws -> ApiEvent {
      try decode(
        #"{"id":"sample-terminal-turn","version":1,"type":"turn.changed","at":"2030-01-02T12:00:00Z","threadId":"t-atlas-launch","payload":{"turn":{"id":"turn-transcript","status":"complete","model":"sample:large","effort":"high","startedAt":"2030-01-02T11:59:00Z","finishedAt":"2030-01-02T12:00:00Z"}}}"#
      )
    }
    static func delta(_ index: Int) throws -> ApiEvent {
      let terminal = index == 8
      return try decode(
        #"{"id":"sample-delta-\#(index)","version":1,"type":"message.delta","at":"2030-01-02T12:00:00Z","threadId":"t-atlas-launch","payload":{"messageId":"sample-assistant","baseSeq":\#(index),"seq":\#(index + 1),"status":"\#(terminal ? "complete" : "running")","updatedAt":"2030-01-02T12:00:00Z"\#(terminal ? ",\"finishedAt\":\"2030-01-02T12:00:00Z\"" : ""),"ops":[{"op":"set","index":1,"part":{"type":"text","text":"Live sample · \#(index) updates received\#(terminal ? " · Stream complete" : "…")"}}]}}"#
      )
    }
  }
#endif
