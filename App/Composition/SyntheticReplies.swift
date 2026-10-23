// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
  import MonoAgentKit
  import MonoAgentStore

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
    static func restarts() throws -> [WebMessage] {
      var message = try TranscriptFixture.message(
        id: "sample-assistant", role: "assistant", text: "")
      message.parts = [
        try TranscriptFixture.decode(
          #"{"type":"restart_proposal","id":"restart","reason":"Restart the sample agent to apply the update.","restartable":{"state":"available"}}"#
        ),
        try TranscriptFixture.decode(
          #"{"type":"restart_proposal","id":"unavailable-restart","reason":"This sample agent cannot restart here.","restartable":{"state":"unavailable","reason":"Restart is unavailable for this agent."}}"#
        ),
      ]
      return [message]
    }
    static func restartOperation(outcome: String? = nil) throws -> WebAgentRestartOperation {
      var value: WebAgentRestartOperation = try TranscriptFixture.decode(
        #"{"id":"sample-restart","sourceId":"atlas","stage":"restarting","requestedAt":"2030-01-02T12:00:00Z","deadline":"2030-01-02T12:02:00Z"}"#
      )
      value.sourceId = try TranscriptFixture.thread(.conversationRestartCard).sourceId
      value.outcome = outcome
      if outcome != nil { value.stage = "back_online" }
      return value
    }
    static func imageBytes(_ index: Int) throws -> Data {
      guard
        let context = CGContext(
          data: nil, width: 960, height: 720, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw ReplyImageError.invalid }
      context.setFillColor(
        CGColor(red: index == 0 ? 0.12 : 0.40, green: 0.48, blue: 0.42, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 720))
      context.setFillColor(CGColor(red: 0.92, green: 0.73, blue: 0.43, alpha: 1))
      context.fillEllipse(in: CGRect(x: 540, y: 340, width: 260, height: 260))
      context.setFillColor(CGColor(red: 0.09, green: 0.22, blue: 0.18, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 210))
      guard let image = context.makeImage() else { throw ReplyImageError.invalid }
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.png.identifier as CFString, 1, nil)
      else { throw ReplyImageError.invalid }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw ReplyImageError.invalid }
      return data as Data
    }
    static func imagePart(_ index: Int) throws -> ReplyAttachmentPart {
      var part = try file("image-\(index)", name: "sample-landscape-\(index + 1).png")
      part.mediaType = "image/png"
      part.sizeBytes = try imageBytes(index).count
      return part
    }
    static func images(_ scenario: StoreScenario) throws -> [WebMessage] {
      var message = try TranscriptFixture.message(
        id: "sample-assistant", role: "assistant", text: "Here are the sample landscapes.")
      let count =
        scenario == .conversationImagesEmpty ? 0 : scenario == .conversationImagesSingle ? 1 : 3
      if count == 0 { message.parts = [.text(.init(text: "No images attached."))] }
      message.parts += try (0..<count).map { .attachment(try imagePart($0)) }
      return [message]
    }
    static func response(_ request: URLRequest, scenario: StoreScenario) throws -> HTTPResponse? {
      if scenario == .conversationRestartCard, let path = request.url?.path {
        if path.hasSuffix("/parts/restart/restart"), request.httpMethod == "POST" {
          return HTTPResponse(data: try JSONEncoder().encode(restartOperation()))
        }
        if path.hasSuffix("/restart/sample-restart") {
          return HTTPResponse(data: try JSONEncoder().encode(restartOperation(outcome: "success")))
        }
      }
      guard scenario == .conversationReplyFiles || scenario.isReplyImageScenario,
        let url = request.url,
        url.path.contains("/reply-attachments/")
      else { return nil }
      let segments = url.path.split(separator: "/")
      guard segments.count == 9 else { return nil }
      let id = String(segments[7])
      if scenario.isReplyImageScenario {
        let index = Int(id.replacingOccurrences(of: "image-", with: "")) ?? 0
        if url.path.hasSuffix("/access") {
          var part = try imagePart(index)
          part.contentUrl =
            url.path.replacingOccurrences(of: "/access", with: "/content")
            + "?expires=1&token=synthetic"
          return HTTPResponse(
            data: try JSONEncoder().encode(try TranscriptFixture.json(["part": part])))
        }
        return HTTPResponse(
          data: try imageBytes(index), contentType: "image/png",
          headers: ["x-mono-agent-integrity-id": "sample-integrity"])
      }
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
