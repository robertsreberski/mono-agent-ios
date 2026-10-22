// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// DTO vocabulary exported by the schema. Live envelopes use `WebEvent` instead of
/// carrying this map: only the payload for that envelope's discriminator is decoded.
public struct ApiEventPayloadMap: Codable, Sendable, Equatable {
  public var ready: ReadyPayload
  public var agentsChanged: AgentsChangedPayload?
  public var cronChanged: CronChangedPayload
  public var threadsChanged: ThreadChangedPayload?
  public var threadChanged: ThreadChangedPayload
  public var tagsChanged: TagChangedPayload
  public var projectsChanged: ProjectChangedPayload
  public var messageChanged: MessageChangedPayload
  public var messageDelta: WebMessageDelta
  public var turnChanged: TurnChangedPayload
  public var attachmentChanged: AttachmentChangedPayload
  public var pushPending: PushPendingPayload
  private enum CodingKeys: String, CodingKey {
    case ready
    case agentsChanged = "agents.changed"
    case cronChanged = "cron.changed"
    case threadsChanged = "threads.changed"
    case threadChanged = "thread.changed"
    case tagsChanged = "tags.changed"
    case projectsChanged = "projects.changed"
    case messageChanged = "message.changed"
    case messageDelta = "message.delta"
    case turnChanged = "turn.changed"
    case attachmentChanged = "attachment.changed"
    case pushPending = "push.pending"
  }
}
