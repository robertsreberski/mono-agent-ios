// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore
  import MonoAgentTestSupport

  /// Fictional dashboard data for DEBUG scenarios, previews and app tests. Every name, title
  /// and preview is synthetic; timestamps are relative to a fixed reference instant so relative
  /// times and screenshots are deterministic. Built by mutating the pinned-golden-derived
  /// TestSupport bootstrap so every value stays wire-compatible.
  enum DashboardFixture {
    /// 2030-01-02T12:00:00Z; the dashboard's relative times are measured from here.
    static let now = Date(timeIntervalSince1970: 1_893_585_600)
    static let searchQuery = "notes"
    static let openThreadID = "t-atlas-launch"

    static let atlas = "agent-atlas"
    static let harbor = "agent-harbor"
    static let quill = "agent-quill"
    static let dormant = "agent-dormant"

    /// Conversations this device last saw at an older revision, so they read as unread.
    static let unreadThreadIDs = ["t-atlas-notes", "t-quill-blog"]

    private static func iso(minutesAgo minutes: Double) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.string(from: now.addingTimeInterval(-minutes * 60))
    }

    private static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
      try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func template() throws -> ApiBootstrap {
      try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    }

    private static func agent(
      _ id: String, _ label: String, status: String = "online", pinned: Bool = false,
      running: Int = 0
    ) throws -> WebAgentSummary {
      var value = try template().agents[0]
      value.sourceId = id
      value.label = label
      value.status = status
      value.pinned = pinned
      value.runningCount = running
      return value
    }

    private enum Run {
      case idle(String?)
      case running(
        calls: Int?, phase: String = "working", cost: Double? = nil, unknown: Bool = false)
    }

    private static func thread(
      _ id: String, source: String, title: String, minutesAgo: Double, revision: Int = 4,
      run: Run = .idle("complete"), preview: String? = nil,
      project: (id: String, name: String)? = nil,
      tags: [String] = [], trigger: String? = nil, wake: Bool = false, archived: Bool = false,
      messages: Int = 6
    ) throws -> WebThread {
      var value = try template().threads[0]
      value.id = id
      value.sourceId = source
      value.title = title
      value.updatedAt = iso(minutesAgo: minutesAgo)
      value.createdAt = iso(minutesAgo: minutesAgo + 600)
      value.revision = revision
      value.messageCount = messages
      value.lastMessagePreview = preview
      value.projectId = project?.id
      value.projectName = project?.name
      value.tagIds = tags
      value.archivedAt = archived ? iso(minutesAgo: minutesAgo) : nil
      if let trigger { value.trigger = try decode(#"{"kind":"\#(trigger)"}"#) }
      if wake {
        value.wakeSchedule = try decode(
          #"{"state":"active","revision":1,"kind":"recurring","nextFireAt":"2030-01-03T08:00:00Z"}"#
        )
      }
      switch run {
      case .idle(let outcome):
        value.runState = try decode(
          outcome.map {
            #"{"status":"idle","lastOutcome":{"status":"\#($0)","finishedAt":"\#(iso(minutesAgo: minutesAgo))"}}"#
          } ?? #"{"status":"idle"}"#)
      case .running(let calls, let phase, let cost, let unknown):
        var state: WebRunState = try decode(
          #"{"status":"running","startedAt":"\#(iso(minutesAgo: minutesAgo + 3))"}"#)
        if let calls {
          state.activity = try decode(
            #"{"toolCallCount":\#(calls),"phase":"\#(phase)"\#(cost.map { ",\"cumulativeUsd\":\($0)" } ?? "")\#(unknown ? ",\"costUnknown\":true" : "")}"#
          )
        }
        value.runState = state
      }
      return value
    }

    private static func tag(_ id: String, _ name: String, _ color: String) throws -> WebTag {
      var value = try template().tags[0]
      value.id = id
      value.sourceId = atlas
      value.name = name
      value.color = color
      return value
    }

    private static func project(
      _ id: String, _ name: String, color: String, chats: Int, running: Int, minutesAgo: Double,
      archived: Bool = false
    ) throws -> WebProject {
      var value = try template().projects[0]
      value.id = id
      value.sourceId = atlas
      value.name = name
      value.color = color
      value.conversationCount = chats
      value.runningCount = running
      value.updatedAt = iso(minutesAgo: minutesAgo)
      value.archivedAt = archived ? iso(minutesAgo: minutesAgo) : nil
      return value
    }

    static let fieldNotes = (id: "p-field-notes", name: "Field notes")
    static let website = (id: "p-website", name: "Website refresh")

    static func agents() throws -> [WebAgentSummary] {
      [
        try agent(quill, "Quill Writer"),
        try agent(harbor, "Harbor Ops", status: "degraded", running: 1),
        try agent(dormant, "Dormant Helper", status: "offline"),
        try agent(atlas, "Atlas Research", pinned: true, running: 3),
      ]
    }

    static func threads(source: String, archived: Bool = false) throws -> [WebThread] {
      switch (source, archived) {
      case (atlas, false):
        [
          try thread(
            "t-atlas-launch", source: atlas, title: "Launch checklist for the sample app",
            minutesAgo: 2, run: .running(calls: 4, cost: 0.42), project: website,
            tags: ["tag-release"]),
          try thread(
            "t-atlas-survey", source: atlas, title: "Survey answers summary", minutesAgo: 6,
            run: .running(calls: nil), project: fieldNotes),
          try thread(
            "t-atlas-brochure", source: atlas, title: "Translate the sample brochure",
            minutesAgo: 12, run: .running(calls: 2, phase: "asking")),
          try thread(
            "t-atlas-notes", source: atlas, title: "Weekly field notes", minutesAgo: 40,
            revision: 9, preview: "Drafted the fictional summary for Morgan's review.",
            project: fieldNotes, tags: ["tag-research", "tag-draft"]),
          try thread(
            "t-atlas-import", source: atlas, title: "Nightly import", minutesAgo: 180,
            run: .idle("failed"), trigger: "webhook"),
          try thread(
            "t-atlas-digest", source: atlas, title: "Daily digest", minutesAgo: 200,
            trigger: "cron"),
          try thread(
            "t-atlas-garden", source: atlas, title: "Ideas for the community garden",
            minutesAgo: 2 * 24 * 60,
            preview: "Three planting layouts and a watering rota for the fictional plot.",
            tags: ["tag-research", "tag-draft", "tag-release", "tag-urgent"], wake: true),
          try thread(
            "t-atlas-reading", source: atlas, title: "Reading list", minutesAgo: 12 * 24 * 60,
            preview: "Added two sample essays on map making."),
        ]
      case (atlas, true):
        [
          try thread(
            "t-atlas-archived", source: atlas, title: "Old travel notes",
            minutesAgo: 40 * 24 * 60, preview: "Packing list for a fictional trip.",
            archived: true)
        ]
      case (harbor, false):
        [
          try thread(
            "t-harbor-deploy", source: harbor, title: "Deploy the demo service", minutesAgo: 1,
            run: .running(calls: 1, unknown: true), project: (id: "p-infra", name: "Infrastructure")
          ),
          try thread(
            "t-harbor-alerts", source: harbor, title: "Tidy alert rules", minutesAgo: 300,
            preview: "Merged the duplicate sample rules."),
        ]
      case (quill, false):
        [
          try thread(
            "t-quill-blog", source: quill, title: "Blog post outline", minutesAgo: 25,
            revision: 7, preview: "Outline ready: intro, three sections and a summary.")
        ]
      default: []
      }
    }

    /// Older page for "Load older conversations".
    static func olderThreads(source: String) throws -> [WebThread] {
      guard source == atlas else { return [] }
      return [
        try thread(
          "t-atlas-older", source: atlas, title: "Sample onboarding questions",
          minutesAgo: 20 * 24 * 60, preview: "Five fictional questions for new members.")
      ]
    }

    static func tags() throws -> [WebTag] {
      [
        try tag("tag-research", "Research", "teal"), try tag("tag-draft", "Draft", "default"),
        try tag("tag-release", "Release", "purple"), try tag("tag-urgent", "Urgent", "red"),
      ]
    }

    static func projects() throws -> [WebProject] {
      [
        try project(
          fieldNotes.id, fieldNotes.name, color: "blue", chats: 4, running: 1, minutesAgo: 6),
        try project(
          website.id, website.name, color: "amber", chats: 2, running: 1, minutesAgo: 2),
        try project(
          "p-retired", "Retired project", color: "rose", chats: 1, running: 0,
          minutesAgo: 9000, archived: true),
      ]
    }

    static func fleet() throws -> WebActiveThreads {
      var value: WebActiveThreads = try decode(
        #"{"threads":[],"total":0,"truncated":false,"runningCounts":{}}"#)
      value.threads =
        try threads(source: atlas).filter { $0.runState.status == "running" }
        + threads(source: harbor).filter { $0.runState.status == "running" }
      value.total = value.threads.count
      value.runningCounts = [atlas: 3, harbor: 1]
      return value
    }

    /// The bootstrap. `empty` is a new console with one agent and nothing else.
    static func bootstrap(empty: Bool = false, theme: String = "evergreen") throws -> ApiBootstrap {
      var value = try template()
      value.console.theme = theme
      if empty {
        value.agents = [try agent(atlas, "Atlas Research")]
        value.threads = []
        value.tags = []
        value.projects = []
        value.activeThreads = try decode(
          #"{"threads":[],"total":0,"truncated":false,"runningCounts":{}}"#)
      } else {
        value.agents = try agents()
        value.threads = try threads(source: atlas)
        value.threadsNextCursor = "cursor-older"
        value.tags = try tags()
        value.projects = try projects()
        value.activeThreads = try fleet()
      }
      value.threadsSourceId = atlas
      value.projectsSourceId = atlas
      return value
    }

    /// Every thread the fixture knows, for detail reads.
    static func allThreads() throws -> [WebThread] {
      try [atlas, harbor, quill].flatMap { try threads(source: $0) }
        + threads(source: atlas, archived: true) + olderThreads(source: atlas)
    }

    static func searchPage(query: String, source: String) throws -> JSONValue {
      guard source == atlas, query.localizedCaseInsensitiveContains(searchQuery) else {
        return .object(["hits": .array([]), "truncated": .bool(false)])
      }
      let all = try allThreads()
      func hit(_ id: String, snippet: String?, matches: Int, title: Bool) throws -> JSONValue {
        let thread = try require(all.first { $0.id == id })
        var fields: [String: JSONValue] = [
          "thread": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(thread)),
          "messageMatches": .number(Double(matches)), "titleMatch": .bool(title),
        ]
        if let snippet { fields["snippet"] = .string(snippet) }
        return .object(fields)
      }
      return .object([
        "hits": .array([
          try hit(
            "t-atlas-notes", snippet: "…the weekly field \u{2}notes\u{3} are ready for review…",
            matches: 3, title: true),
          try hit(
            "t-atlas-survey", snippet: "Shared \u{2}notes\u{3} from the fictional survey answers.",
            matches: 1, title: false),
          try hit("t-atlas-archived", snippet: nil, matches: 0, title: true),
        ]),
        "truncated": .bool(false),
      ])
    }

    /// A cache snapshot as an earlier session would have left it: every bucket, the fleet and
    /// read markers. The offline scenario shows exactly this; live scenarios refresh over it.
    static func prepare(
      _ store: ConsoleStore, repository: any ConsoleRepository, empty: Bool, theme: String,
      transcript: StoreScenario? = nil
    ) async throws {
      let saved = now.addingTimeInterval(-15 * 60)
      var cache = CacheRecord()
      cache.revision = 1
      cache.bootstrap =
        try transcript.map { try TranscriptFixture.bootstrap($0, theme: theme) }
        ?? bootstrap(empty: empty, theme: theme)
      if !empty {
        cache.buckets = [
          .init(
            key: .init(sourceID: atlas), threads: try threads(source: atlas),
            nextCursor: "cursor-older", savedAt: saved),
          .init(key: .init(sourceID: harbor), threads: try threads(source: harbor), savedAt: saved),
          .init(key: .init(sourceID: quill), threads: try threads(source: quill), savedAt: saved),
        ]
      }
      if let transcript {
        cache.conversations = [try TranscriptFixture.cached(transcript)]
        for index in cache.buckets.indices {
          cache.buckets[index].threads = try TranscriptFixture.replacingSummary(
            cache.buckets[index].threads, scenario: transcript)
        }
      }
      try await repository.saveCache(cache, namespace: store.namespace)
      var authored = AuthoredRecord()
      authored.revision = 1
      if !empty {
        authored.seen = try allThreads().map { thread in
          ReadMarker(
            id: thread.id,
            revision: unreadThreadIDs.contains(thread.id) ? thread.revision - 2 : thread.revision)
        }
      }
      try await repository.saveAuthored(authored, namespace: store.namespace)
    }

    /// Fail-closed fixture routing: unknown paths throw, never reach a live session.
    static func response(
      for request: URLRequest, empty: Bool, theme: String
    ) throws -> HTTPResponse? {
      guard let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { return nil }
      let query = Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first })
      let source = query["sourceId"] ?? atlas
      func encoded<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(data: try JSONEncoder().encode(value))
      }
      switch url.path {
      case "/api/v1/bootstrap":
        return try encoded(bootstrap(empty: empty, theme: theme))
      case "/api/v1/threads":
        let archived = query["archived"] == "true"
        let older = query["before"] != nil
        let rows =
          empty
          ? []
          : try older ? olderThreads(source: source) : threads(source: source, archived: archived)
        let cursor: JSONValue =
          !empty && !older && !archived && source == atlas ? .string("cursor-older") : .null
        return try encoded(
          JSONValue.object([
            "threads": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rows)),
            "nextCursor": cursor,
          ]))
      case "/api/v1/threads/active":
        return try encoded(empty ? bootstrap(empty: true).activeThreads : fleet())
      case "/api/v1/threads/search":
        return try encoded(searchPage(query: query["q"] ?? "", source: source))
      case "/api/v1/tags":
        return try encoded(
          JSONValue.object(["tags": try jsonValue(empty || source != atlas ? [] : tags())]))
      case "/api/v1/projects":
        return try encoded(
          JSONValue.object(["projects": try jsonValue(empty || source != atlas ? [] : projects())]))
      default:
        let prefix = "/api/v1/threads/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let id = String(url.path.dropFirst(prefix.count))
        guard !id.contains("/"), let thread = try allThreads().first(where: { $0.id == id }) else {
          return nil
        }
        return try encoded(
          JSONValue.object([
            "thread": try jsonValue(thread), "messages": .array([]), "messagesNextCursor": .null,
          ]))
      }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
  }

  private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw URLError(.resourceUnavailable) }
    return value
  }
#endif
