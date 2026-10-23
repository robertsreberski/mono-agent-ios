// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore
  import MonoAgentTestSupport

  enum StoreScenario: String, CaseIterable {
    case offline = "store-offline"
    case streaming = "store-streaming"
    case unread = "store-unread"
    case uncertain = "store-uncertain"
    case fidelityChat = "fidelity-chat"
    case fidelityDashboard = "fidelity-dashboard"
    case dashboardPopulated = "dashboard-populated"
    case dashboardEmpty = "dashboard-empty"
    case dashboardOffline = "dashboard-offline"
    case dashboardSearch = "dashboard-search"
    case conversationPlaceholder = "conversation-placeholder"
    case conversationTranscript = "conversation-transcript"
    case conversationStreaming = "conversation-streaming"
    case conversationTools = "conversation-tools"
    case conversationLong = "conversation-long"
    case conversationMarkdown = "conversation-markdown"
    case conversationJobs = "conversation-jobs"
    case conversationJobStack = "conversation-job-stack"
    case conversationSubagents = "conversation-subagents"
    case conversationReplyFiles = "conversation-reply-files"
    case conversationContext = "conversation-context"
    // Composer (C8): scripted send/upload/ask round trips through the synthetic Store.
    case composerEmpty = "composer-empty"
    case composerDraftAttachments = "composer-draft-attachments"
    case composerSkillPicker = "composer-skill-picker"
    case composerModelSelector = "composer-model-selector"
    case composerRunning = "composer-running"
    case composerSendFailed = "composer-send-failed"
    case composerQuote = "composer-quote"
    case conversationAskForm = "conversation-ask-form"
    case conversationQuickReplies = "conversation-quick-replies"
    case peerQuestionSheet = "peer-question-sheet"

    var isTranscript: Bool { rawValue.hasPrefix("conversation-") || self == .fidelityChat }
    var isFidelity: Bool { self == .fidelityChat || self == .fidelityDashboard }

    /// Composer scenarios are served by a stateful per-instance `ComposerScript`.
    var isComposer: Bool {
      switch self {
      case .composerEmpty, .composerDraftAttachments, .composerSkillPicker,
        .composerModelSelector, .composerRunning, .composerSendFailed, .composerQuote,
        .conversationAskForm, .conversationQuickReplies, .peerQuestionSheet:
        true
      default: false
      }
    }

    /// Dashboard scenarios use the richer `DashboardFixture`; store scenarios keep the golden.
    var isDashboard: Bool {
      switch self {
      case .offline, .streaming, .unread, .uncertain: false
      default: true
      }
    }

    /// No console answers: every read fails and the stream never becomes ready.
    var isOffline: Bool { self == .offline || self == .dashboardOffline }

    /// Fixture launch state the dashboard applies once the Store is ready.
    var launchQuery: String? { self == .dashboardSearch ? DashboardFixture.searchQuery : nil }
    var launchThreadID: String? {
      isTranscript || (isComposer && self != .composerEmpty) ? DashboardFixture.openThreadID : nil
    }

    /// Scenario.bootstrap is the fictional composition derived from the pinned C1 golden.
    @MainActor func prepare(
      _ store: ConsoleStore, repository: any ConsoleRepository, theme: String = "evergreen"
    ) async throws {
      if isFidelity {
        try await ScreenFixture.prepare(store, repository: repository, theme: theme)
        return
      }
      if isComposer {
        try await ComposerFixture.prepare(self, store: store, repository: repository, theme: theme)
        return
      }
      if isDashboard {
        try await DashboardFixture.prepare(
          store, repository: repository, empty: self == .dashboardEmpty, theme: theme,
          transcript: isTranscript ? self : nil)
        return
      }
      let bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
      var cache = CacheRecord()
      cache.revision = 1
      cache.bootstrap = bootstrap
      var thread = bootstrap.threads[0]
      if self == .streaming { thread.runState.status = "running" }
      let message = try JSONDecoder().decode(
        WebMessage.self,
        from: Data(
          #"{"id":"message-example","threadId":"thread-example","turnId":"turn-example","role":"assistant","parts":[{"type":"text","text":"A fictional streamed answer"}],"attachments":[],"createdAt":"2030-01-02T12:00:00Z","updatedAt":"2030-01-02T12:00:00Z","status":"running","seq":1}"#
            .utf8))
      cache.conversations = [.init(thread: thread, messages: [message], savedAt: Date())]
      cache.buckets = [
        .init(key: .init(sourceID: thread.sourceId), threads: [thread], savedAt: Date())
      ]
      try await repository.saveCache(cache, namespace: store.namespace)
      var authored = AuthoredRecord()
      authored.revision = 1
      authored.seen = [.init(id: thread.id, revision: self == .unread ? 0 : thread.revision)]
      try await repository.saveAuthored(authored, namespace: store.namespace)
      if self == .uncertain {
        var journal = JournalRecord()
        journal.revision = 1
        journal.pending = [
          .init(
            threadID: thread.id, submissionID: "00000000-0000-0000-0000-000000000001",
            payloadDigest: "fictional-digest",
            draftKey: .init(profileID: store.profile.id, sourceID: thread.sourceId),
            draftVersion: nil, dispatched: true)
        ]
        try await repository.saveJournal(journal, namespace: store.namespace)
      }
    }
  }

  actor ScenarioConsoleTransport: FileUploadTransport {
    let scenario: StoreScenario?
    let theme: String
    let script: ComposerScript?
    init(_ scenario: StoreScenario?, theme: String = "evergreen", script: ComposerScript? = nil) {
      self.scenario = scenario
      self.theme = theme
      self.script = script
    }
    func upload(
      _ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPResponse {
      guard let script else { throw URLError(.resourceUnavailable) }
      return try await script.upload(request, file: file, progress: progress)
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
      guard scenario?.isOffline != true else { throw URLError(.notConnectedToInternet) }
      if let script { return try await script.response(request, theme: theme) }
      if scenario?.isFidelity == true { return try ScreenFixture.response(request, theme: theme) }
      if let scenario, let response = try RichReplyFixture.response(request, scenario: scenario) {
        return response
      }
      if let scenario, scenario.isTranscript,
        let response = try TranscriptFixture.response(request, scenario: scenario, theme: theme)
      {
        return response
      }
      if let scenario, scenario.isDashboard {
        guard
          let response = try DashboardFixture.response(
            for: request, empty: scenario == .dashboardEmpty, theme: theme)
        else { throw URLError(.resourceUnavailable) }
        return response
      }
      if let response = try Self.goldenListing(request, streaming: scenario == .streaming) {
        return response
      }
      if request.url?.path == "/api/v1/bootstrap" {
        var value = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
        if scenario == .streaming { value.threads[0].runState.status = "running" }
        return HTTPResponse(data: try JSONEncoder().encode(value))
      }
      if request.url?.path == "/api/v1/threads/thread-example" {
        var thread = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
          .threads[0]
        if scenario == .streaming { thread.runState.status = "running" }
        let json: JSONValue = .object([
          "thread": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(thread)),
          "messages": .array([]), "messagesNextCursor": .null,
        ])
        return HTTPResponse(data: try JSONEncoder().encode(json))
      }
      // Exhaustion never falls through to a live session, including receipt recovery.
      throw URLError(.resourceUnavailable)
    }

    /// The golden's own listings for reconciliation reads, so the connected shell shows no
    /// spurious refresh failure. Detail and bootstrap keep their scenario-specific answers.
    private static func goldenListing(_ request: URLRequest, streaming: Bool) throws
      -> HTTPResponse?
    {
      var golden = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
      if streaming { golden.threads[0].runState.status = "running" }
      func encoded(_ value: JSONValue) throws -> HTTPResponse {
        HTTPResponse(data: try JSONEncoder().encode(value))
      }
      func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
      }
      switch request.url?.path {
      case "/api/v1/threads":
        let archived = request.url?.query?.contains("archived=true") == true
        return try encoded(
          .object([
            "threads": try json(archived ? [] : golden.threads), "nextCursor": .null,
          ]))
      case "/api/v1/threads/active":
        return try encoded(
          .object([
            "threads": .array([]), "total": .number(0), "truncated": .bool(false),
            "runningCounts": .object([:]),
          ]))
      case "/api/v1/tags": return try encoded(.object(["tags": try json(golden.tags)]))
      case "/api/v1/projects": return try encoded(.object(["projects": try json(golden.projects)]))
      default: return nil
      }
    }
  }
  actor ScenarioEventSource: ConsoleEventSource {
    let scenario: StoreScenario?
    let composer: ComposerScript?
    var continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation?
    var script: Task<Void, Never>?
    init(_ scenario: StoreScenario?, script composer: ComposerScript? = nil) {
      self.scenario = scenario
      self.composer = composer
    }
    func subscribe(thread: String?, capacity: Int) -> AsyncThrowingStream<StreamUpdate, any Error> {
      script?.cancel()
      continuation?.finish()
      let pair = AsyncThrowingStream<StreamUpdate, any Error>.makeStream()
      continuation = pair.continuation
      if scenario?.isOffline != true {
        pair.continuation.yield(.connecting(generation: 1, gap: .initial))
        if let ready = try? JSONDecoder().decode(
          ApiEvent.self,
          from: Data(
            #"{"id":"ready-example","version":1,"type":"ready","at":"2030-01-02T12:00:00Z","payload":{"version":1}}"#
              .utf8))
        {
          pair.continuation.yield(.event(generation: 1, gap: .initial, ready))
        }
      }
      if let composer {
        let continuation = pair.continuation
        Task { await composer.attach(continuation) }
      }
      if scenario == .conversationStreaming, thread == DashboardFixture.openThreadID {
        script = Task {
          for index in 1...8 {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            if let event = try? TranscriptFixture.delta(index) {
              pair.continuation.yield(.event(generation: 1, gap: .initial, event))
              if index == 8, let terminal = try? TranscriptFixture.terminalTurn() {
                pair.continuation.yield(.event(generation: 1, gap: .initial, terminal))
              }
            }
          }
        }
      }
      return pair.stream
    }
    func cancel() {
      script?.cancel()
      script = nil
      continuation?.finish()
      continuation = nil
    }
  }
#endif
