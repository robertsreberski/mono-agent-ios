// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore
  import SwiftUI

  /// Fictional composer scenarios (C8). Every value is synthetic; the console is never contacted.
  enum ComposerFixture {
    static let atlas = DashboardFixture.atlas
    static let open = DashboardFixture.openThreadID
    static let draftText = "Draft kept from an earlier visit: add the field notes."
    static let at = "2030-01-02T12:00:00.000Z"

    static func decode<T: Decodable>(_ text: String, as: T.Type = T.self) throws -> T {
      try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Atlas with a configured shortlist, efforts, a model without reasoning, and one
    /// catalog-only provider, so the selector shows allowed, default and explained rows.
    static func agent(_ value: WebAgentSummary) throws -> WebAgentSummary {
      guard value.sourceId == atlas else { return value }
      var agent = value
      agent.models = ["sample:large", "sample:small", "sample:fast"]
      agent.defaultModel = "sample:large"
      agent.defaultEffort = "high"
      agent.supportsAttachments = true
      agent.modelOptions = try decode(
        #"{"sample:large":{"label":"Sample Large","effortLevels":["low","medium","high"]},"sample:small":{"label":"Sample Small","effortLevels":["low","medium"]},"sample:fast":{"label":"Sample Fast","reasoning":false}}"#
      )
      agent.providers = try decode(
        #"[{"id":"sample","label":"Sample","configured":true},{"id":"harbor","label":"Harbor","configured":true}]"#
      )
      return agent
    }

    static func thread(_ scenario: StoreScenario) throws -> WebThread {
      var thread = try TranscriptFixture.thread(.conversationTranscript)
      thread.title = "Sample release conversation"
      thread.messageCount = 2
      switch scenario {
      case .composerRunning, .conversationAskForm:
        thread.runState = try decode(
          #"{"id":"turn-transcript","status":"running","model":"sample:large","effort":"high","startedAt":"2030-01-02T11:59:00Z"}"#
        )
      case .composerModelSelector:
        thread.runModel = nil
        thread.runEffort = nil
      default: break
      }
      return thread
    }

    static func message(_ id: String, role: String, text: String, status: String = "complete")
      throws -> WebMessage
    {
      var value = try TranscriptFixture.message(id: id, role: role, text: text)
      value.status = status
      if status == "running" { value.finishedAt = nil }
      return value
    }

    static func messages(_ scenario: StoreScenario) throws -> [WebMessage] {
      let user = try message("sample-user", role: "user", text: "Please review the sample release.")
      var assistant = try message(
        "sample-assistant", role: "assistant",
        text: "The sample is ready. **Two checks** passed; one fictional file needs attention.")
      switch scenario {
      case .composerRunning:
        assistant.status = "running"
        assistant.finishedAt = nil
        assistant.parts = [
          .reasoning(.init(type: "reasoning", text: "Walking through the synthetic checklist…")),
          .text(.init(text: "Working through the sample checklist…")),
        ]
      case .conversationAskForm:
        assistant.status = "running"
        assistant.finishedAt = nil
        let ask: WebToolCall = try decode(
          #"{"type":"tool-call","toolCallId":"ask-sample","toolName":"AskUser","args":{"message":"Two quick choices before I schedule the sample release."},"status":"running"}"#
        )
        assistant.parts = [.toolCall(ask)]
      case .conversationQuickReplies:
        let options: ReplyOptionsPart = try decode(
          #"{"type":"reply_options","id":"choices-sample","options":["Ship it","Hold for review"]}"#
        )
        assistant.parts = [
          .text(.init(text: "The sample release is ready to publish.")), .replyOptions(options),
        ]
      case .peerQuestionSheet:
        let job: ProcessJobPart = try decode(peerJob)
        assistant.parts = [
          .processJob(job),
          .text(.init(text: "I asked the seed-bank agent; it needs a decision from you.")),
        ]
      default: break
      }
      return [user, assistant]
    }

    static let peerJob = #"""
      {"type":"process-job","job":{"schema":"mono-agent.process-job-projection.v1","jobId":"job-peer-sample","tool":"PeerAgent","kind":"internal","instanceId":"seed-bank","childStillBusy":false,"state":"succeeded","summary":"Ask the seed-bank agent about sample stock","origin":{"conversationId":"t-atlas-launch","channel":"web","runId":"turn-transcript","historyBoundary":"sample-assistant","bucket":null},"timestamps":{"admittedAt":"2030-01-02T11:58:00.000Z","queueDeadlineAt":"2030-01-02T12:08:00.000Z","startedAt":"2030-01-02T11:58:00.000Z","runtimeDeadlineAt":"2030-01-02T12:28:00.000Z","completedAt":"2030-01-02T11:59:00.000Z"},"limits":{"maxRuntimeMs":60000,"maxOutputBytes":4096,"previewChars":200,"chainDepth":0},"output":{"stdoutBytes":0,"stderrBytes":0,"truncated":false,"preview":"","stdoutRef":null,"stderrRef":null},"wake":{"state":"delivered","attempts":1,"deliveryKey":"wake-peer-sample","lastAttemptAt":"2030-01-02T11:59:00.000Z"},"exitCode":0,"signal":null,"durationMs":60000,"cancelRequested":false,"lastError":null,"peerQuestion":{"state":"awaiting_answer","questionId":"3f6c9a2e-0000-4c8e-9a70-000000000001","peer":"seed-bank","thread":"spring-orders","message":"Should I reserve the sample tomato seeds now or wait for the member vote?","requestedSchema":{"type":"object","required":["question_1"],"properties":{"question_1":{"type":"string","title":"Sample tomatoes","description":"Reserve 40 packets now?","oneOf":[{"const":"reserve","title":"Reserve now"},{"const":"wait","title":"Wait for the vote"}]},"question_2":{"type":"string","title":"Delivery note"}}},"expiresAt":"2030-01-02T12:20:00.000Z"}}}
      """#

    static func askSnapshot(answered: [ChannelAskAnswer]? = nil) throws -> ChannelAskSnapshot {
      var value: ChannelAskSnapshot = try decode(
        #"{"interactionId":"ask-sample","message":"Two quick choices before I schedule the sample release.","questions":[{"id":"window","header":"Release window","question":"When should the sample release go out?","multiSelect":false,"options":[{"id":"today","label":"Today","description":"Publish this afternoon"},{"id":"monday","label":"Monday","description":"After the weekend review"}]},{"id":"checks","header":"Checks","question":"Which checks should run first?","multiSelect":true,"options":[{"id":"links","label":"Links","description":"Validate every sample link"},{"id":"images","label":"Images","description":"Check image sizes"},{"id":"copy","label":"Copy","description":"Proofread the text"}]}],"answers":[],"activeQuestionIndex":0,"status":"pending","createdAt":"2030-01-02T11:59:30.000Z","expiresAt":null}"#
      )
      if let answered {
        value.answers = answered
        value.status = "answered"
        value.activeQuestionIndex = value.questions.count
      }
      return value
    }

    static let skills = #"""
      {"status":"ready","items":[{"name":"release-notes","description":"Draft release notes from the sample changelog","availability":"on-demand","reference":"$release-notes"},{"name":"review-checklist","description":"Walk a fictional review checklist","availability":"inlined","reference":"$review-checklist"},{"name":"weekly-digest","description":"Summarise a synthetic week of notes","availability":"on-demand","reference":"$weekly-digest"},{"name":"legacy-export","description":"Export to an old sample format","availability":"unavailable","unavailableReason":"read-skill-disabled","reference":"$legacy-export"}],"total":4}
      """#

    static func bootstrap(_ thread: WebThread, created: [WebThread], theme: String) throws
      -> ApiBootstrap
    {
      var value = try TranscriptFixture.bootstrap(.conversationTranscript, theme: theme)
      value.agents = try value.agents.map(agent)
      value.threads = created + value.threads.map { $0.id == thread.id ? thread : $0 }
      value.limits = UploadLimits(
        accept: ["text/plain", "image/png", "image/jpeg", "application/pdf"])
      var fleet = try TranscriptFixture.fleet(.conversationTranscript)
      if thread.runState.status == "running" { fleet.threads.insert(thread, at: 0) }
      fleet.total = fleet.threads.count
      fleet.runningCounts = Dictionary(grouping: fleet.threads, by: \.sourceId).mapValues(\.count)
      value.activeThreads = fleet
      for index in value.agents.indices {
        value.agents[index].runningCount = fleet.runningCounts[value.agents[index].sourceId] ?? 0
      }
      return value
    }

    @MainActor static func prepare(
      _ scenario: StoreScenario, store: ConsoleStore, repository: any ConsoleRepository,
      theme: String
    ) async throws {
      let saved = DashboardFixture.now.addingTimeInterval(-15 * 60)
      let thread = try thread(scenario)
      var cache = CacheRecord()
      cache.revision = 1
      cache.bootstrap = try bootstrap(thread, created: [], theme: theme)
      func replaced(_ rows: [WebThread]) -> [WebThread] {
        rows.map { $0.id == thread.id ? thread : $0 }
      }
      cache.buckets = [
        .init(
          key: .init(sourceID: atlas),
          threads: replaced(try DashboardFixture.threads(source: atlas)),
          nextCursor: "cursor-older", savedAt: saved),
        .init(
          key: .init(sourceID: DashboardFixture.harbor),
          threads: try DashboardFixture.threads(source: DashboardFixture.harbor), savedAt: saved),
      ]
      cache.conversations = [
        .init(thread: thread, messages: try messages(scenario), savedAt: saved)
      ]
      try await repository.saveCache(cache, namespace: store.namespace)
      var authored = AuthoredRecord()
      authored.revision = 1
      authored.seen = try DashboardFixture.allThreads().map {
        ReadMarker(id: $0.id, revision: $0.id == thread.id ? thread.revision : $0.revision)
      }
      if scenario == .composerDraftAttachments {
        let draft: JSONValue = .object([
          "key": .object([
            "profileID": .string(store.profile.id.uuidString), "sourceID": .string(atlas),
            "threadID": .string(open),
          ]),
          "text": .string(draftText), "version": .string(UUID().uuidString),
          "updatedAt": .number(Date().timeIntervalSinceReferenceDate),
        ])
        authored.drafts = [
          try JSONDecoder().decode(ComposerDraft.self, from: JSONEncoder().encode(draft))
        ]
      }
      try await repository.saveAuthored(authored, namespace: store.namespace)
    }
  }

  /// Per-instance stateful console for composer scenarios. It answers the composer's routes
  /// (create, submit, receipt, live input, cancel, ask, uploads, run settings, skills) and
  /// scripts the agent's reply as `message.changed`/`turn.changed` events. Unknown routes fail
  /// closed. `composer-send-failed` loses the first POST and its receipt, then accepts only a
  /// retry that reuses the same submission UUID.
  actor ComposerScript {
    let scenario: StoreScenario?
    private var threads: [String: WebThread] = [:]
    private var transcripts: [String: [WebMessage]] = [:]
    private var createdOrder: [String] = []
    private var continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation?
    private var counter = 0
    private var lostSubmission: String?
    private(set) var submissionIDs: [String] = []
    private(set) var submissions: [ApiStartSubmission] = []
    private var uploads: [String: WebAttachment] = [:]
    private var answeredAsk: ChannelAskSnapshot?

    init(_ scenario: StoreScenario?) {
      self.scenario = scenario
      if let scenario, let thread = try? ComposerFixture.thread(scenario) {
        threads[thread.id] = thread
        transcripts[thread.id] = (try? ComposerFixture.messages(scenario)) ?? []
      }
    }

    func attach(_ continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation) {
      self.continuation = continuation
    }

    private func encoded<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
      HTTPResponse(data: try JSONEncoder().encode(value), status: status)
    }
    private func body<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) throws -> T {
      try JSONDecoder().decode(T.self, from: request.httpBody ?? Data("{}".utf8))
    }
    private func stamp() -> String {
      counter += 1
      return String(format: "2030-01-02T12:00:%02d.000Z", min(59, counter))
    }

    func response(_ request: URLRequest, theme: String) async throws -> HTTPResponse {
      guard let url = request.url else { throw URLError(.badURL) }
      let method = request.httpMethod ?? "GET"
      let path = url.path
      let open = ComposerFixture.open
      let main = threads[open]!
      let created = createdOrder.compactMap { threads[$0] }
      switch (method, path) {
      case ("GET", "/api/v1/bootstrap"):
        return try encoded(ComposerFixture.bootstrap(main, created: created, theme: theme))
      case ("GET", "/api/v1/threads/active"):
        return try encoded(
          ComposerFixture.bootstrap(main, created: created, theme: theme).activeThreads)
      case ("GET", "/api/v1/threads"):
        guard let listed = try DashboardFixture.response(for: request, empty: false, theme: theme)
        else { throw URLError(.resourceUnavailable) }
        var page = try JSONDecoder().decode(ApiThreadPage.self, from: listed.data)
        page.threads = page.threads.map { threads[$0.id] ?? $0 }
        let query = url.query ?? ""
        if !query.contains("archived=true"), !query.contains("before="),
          query.contains("sourceId=\(ComposerFixture.atlas)") || !query.contains("sourceId=")
        {
          page.threads = created.reversed() + page.threads
        }
        return try encoded(page)
      case ("POST", "/api/v1/threads"):
        let input: ApiCreateThread = try body(request)
        var thread = try TranscriptFixture.thread(.conversationTranscript)
        thread.id = "t-new-\(createdOrder.count + 1)"
        thread.sourceId = input.sourceId
        thread.title = "New conversation"
        thread.messageCount = 0
        thread.revision = 1
        thread.runState = try ComposerFixture.decode(#"{"status":"idle"}"#)
        if case .value(let model) = input.model {
          thread.runModel = model
        } else {
          thread.runModel = nil
        }
        if case .value(let effort) = input.effort {
          thread.runEffort = effort
        } else {
          thread.runEffort = nil
        }
        thread.createdAt = stamp()
        thread.updatedAt = thread.createdAt
        threads[thread.id] = thread
        transcripts[thread.id] = []
        createdOrder.append(thread.id)
        return try encoded(
          JSONValue.object(["thread": try ComposerFixture.json(thread)]), status: 201)
      case ("GET", "/api/v1/agents/\(ComposerFixture.atlas)/skills"):
        return HTTPResponse(data: Data(ComposerFixture.skills.utf8))
      case ("POST", "/api/v1/uploads"):
        let input: ApiCreateUpload = try body(request)
        let id = "upload-\(uploads.count + 1)"
        let attachment: WebAttachment = try ComposerFixture.decode(
          #"{"id":"\#(id)","name":"upload","contentType":"text/plain","sizeBytes":0,"kind":"file","status":"pending","uploaded":false,"createdAt":"2030-01-02T12:00:00.000Z"}"#
        )
        var value = attachment
        value.name = input.name
        value.contentType = input.contentType
        value.sizeBytes = input.sizeBytes ?? 0
        value.kind = input.contentType.hasPrefix("image/") ? "image" : "file"
        uploads[id] = value
        return try encoded(
          JSONValue.object(["attachment": try ComposerFixture.json(value)]), status: 201)
      default: break
      }
      if method == "DELETE", path.hasPrefix("/api/v1/uploads/") {
        uploads[String(path.dropFirst("/api/v1/uploads/".count))] = nil
        return HTTPResponse(data: Data(), status: 204)
      }
      let prefix = "/api/v1/threads/"
      guard path.hasPrefix(prefix) else {
        // Tags, projects and other dashboard reads keep the shared fixture's answers.
        if method == "GET",
          let fallback = try DashboardFixture.response(for: request, empty: false, theme: theme)
        {
          return fallback
        }
        throw URLError(.resourceUnavailable)
      }
      let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
      guard let id = parts.first, var thread = threads[id] else {
        if let fallback = try DashboardFixture.response(for: request, empty: false, theme: theme) {
          return fallback
        }
        throw URLError(.resourceUnavailable)
      }
      let messages = transcripts[id] ?? []
      switch (method, Array(parts.dropFirst())) {
      case ("GET", []):
        return try encoded(
          JSONValue.object([
            "thread": try ComposerFixture.json(thread),
            "messages": try ComposerFixture.json(messages), "messagesNextCursor": .null,
          ]))
      case ("PATCH", []):
        let patch: ApiPatchThread = try body(request)
        switch patch.model {
        case .value(let model): thread.runModel = model
        case .null: thread.runModel = nil
        case .omitted: break
        }
        switch patch.effort {
        case .value(let effort): thread.runEffort = effort
        case .null: thread.runEffort = nil
        case .omitted: break
        }
        thread.revision += 1
        threads[id] = thread
        return try encoded(JSONValue.object(["thread": try ComposerFixture.json(thread)]))
      case ("GET", ["messages"]):
        return try encoded(JSONValue.object(["messages": .array([]), "nextCursor": .null]))
      case ("GET", let rest) where rest.count == 2 && rest[0] == "messages":
        guard let message = messages.first(where: { $0.id == rest[1] }) else {
          throw URLError(.resourceUnavailable)
        }
        return try encoded(JSONValue.object(["message": try ComposerFixture.json(message)]))
      case ("POST", ["submissions"]):
        return try await submit(request, thread: thread)
      case ("GET", let rest) where rest.count == 2 && rest[0] == "submissions":
        // A lost POST is also lost to recovery reads here, so the Store stays uncertain.
        throw URLError(.networkConnectionLost)
      case ("POST", ["cancel"]):
        thread.runState = try ComposerFixture.decode(
          #"{"id":"turn-transcript","status":"cancelled","cancelOrigin":"user-stop","startedAt":"2030-01-02T11:59:00Z","finishedAt":"2030-01-02T12:00:30Z"}"#
        )
        thread.revision += 1
        threads[id] = thread
        transcripts[id] = messages.map { message in
          var value = message
          if value.status == "running" {
            value.status = "cancelled"
            value.finishedAt = "2030-01-02T12:00:30Z"
          }
          return value
        }
        emit(
          "turn.changed", thread: id,
          payload: .object(["turn": try ComposerFixture.json(thread.runState)]))
        return try encoded(
          JSONValue.object(["cancelled": .bool(true), "thread": try ComposerFixture.json(thread)]),
          status: 202)
      case ("GET", let rest) where rest.first == "ask" && rest.count <= 2:
        // By id: the exact interaction, terminal included. Pending: none once answered.
        let value: ChannelAskSnapshot? =
          rest.count == 2
          ? try answeredAsk ?? ComposerFixture.askSnapshot()
          : answeredAsk == nil ? try ComposerFixture.askSnapshot() : nil
        return try encoded(JSONValue.object(["ask": try value.map(ComposerFixture.json) ?? .null]))
      case ("POST", ["ask"]):
        let input: ApiAnswerAsk = try body(request)
        guard input.interactionId == "ask-sample", input.answers.count == 2,
          input.answers.allSatisfy({ !$0.selectedOptionIds.isEmpty || $0.customReply != nil })
        else {
          return try encoded(
            JSONValue.object(["accepted": .bool(false), "code": .string("invalid_answer")]))
        }
        let snapshot = try ComposerFixture.askSnapshot(answered: input.answers)
        answeredAsk = snapshot
        try finishAsk(id, answers: input.answers)
        return try encoded(
          JSONValue.object([
            "accepted": .bool(true), "snapshot": try ComposerFixture.json(snapshot),
          ]))
      default:
        throw URLError(.resourceUnavailable)
      }
    }

    func upload(
      _ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPResponse {
      let parts = request.url?.path.split(separator: "/").map(String.init) ?? []
      guard parts.count >= 4, var attachment = uploads[parts[3]] else {
        throw URLError(.resourceUnavailable)
      }
      for step in [0.25, 0.5, 0.75] {
        try await Task.sleep(for: .milliseconds(150))
        progress(step)
      }
      attachment.uploaded = true
      attachment.status = "ready"
      uploads[attachment.id] = attachment
      return try encoded(JSONValue.object(["attachment": try ComposerFixture.json(attachment)]))
    }

    private func submit(_ request: URLRequest, thread: WebThread) async throws -> HTTPResponse {
      let input: ApiStartSubmission = try body(request)
      submissionIDs.append(input.submissionId)
      if scenario == .composerSendFailed {
        if lostSubmission == nil {
          lostSubmission = input.submissionId
          throw URLError(.networkConnectionLost)
        }
        guard input.submissionId == lostSubmission else {
          return try encoded(
            JSONValue.object([
              "error": .object([
                "code": .string("fixture_new_identity"),
                "message": .string("Retry must reuse the original submission ID."),
              ])
            ]), status: 400)
        }
      }
      submissions.append(input)
      var thread = thread
      let running = thread.runState.status == "running"
      let turnID = running ? (thread.runState.id ?? "turn-transcript") : "turn-sub-\(counter + 1)"
      var user = try ComposerFixture.message(
        "user-\(input.submissionId.prefix(8))", role: "user", text: input.text ?? "")
      user.threadId = thread.id
      user.turnId = turnID
      user.quote = input.quote
      user.attachments = (input.attachmentIds ?? []).compactMap { uploads[$0] }
      user.createdAt = stamp()
      user.updatedAt = user.createdAt
      user.finishedAt = nil
      if running { user.liveInputStatus = "queued" }
      transcripts[thread.id, default: []].append(user)
      if !running {
        thread.runState = try ComposerFixture.decode(
          #"{"id":"\#(turnID)","status":"running","model":"\#(input.model ?? thread.runModel ?? "sample:large")","effort":"\#(input.effort ?? thread.runEffort ?? "high")","startedAt":"\#(user.createdAt)"}"#
        )
      }
      thread.messageCount += 1
      thread.revision += 1
      thread.updatedAt = user.createdAt
      threads[thread.id] = thread
      let receipt: JSONValue = .object([
        "submissionId": .string(input.submissionId), "threadId": .string(thread.id),
        "outcome": .string(running ? "live-input" : "turn"), "messageId": .string(user.id),
        "turnId": .string(turnID), "message": try ComposerFixture.json(user),
        "turn": try ComposerFixture.json(thread.runState),
      ])
      let threadID = thread.id
      let userID = user.id
      Task {
        try? await Task.sleep(for: .milliseconds(700))
        if running {
          try? self.applyLiveInput(threadID, messageID: userID)
        } else {
          try? self.reply(threadID, to: input, turnID: turnID)
        }
      }
      return try encoded(receipt, status: 202)
    }

    private func applyLiveInput(_ threadID: String, messageID: String) throws {
      guard let index = transcripts[threadID]?.firstIndex(where: { $0.id == messageID }) else {
        return
      }
      transcripts[threadID]?[index].liveInputStatus = "applied"
      emit("message.changed", thread: threadID, payload: messageChanged(messageID))
    }

    private func reply(_ threadID: String, to input: ApiStartSubmission, turnID: String) throws {
      guard var thread = threads[threadID] else { return }
      let quoted = input.quote.map { " about “\(QuotePrefix.short($0.text))”" } ?? ""
      let files =
        input.attachmentIds.map { " with \($0.count) attachment\($0.count == 1 ? "" : "s")" } ?? ""
      var answer = try ComposerFixture.message(
        "reply-\(turnID)", role: "assistant",
        text: "Synthetic reply\(quoted)\(files): received “\(QuotePrefix.short(input.text ?? ""))”."
      )
      answer.threadId = threadID
      answer.turnId = turnID
      answer.createdAt = stamp()
      answer.updatedAt = answer.createdAt
      answer.finishedAt = answer.createdAt
      transcripts[threadID, default: []].append(answer)
      thread.runState = try ComposerFixture.decode(
        #"{"id":"\#(turnID)","status":"complete","startedAt":"\#(answer.createdAt)","finishedAt":"\#(answer.createdAt)"}"#
      )
      thread.messageCount += 1
      thread.revision += 1
      threads[threadID] = thread
      emit("message.changed", thread: threadID, payload: messageChanged(answer.id))
      emit(
        "turn.changed", thread: threadID,
        payload: .object(["turn": try ComposerFixture.json(thread.runState)]))
    }

    private func finishAsk(_ threadID: String, answers: [ChannelAskAnswer]) throws {
      guard var thread = threads[threadID], var messages = transcripts[threadID],
        let index = messages.firstIndex(where: { $0.id == "sample-assistant" })
      else { return }
      var assistant = messages[index]
      assistant.parts = assistant.parts.map { part in
        guard case .toolCall(var call) = part, call.toolName == "AskUser" else { return part }
        call.status = "complete"
        call.structuredResult = .object([
          "interactionId": .string("ask-sample"), "answered": .bool(true),
        ])
        call.result = .string("The operator answered.")
        return .toolCall(call)
      }
      assistant.parts.append(.text(.init(text: "Thanks — scheduling the sample release.")))
      assistant.status = "complete"
      assistant.finishedAt = "2030-01-02T12:00:30Z"
      messages[index] = assistant
      transcripts[threadID] = messages
      thread.runState = try ComposerFixture.decode(
        #"{"id":"turn-transcript","status":"complete","startedAt":"2030-01-02T11:59:00Z","finishedAt":"2030-01-02T12:00:30Z"}"#
      )
      thread.revision += 1
      threads[threadID] = thread
      let state = thread.runState
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        self.emit(
          "message.changed", thread: threadID, payload: self.messageChanged("sample-assistant"))
        self.emit(
          "turn.changed", thread: threadID,
          payload: .object(["turn": (try? ComposerFixture.json(state)) ?? .null]))
      }
    }

    /// Explicit deterministic run changes for draft-lifecycle tests; never submits a message.
    func setRunning(_ running: Bool) throws {
      let id = ComposerFixture.open
      guard var thread = threads[id] else { return }
      if running {
        thread.runState = try ComposerFixture.decode(
          #"{"id":"turn-lifecycle-\#(counter)","status":"running","startedAt":"2030-01-02T12:00:00Z"}"#
        )
      } else {
        thread.runState.status = "complete"
        thread.runState.finishedAt = stamp()
      }
      thread.revision += 1
      threads[id] = thread
      emit(
        "turn.changed", thread: id,
        payload: .object(["turn": try ComposerFixture.json(thread.runState)]))
    }

    private func messageChanged(_ id: String) -> JSONValue {
      .object(["messageId": .string(id), "updatedAt": .string("2030-01-02T12:00:59.000Z")])
    }

    private func emit(_ type: String, thread: String, payload: JSONValue) {
      counter += 1
      let event: JSONValue = .object([
        "id": .string("composer-event-\(counter)"), "version": .number(1), "type": .string(type),
        "at": .string(ComposerFixture.at), "threadId": .string(thread), "payload": payload,
      ])
      guard let data = try? JSONEncoder().encode(event),
        let value = try? JSONDecoder().decode(ApiEvent.self, from: data)
      else { return }
      continuation?.yield(.event(generation: 1, gap: .initial, value))
    }
  }

  /// Opt-in controls only for synthetic automation; absent from ordinary scenarios and Release.
  struct SyntheticDraftLifecycle: ViewModifier {
    let model: AppModel
    let store: ConsoleStore
    @State private var revision = 0

    func body(content: Content) -> some View {
      content.overlay(alignment: .topTrailing) {
        if ProcessInfo.processInfo.arguments.contains("--draft-lifecycle-controls"),
          model.offersSampleAttachments, let script = model.composerScript
        {
          Menu("Synthetic lifecycle") {
            Button("Toggle synthetic run") {
              Task {
                try? await script.setRunning(
                  store.selectedConversation?.thread.runState.status != "running")
                await store.reconcile()
                revision += 1
              }
            }.accessibilityIdentifier("fixture-toggle-run")
            Button("Refresh synthetic conversation") {
              Task {
                await store.reconcile()
                revision += 1
              }
            }.accessibilityIdentifier("fixture-refresh")
            Button("Reselect synthetic conversation") {
              Task {
                await store.select(sourceID: ComposerFixture.atlas, threadID: ComposerFixture.open)
                revision += 1
              }
            }.accessibilityIdentifier("fixture-reselect")
          }
          .accessibilityIdentifier("fixture-lifecycle")
          .accessibilityValue(String(revision))
        }
      }
    }
  }

  enum QuotePrefix {
    static func short(_ text: String) -> String {
      let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }
  }
#endif
