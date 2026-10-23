// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  enum RichReplyFixture {
    static func file(_ id: String, name: String) throws -> ReplyAttachmentPart {
      var part: ReplyAttachmentPart = try TranscriptFixture.decode(
        #"{"type":"attachment","id":"file","artifactId":"artifact","name":"report.txt","mediaType":"text/plain","sizeBytes":23,"integrityId":"sample-integrity"}"#
      )
      part.sizeBytes = bytes.count
      part.id = id
      part.artifactId = "artifact-" + id
      part.name = name
      return part
    }
    static let bytes = Data("Synthetic sample file.\n".utf8)
    static func files() throws -> [WebMessage] {
      var message = try TranscriptFixture.message(
        id: "sample-assistant", role: "assistant", text: "")
      message.parts = [
        .attachment(try file("report", name: "release-notes.txt")),
        .attachment(
          try file("long", name: "a-long-filename-for-the-synthetic-release-review-and-archive.txt")
        ),
        .attachment(try file("unavailable", name: "archive.txt")),
        try TranscriptFixture.decode(
          #"{"type":"failure","id":"missing","code":"reply_artifact_not_found","message":"The requested artifact was not found."}"#
        ),
        try TranscriptFixture.decode(
          #"{"type":"failure","id":"large","code":"reply_attachment_too_large","message":"The reply attachment is too large to download."}"#
        ),
      ]
      return [message]
    }
    static func response(_ request: URLRequest, scenario: StoreScenario) throws -> HTTPResponse? {
      guard scenario == .conversationReplyFiles, let url = request.url,
        url.path.contains("/reply-attachments/")
      else { return nil }
      let segments = url.path.split(separator: "/")
      guard segments.count == 9 else { return nil }
      let id = String(segments[7])
      if id == "unavailable" {
        return HTTPResponse(
          data: Data(#"{"error":{"code":"reply_part_not_found","message":"Unavailable"}}"#.utf8),
          status: 404)
      }
      if url.path.hasSuffix("/access") {
        var part = try file(
          id,
          name: id == "long"
            ? "a-long-filename-for-the-synthetic-release-review-and-archive.txt"
            : "release-notes.txt")
        part.sizeBytes = bytes.count
        part.contentUrl =
          url.path.replacingOccurrences(of: "/access", with: "/content")
          + "?expires=1&token=synthetic"
        return HTTPResponse(
          data: try JSONEncoder().encode(try TranscriptFixture.json(["part": part])))
      }
      return HTTPResponse(
        data: bytes, contentType: "text/plain",
        headers: ["x-mono-agent-integrity-id": "sample-integrity"])
    }
  }
#endif
