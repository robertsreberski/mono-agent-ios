// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Per-instance, stateful synthetic routes. Never reads a live console.
  actor OrganizeScript {
    var thread: WebThread?
    var deleted = false
    func response(_ request: URLRequest, theme: String) throws -> HTTPResponse {
      if thread == nil { thread = try ScreenFixture.bootstrap(theme: theme).threads[0] }
      let base = "/api/v1/threads/" + DashboardFixture.openThreadID
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
