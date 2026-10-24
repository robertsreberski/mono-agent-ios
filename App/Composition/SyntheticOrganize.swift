// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Per-instance, stateful synthetic routes. Never reads a live console.
  actor OrganizeScript {
    var thread: WebThread?
    var deleted = false
    var projects: [WebProject]?
    var tags: [WebTag]?
    let wakeScenario: String?
    var wakeInitialized = false
    var wake: WebWakeSchedule?
    var wakeConflicted = false
    init(wakeScenario: String? = nil) { self.wakeScenario = wakeScenario }
    func publishWake() {
      thread?.wakeSchedule = wake.map {
        .init(
          state: $0.state, revision: $0.revision, nextFireAt: $0.nextFireAt,
          kind: $0.definition.kind, compactFirst: $0.definition.compactFirst)
      }
    }
    func response(_ request: URLRequest, theme: String) throws -> HTTPResponse {
      if thread == nil { thread = try ScreenFixture.bootstrap(theme: theme).threads[0] }
      if wakeScenario == "organize-long", tags == nil {
        let sample = try ScreenFixture.bootstrap(theme: theme)
        tags = (1...30).map { index in
          var value = sample.tags[0]
          value.id = "label-\(index)"
          value.name = String(format: "Label %02d", index)
          return value
        }
        projects = (1...12).map { index in
          var value = sample.projects[0]
          value.id = "collection-\(index)"
          value.name = String(format: "Collection %02d", index)
          return value
        }
        thread?.tagIds = []
        thread?.projectId = nil
        thread?.projectName = nil
      }
      if wakeScenario == "organize-archived-search" {
        var cold = thread!
        cold.id = "cold-archived"
        cold.title = "Archived cold note"
        cold.archivedAt = ScreenFixture.stamp
        if request.url?.path == "/api/v1/threads/search" {
          let value: JSONValue = .object([
            "hits": .array([
              .object([
                "thread": try TranscriptFixture.json(cold), "messageMatches": .number(0),
                "titleMatch": .bool(true),
              ])
            ]), "truncated": .bool(false),
          ])
          return HTTPResponse(data: try JSONEncoder().encode(value))
        }
        if request.url?.path == "/api/v1/threads/cold-archived" {
          let value: JSONValue = .object([
            "thread": try TranscriptFixture.json(cold),
            "messages": try TranscriptFixture.json(ScreenFixture.messages()),
            "messagesNextCursor": .null,
          ])
          return HTTPResponse(data: try JSONEncoder().encode(value))
        }
      }
      if !wakeInitialized {
        wakeInitialized = true
        if let wakeScenario, wakeScenario.hasPrefix("wake-"), wakeScenario != "wake-new" {
          let weekly = wakeScenario != "wake-once"
          let definition = WebWakeScheduleDefinition(
            kind: weekly ? "weekly" : "once", timezone: "UTC",
            localAt: weekly ? nil : "2031-05-14T09:00", days: weekly ? [1, 3, 5] : nil,
            times: weekly ? ["09:00", "14:30"] : nil, message: "Review the fictional garden plan.",
            compactFirst: true)
          let json: JSONValue = .object([
            "scheduleId": .string("wake-garden"), "threadId": .string(thread!.id),
            "sourceId": .string(thread!.sourceId),
            "definition": try TranscriptFixture.json(definition), "state": .string("active"),
            "revision": .number(1), "nextFireAt": .string("2031-05-14T09:00:00Z"),
            "lastOutcome": .string("fired"), "createdAt": .string(ScreenFixture.stamp),
          ])
          wake = try JSONDecoder().decode(WebWakeSchedule.self, from: JSONEncoder().encode(json))
          publishWake()
        }
      }
      if request.url?.path == "/api/v1/threads/" + thread!.id + "/wake-schedule" {
        let method = request.httpMethod ?? "GET"
        if method != "GET", wakeScenario == "wake-conflict", !wakeConflicted {
          wakeConflicted = true
          wake?.revision += 1
          wake?.definition.message = "Updated elsewhere."
          publishWake()
          return HTTPResponse(
            data: Data(
              #"{"error":{"code":"wake_revision_conflict","message":"Schedule changed; reload and retry."}}"#
                .utf8), status: 409)
        }
        if method == "DELETE" {
          wake = nil
          publishWake()
          return HTTPResponse(data: Data(), status: 204)
        }
        if let data = request.httpBody {
          if method == "PATCH" {
            let body = try JSONDecoder().decode(ApiPatchWake.self, from: data)
            wake?.state = body.state
            wake?.revision += 1
          } else {
            let definition = try JSONDecoder().decode(WebWakeScheduleDefinition.self, from: data)
            let json: JSONValue = .object([
              "scheduleId": .string("wake-garden"), "threadId": .string(thread!.id),
              "sourceId": .string(thread!.sourceId),
              "definition": try TranscriptFixture.json(definition), "state": .string("active"),
              "revision": .number(Double((wake?.revision ?? 0) + 1)),
              "nextFireAt": .string("2031-05-14T09:00:00Z"), "lastOutcome": .null,
              "createdAt": .string(ScreenFixture.stamp),
            ])
            wake = try JSONDecoder().decode(WebWakeSchedule.self, from: JSONEncoder().encode(json))
          }
          publishWake()
        }
        let json: JSONValue = .object(["schedule": try wake.map(TranscriptFixture.json) ?? .null])
        return HTTPResponse(
          data: try JSONEncoder().encode(json), status: method == "POST" ? 201 : 200)
      }
      if tags == nil { tags = try ScreenFixture.bootstrap(theme: theme).tags }
      if request.url?.path == "/api/v1/tags", request.httpMethod == "POST",
        let data = request.httpBody
      {
        let input = try JSONDecoder().decode(ApiCreateTag.self, from: data)
        var value = try ScreenFixture.bootstrap(theme: theme).tags[0]
        value.id = "tag-created-\(tags!.count)"
        value.name = input.name
        value.sourceId = input.sourceId
        value.color = input.color ?? "default"
        tags?.append(value)
        return HTTPResponse(data: try JSONEncoder().encode(["tag": value]), status: 201)
      }
      if let path = request.url?.path, path.hasPrefix("/api/v1/tags/"),
        let index = tags?.firstIndex(where: { $0.id == request.url?.lastPathComponent })
      {
        if request.httpMethod == "DELETE" {
          let value = tags!.remove(at: index)
          thread?.tagIds.removeAll { $0 == value.id }
          return HTTPResponse(data: Data(), status: 204)
        }
        if request.httpMethod == "PATCH", let data = request.httpBody {
          let input = try JSONDecoder().decode(ApiPatchTag.self, from: data)
          if let name = input.name { tags?[index].name = name }
          if let color = input.color { tags?[index].color = color }
          tags?[index].revision += 1
          return HTTPResponse(data: try JSONEncoder().encode(["tag": tags![index]]))
        }
      }
      if request.url?.path == "/api/v1/tags" {
        return HTTPResponse(data: try JSONEncoder().encode(["tags": tags!]))
      }
      if projects == nil { projects = try ScreenFixture.bootstrap(theme: theme).projects }
      if request.url?.path == "/api/v1/projects", request.httpMethod == "POST",
        let data = request.httpBody
      {
        let input = try JSONDecoder().decode(ApiCreateProject.self, from: data)
        var project = try ScreenFixture.bootstrap(theme: theme).projects[0]
        project.id = "project-created-\(projects!.count)"
        project.sourceId = input.sourceId
        project.name = input.name
        project.context = input.context ?? ""
        project.color = input.color
        project.conversationCount = 0
        project.runningCount = 0
        projects?.append(project)
        return HTTPResponse(data: try JSONEncoder().encode(["project": project]), status: 201)
      }
      if let path = request.url?.path, path.hasPrefix("/api/v1/projects/"),
        let index = projects?.firstIndex(where: { $0.id == request.url?.lastPathComponent })
      {
        if request.httpMethod == "DELETE" {
          let removed = projects!.remove(at: index)
          if thread?.projectId == removed.id {
            thread?.projectId = nil
            thread?.projectName = nil
          }
          return HTTPResponse(data: Data(), status: 204)
        }
        if request.httpMethod == "PATCH", let data = request.httpBody {
          let input = try JSONDecoder().decode(ApiPatchProject.self, from: data)
          if let name = input.name { projects?[index].name = name }
          if let context = input.context { projects?[index].context = context }
          if let color = input.color { projects?[index].color = color }
          if let archived = input.archived {
            projects?[index].archivedAt = archived ? ScreenFixture.stamp : nil
          }
          projects?[index].revision += 1
          return HTTPResponse(data: try JSONEncoder().encode(["project": projects![index]]))
        }
      }
      if request.url?.path == "/api/v1/projects" {
        return HTTPResponse(data: try JSONEncoder().encode(["projects": projects!]))
      }
      if request.url?.path == "/api/v1/threads", request.httpMethod == "POST",
        let data = request.httpBody
      {
        let input = try JSONDecoder().decode(ApiCreateThread.self, from: data)
        var value = thread!
        value.id = "project-new-chat"
        value.title = "New conversation"
        value.messageCount = 0
        value.projectId = input.projectId
        value.projectName = projects?.first { $0.id == input.projectId }?.name
        thread = value
        deleted = false
        return HTTPResponse(data: try JSONEncoder().encode(["thread": value]), status: 201)
      }
      if request.url?.path == "/api/v1/threads" {
        var rows = try ScreenFixture.bootstrap(theme: theme).threads
        rows.removeAll { $0.id == thread?.id }
        if !deleted, let thread { rows.insert(thread, at: 0) }
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let archived = query.first { $0.name == "archived" }?.value == "true"
        rows = rows.filter { ($0.archivedAt != nil) == archived }
        if let project = query.first(where: { $0.name == "projectId" })?.value {
          rows = rows.filter { $0.projectId == project }
        }
        let value: JSONValue = .object([
          "threads": try TranscriptFixture.json(rows), "nextCursor": .null,
        ])
        return HTTPResponse(data: try JSONEncoder().encode(value))
      }
      let base = "/api/v1/threads/" + thread!.id
      if request.url?.path == base + "/compact" {
        return HTTPResponse(
          data: Data(
            #"{"status":"succeeded","operationId":"garden-compact","trigger":"manual","tokensBefore":4000,"tokensAfter":2000,"tokenCountsExact":true}"#
              .utf8))
      }
      if request.url?.path == base {
        if request.httpMethod == "DELETE" {
          deleted = true
          return HTTPResponse(data: Data(), status: 204)
        }
        if request.httpMethod == "PATCH", let data = request.httpBody {
          let patch = try JSONDecoder().decode(ApiPatchThread.self, from: data)
          if let title = patch.title { thread?.title = title }
          if let ids = patch.tagIds { thread?.tagIds = ids }
          switch patch.projectId {
          case .omitted: break
          case .null:
            thread?.projectId = nil
            thread?.projectName = nil
          case .value(let id):
            thread?.projectId = id
            thread?.projectName = projects?.first { $0.id == id }?.name
          }
          if let archived = patch.archived {
            thread?.archivedAt = archived ? ScreenFixture.stamp : nil
          }
          thread?.revision += 1
          return HTTPResponse(data: try JSONEncoder().encode(["thread": thread!]))
        }
        if deleted { return HTTPResponse(data: Data(), status: 404) }
        var messages = try ScreenFixture.messages()
        if wakeScenario == "wake-once", !messages.isEmpty {
          let marker = try JSONDecoder().decode(
            WebMessagePart.self,
            from: Data(
              #"{"type":"scheduled-wake","occurrenceId":"wake-occurrence-example","scheduledAt":"2031-05-14T09:00:00Z","firedAt":"2031-05-14T09:00:02Z","timezone":"UTC","message":"Review the fictional garden plan."}"#
                .utf8))
          messages[0].parts.insert(marker, at: 0)
        }
        let value: JSONValue = .object([
          "thread": try TranscriptFixture.json(thread!),
          "messages": try TranscriptFixture.json(messages),
          "messagesNextCursor": .null,
        ])
        return HTTPResponse(data: try JSONEncoder().encode(value))
      }
      return try ScreenFixture.response(request, theme: theme)
    }
  }
#endif
