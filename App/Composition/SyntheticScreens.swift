// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentStore

  /// Content-identical to the web Storybook Screens/Chat and Screens/Dashboard fixtures.
  /// Kept in DEBUG composition; all reads are per-instance and fail closed.
  enum ScreenFixture {
    static let question = "Morgan: Can you help outline a garden planner?"
    static let plan = """
      # Garden planner

      Here is a small plan for a **fictional** garden.

      - Map three beds
      - Choose low-water plants
      - Check seedlings weekly

      | Bed | Plant |
      | --- | --- |
      | North | Sage |
      | South | Thyme |

      ```ts
      const beds = ["north", "south"];
      ```
      """
    static let stamp = "2026-01-15T10:00:00Z"

    static func bootstrap(theme: String = "evergreen") throws -> ApiBootstrap {
      var value = try DashboardFixture.bootstrap(theme: theme)
      value.console.displayName = "Garden console"
      var atlas = value.agents.first { $0.sourceId == DashboardFixture.atlas }!
      atlas.label = "Atlas"
      atlas.runningCount = 1
      atlas.supportsManualCompaction = true
      atlas.models = ["atlas/standard"]
      atlas.defaultModel = "atlas/standard"
      atlas.defaultEffort = "medium"
      atlas.efforts = ["low", "medium"]
      atlas.runSettings.config.model = "atlas/standard"
      atlas.runSettings.config.effort = "medium"
      atlas.runSettings.override = nil
      atlas.runSettings.effective.model = "atlas/standard"
      atlas.runSettings.effective.effort = "medium"
      var grove = atlas
      grove.sourceId = "grove"
      grove.label = "Grove"
      grove.status = "offline"
      grove.pinned = false
      grove.runningCount = 0
      value.agents = [atlas, grove]
      var garden = value.threads[0]
      garden.id = DashboardFixture.openThreadID
      garden.title = "Garden planner"
      garden.messageCount = 8
      garden.projectId = "garden"
      garden.projectName = "Garden planner"
      garden.tagIds = ["research"]
      garden.runModel = nil
      garden.runEffort = nil
      garden.lastMessagePreview = nil
      garden.trigger = nil
      garden.wakeSchedule = nil
      garden.createdAt = stamp
      garden.updatedAt = stamp
      garden.runState = try TranscriptFixture.decode(#"{"status":"idle"}"#)
      var running = garden
      running.id = "seed-catalog"
      running.title = "Seed catalog"
      running.projectId = nil
      running.projectName = nil
      running.tagIds = []
      running.messageCount = 3
      running.runState = try TranscriptFixture.decode(#"{"status":"running"}"#)
      var notes = running
      notes.id = "seedling-notes"
      notes.title = "Seedling notes"
      notes.messageCount = 2
      notes.updatedAt = "2026-01-15T11:00:00Z"
      notes.runState = garden.runState
      value.threads = [garden, running, notes]
      value.threadsNextCursor = nil
      value.threadsSourceId = DashboardFixture.atlas
      var project = value.projects[0]
      project.id = "garden"
      project.name = "Garden planner"
      project.color = "blue"
      project.conversationCount = 2
      project.runningCount = 0
      project.createdAt = stamp
      project.updatedAt = stamp
      project.archivedAt = nil
      value.projects = [project]
      var tag = value.tags[0]
      tag.id = "research"
      tag.name = "Research"
      tag.color = "green"
      value.tags = [tag]
      value.activeThreads?.threads = [running]
      value.activeThreads?.total = 1
      value.activeThreads?.truncated = false
      value.activeThreads?.runningCounts = [DashboardFixture.atlas: 1]
      return value
    }

    static func messages() throws -> [WebMessage] {
      try [
        TranscriptFixture.message(
          id: "garden-context", role: "system", text: "Example project context: Garden planner"),
        TranscriptFixture.message(id: "garden-question", role: "user", text: question),
        TranscriptFixture.message(id: "garden-plan", role: "assistant", text: plan),
      ]
    }

    @MainActor static func prepare(
      _ store: ConsoleStore, repository: any ConsoleRepository, theme: String
    ) async throws {
      let value = try bootstrap(theme: theme)
      var cache = CacheRecord()
      cache.revision = 1
      cache.bootstrap = value
      cache.buckets = [
        .init(
          key: .init(sourceID: DashboardFixture.atlas), threads: value.threads,
          savedAt: DashboardFixture.now)
      ]
      cache.conversations = [
        .init(thread: value.threads[0], messages: try messages(), savedAt: DashboardFixture.now)
      ]
      try await repository.saveCache(cache, namespace: store.namespace)
      var authored = AuthoredRecord()
      authored.revision = 1
      authored.seen = value.threads.map {
        ReadMarker(id: $0.id, revision: $0.id == "seedling-notes" ? $0.revision - 1 : $0.revision)
      }
      try await repository.saveAuthored(authored, namespace: store.namespace)
    }

    static func response(_ request: URLRequest, theme: String) throws -> HTTPResponse {
      let bootstrap = try bootstrap(theme: theme)
      let base = "/api/v1/threads/" + DashboardFixture.openThreadID
      let value: JSONValue
      switch request.url?.path {
      case "/api/v1/bootstrap": value = try TranscriptFixture.json(bootstrap)
      case "/api/v1/threads/active": value = try TranscriptFixture.json(bootstrap.activeThreads)
      case "/api/v1/threads":
        let archived =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "archived" && $0.value == "true"
          } == true
        value = .object([
          "threads": try TranscriptFixture.json(archived ? [] : bootstrap.threads),
          "nextCursor": .null,
        ])
      case "/api/v1/projects":
        value = .object(["projects": try TranscriptFixture.json(bootstrap.projects)])
      case "/api/v1/tags": value = .object(["tags": try TranscriptFixture.json(bootstrap.tags)])
      case base:
        value = .object([
          "thread": try TranscriptFixture.json(bootstrap.threads[0]),
          "messages": try TranscriptFixture.json(messages()), "messagesNextCursor": .null,
        ])
      default: throw URLError(.resourceUnavailable)
      }
      return HTTPResponse(data: try JSONEncoder().encode(value))
    }
  }
#endif
