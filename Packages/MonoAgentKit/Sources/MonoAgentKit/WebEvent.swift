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
    try self.init(envelope: WebEventEnvelope(from: decoder))
  }
  init(envelope: WebEventEnvelope) throws {
    id = envelope.id
    version = envelope.version
    at = envelope.at
    threadId = envelope.threadId
    func read<T: Decodable>(_ type: T.Type) throws -> T {
      try JSONDecoder().decode(type, from: JSONEncoder().encode(envelope.payload ?? .null))
    }
    func readOptional<T: Decodable>(_ type: T.Type) throws -> T? {
      guard let payload = envelope.payload, payload != .null else { return nil }
      return try read(type)
    }
    switch envelope.type {
    case "ready": event = .ready(try read(ReadyPayload.self))
    case "agents.changed":
      event = .agentsChanged(try readOptional(AgentsChangedPayload.self))
    case "cron.changed":
      event = .cronChanged(try read(CronChangedPayload.self))
    case "threads.changed":
      event = .threadsChanged(try readOptional(ThreadChangedPayload.self))
    case "thread.changed":
      event = .threadChanged(try read(ThreadChangedPayload.self))
    case "tags.changed":
      event = .tagsChanged(try read(TagChangedPayload.self))
    case "projects.changed":
      event = .projectsChanged(try read(ProjectChangedPayload.self))
    case "message.changed":
      event = .messageChanged(try read(MessageChangedPayload.self))
    case "message.delta":
      event = .messageDelta(try read(WebMessageDelta.self))
    case "turn.changed":
      event = .turnChanged(try read(TurnChangedPayload.self))
    case "attachment.changed":
      event = .attachmentChanged(try read(AttachmentChangedPayload.self))
    case "push.pending":
      event = .pushPending(try read(PushPendingPayload.self))
    default:
      throw StreamFailure.malformedEvent
    }
    guard event.isReadable else { throw StreamFailure.malformedEvent }
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

/// Envelope shape is validated independently of the event-specific payload.
struct WebEventEnvelope: Decodable {
  var id: String
  var version: Int
  var type: String
  var at: String
  var threadId: String?
  var payload: JSONValue?
}
extension WebEvent {
  var isReadable: Bool {
    switch self {
    case .ready(let value): return value.version == 1
    case .messageDelta(let value): return DeltaReducer.isReadable(value)
    case .threadChanged(let value):
      return value.thread != nil || (value.removed == true && value.threadId != nil)
    case .threadsChanged(let value):
      guard let value else { return true }
      return value.thread != nil || (value.removed == true && value.threadId != nil)
    case .tagsChanged(let value):
      return value.tag != nil || (value.removed == true && value.tagId != nil)
    case .projectsChanged(let value):
      return value.project != nil || (value.removed == true && value.projectId != nil)
    case .attachmentChanged(let value):
      return value.attachment != nil || (value.removed == true && value.attachmentId != nil)
    default: return true
    }
  }
}
