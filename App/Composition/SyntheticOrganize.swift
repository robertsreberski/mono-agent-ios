// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Per-instance, stateful synthetic routes. Never reads a live console.
  actor OrganizeScript {
    var thread: WebThread?
    var deleted = false
    var projects: [WebProject]?
    func response(_ request: URLRequest, theme: String) throws -> HTTPResponse {
      if thread == nil { thread = try ScreenFixture.bootstrap(theme: theme).threads[0] }
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
        let value: JSONValue = .object([
          "thread": try TranscriptFixture.json(thread!),
          "messages": try TranscriptFixture.json(ScreenFixture.messages()),
          "messagesNextCursor": .null,
        ])
        return HTTPResponse(data: try JSONEncoder().encode(value))
      }
      return try ScreenFixture.response(request, theme: theme)
    }
  }
#endif
