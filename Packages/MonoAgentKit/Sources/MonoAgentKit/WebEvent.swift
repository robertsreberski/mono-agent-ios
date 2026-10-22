// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ReadyPayload: Codable, Sendable, Equatable { public var version: Int }
public struct AgentsChangedPayload: Codable, Sendable, Equatable {
  public var sourceId: String
  public var pinned: Bool
}
public struct CronChangedPayload: Codable, Sendable, Equatable {
  public var sourceId: String
  public var jobId: String?
}
public struct ThreadChangedPayload: Codable, Sendable, Equatable {
  public var thread: WebThread?
  public var threadId: String?
  public var removed: Bool?
}
public struct TagChangedPayload: Codable, Sendable, Equatable {
  public var tag: WebTag?
  public var tagId: String?
  public var removed: Bool?
}
public struct ProjectChangedPayload: Codable, Sendable, Equatable {
  public var project: WebProject?
  public var projectId: String?
  public var removed: Bool?
}
public struct MessageChangedPayload: Codable, Sendable, Equatable {
  public var messageId: String
  public var updatedAt: String
}
public struct TurnChangedPayload: Codable, Sendable, Equatable { public var turn: WebRunState }
public struct AttachmentChangedPayload: Codable, Sendable, Equatable {
  public var attachment: WebAttachment?
  public var attachmentId: String?
  public var removed: Bool?
}
public struct PushPendingPayload: Codable, Sendable, Equatable {
  public var eventId: String
  public var threadId: String
  public var ackToken: String
}

public enum WebEvent: Sendable, Equatable {
  case ready(ReadyPayload)
  case agentsChanged(AgentsChangedPayload?)
  case cronChanged(CronChangedPayload)
  case threadsChanged(ThreadChangedPayload?)
  case threadChanged(ThreadChangedPayload)
  case tagsChanged(TagChangedPayload)
  case projectsChanged(ProjectChangedPayload)
  case messageChanged(MessageChangedPayload)
  case messageDelta(WebMessageDelta)
  case turnChanged(TurnChangedPayload)
  case attachmentChanged(AttachmentChangedPayload)
  case pushPending(PushPendingPayload)
  public var name: String {
    switch self {
    case .ready: "ready"
    case .agentsChanged: "agents.changed"
    case .cronChanged: "cron.changed"
    case .threadsChanged: "threads.changed"
    case .threadChanged: "thread.changed"
    case .tagsChanged: "tags.changed"
    case .projectsChanged: "projects.changed"
    case .messageChanged: "message.changed"
    case .messageDelta: "message.delta"
    case .turnChanged: "turn.changed"
    case .attachmentChanged: "attachment.changed"
    case .pushPending: "push.pending"
    }
  }
  public static let names: Set<String> = [
    "ready", "agents.changed", "cron.changed", "threads.changed", "thread.changed", "tags.changed",
    "projects.changed", "message.changed", "message.delta", "turn.changed", "attachment.changed",
    "push.pending",
  ]
}
public struct ApiEvent: Codable, Sendable, Equatable {
  public var id: String
  public var version: Int
  public var at: String
  public var threadId: String?
  public var event: WebEvent
  private enum CodingKeys: String, CodingKey { case id, version, type, at, threadId, payload }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    version = try c.decode(Int.self, forKey: .version)
    at = try c.decode(String.self, forKey: .at)
    threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
    switch try c.decode(String.self, forKey: .type) {
    case "ready": event = .ready(try c.decode(ReadyPayload.self, forKey: .payload))
    case "agents.changed":
      event = .agentsChanged(try c.decodeIfPresent(AgentsChangedPayload.self, forKey: .payload))
    case "cron.changed":
      event = .cronChanged(try c.decode(CronChangedPayload.self, forKey: .payload))
    case "threads.changed":
      event = .threadsChanged(try c.decodeIfPresent(ThreadChangedPayload.self, forKey: .payload))
    case "thread.changed":
      event = .threadChanged(try c.decode(ThreadChangedPayload.self, forKey: .payload))
    case "tags.changed":
      event = .tagsChanged(try c.decode(TagChangedPayload.self, forKey: .payload))
    case "projects.changed":
      event = .projectsChanged(try c.decode(ProjectChangedPayload.self, forKey: .payload))
    case "message.changed":
      event = .messageChanged(try c.decode(MessageChangedPayload.self, forKey: .payload))
    case "message.delta":
      event = .messageDelta(try c.decode(WebMessageDelta.self, forKey: .payload))
    case "turn.changed":
      event = .turnChanged(try c.decode(TurnChangedPayload.self, forKey: .payload))
    case "attachment.changed":
      event = .attachmentChanged(try c.decode(AttachmentChangedPayload.self, forKey: .payload))
    case "push.pending":
      event = .pushPending(try c.decode(PushPendingPayload.self, forKey: .payload))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown event")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(version, forKey: .version)
    try c.encode(at, forKey: .at)
    try c.encodeIfPresent(threadId, forKey: .threadId)
    try c.encode(event.name, forKey: .type)
    switch event {
    case .ready(let v): try c.encode(v, forKey: .payload)
    case .agentsChanged(let v): try c.encodeIfPresent(v, forKey: .payload)
    case .cronChanged(let v): try c.encode(v, forKey: .payload)
    case .threadsChanged(let v): try c.encodeIfPresent(v, forKey: .payload)
    case .threadChanged(let v): try c.encode(v, forKey: .payload)
    case .tagsChanged(let v): try c.encode(v, forKey: .payload)
    case .projectsChanged(let v): try c.encode(v, forKey: .payload)
    case .messageChanged(let v): try c.encode(v, forKey: .payload)
    case .messageDelta(let v): try c.encode(v, forKey: .payload)
    case .turnChanged(let v): try c.encode(v, forKey: .payload)
    case .attachmentChanged(let v): try c.encode(v, forKey: .payload)
    case .pushPending(let v): try c.encode(v, forKey: .payload)
    }
  }
}
