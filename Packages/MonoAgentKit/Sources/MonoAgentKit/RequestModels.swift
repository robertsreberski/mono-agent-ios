// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ApiPatchAgent: Codable, Sendable, Equatable {
  public var pinned: Bool
  public init(pinned: Bool) { self.pinned = pinned }
}
public struct ApiPutRunDefaults: Codable, Sendable, Equatable {
  public var model: InputField<String>
  public var effort: InputField<String>
  public var context1M: InputField<Bool>
  public init(
    model: InputField<String>, effort: InputField<String>, context1M: InputField<Bool> = .omitted
  ) {
    self.model = model
    self.effort = effort
    self.context1M = context1M
  }
}
public struct ApiCreateThread: Codable, Sendable, Equatable {
  public var sourceId: String
  public var model: InputField<String>
  public var effort: InputField<String>
  public var projectId: String?
  public var context1M: InputField<Bool>
  public init(
    sourceId: String, model: InputField<String> = .omitted, effort: InputField<String> = .omitted,
    projectId: String? = nil, context1M: InputField<Bool> = .omitted
  ) {
    self.sourceId = sourceId
    self.model = model
    self.effort = effort
    self.projectId = projectId
    self.context1M = context1M
  }
}
public struct ApiPatchThread: Codable, Sendable, Equatable {
  public var tagIds: [String]?
  public var title: String?
  public var archived: Bool?
  public var model: InputField<String>
  public var effort: InputField<String>
  public var projectId: InputField<String>
  public var ifRunConfigUnset: Bool?
  public var context1M: InputField<Bool>
  public init(
    tagIds: [String]? = nil, title: String? = nil, archived: Bool? = nil,
    model: InputField<String> = .omitted, effort: InputField<String> = .omitted,
    projectId: InputField<String> = .omitted, ifRunConfigUnset: Bool? = nil,
    context1M: InputField<Bool> = .omitted
  ) {
    self.tagIds = tagIds
    self.title = title
    self.archived = archived
    self.model = model
    self.effort = effort
    self.projectId = projectId
    self.ifRunConfigUnset = ifRunConfigUnset
    self.context1M = context1M
  }
}
public struct ApiCreateTag: Codable, Sendable, Equatable {
  public var sourceId: String
  public var name: String
  public var color: String?
  public init(sourceId: String, name: String, color: String? = nil) {
    self.sourceId = sourceId
    self.name = name
    self.color = color
  }
}
public struct ApiPatchTag: Codable, Sendable, Equatable {
  public var name: String?
  public var color: String?
  public init(name: String? = nil, color: String? = nil) {
    self.name = name
    self.color = color
  }
}
public struct ApiCreateProject: Codable, Sendable, Equatable {
  public var sourceId: String
  public var name: String
  public var color: String?
  public var context: String?
  public init(sourceId: String, name: String, color: String? = nil, context: String? = nil) {
    self.sourceId = sourceId
    self.name = name
    self.color = color
    self.context = context
  }
}
public struct ApiPatchProject: Codable, Sendable, Equatable {
  public var color: String?
  public var name: String?
  public var context: String?
  public var archived: Bool?
  public init(
    color: String? = nil, name: String? = nil, context: String? = nil, archived: Bool? = nil
  ) {
    self.color = color
    self.name = name
    self.context = context
    self.archived = archived
  }
}
public struct ApiStartTurn: Codable, Sendable, Equatable {
  public var text: String?
  public var quote: WebQuote?
  public var attachmentIds: [String]?
  public var model: String?
  public var effort: String?
  public var context1M: InputField<Bool>
  public init(
    text: String? = nil, quote: WebQuote? = nil, attachmentIds: [String]? = nil,
    model: String? = nil, effort: String? = nil, context1M: InputField<Bool> = .omitted
  ) {
    self.text = text
    self.quote = quote
    self.attachmentIds = attachmentIds
    self.model = model
    self.effort = effort
    self.context1M = context1M
  }
}
public struct ApiStartSubmission: Codable, Sendable, Equatable {
  public var submissionId: String
  public var text: String?
  public var quote: WebQuote?
  public var attachmentIds: [String]?
  public var model: String?
  public var effort: String?
  public var context1M: InputField<Bool>
  public init(
    submissionId: String, text: String? = nil, quote: WebQuote? = nil,
    attachmentIds: [String]? = nil, model: String? = nil, effort: String? = nil,
    context1M: InputField<Bool> = .omitted
  ) {
    self.submissionId = submissionId
    self.text = text
    self.quote = quote
    self.attachmentIds = attachmentIds
    self.model = model
    self.effort = effort
    self.context1M = context1M
  }
}
public struct ApiLiveInput: Codable, Sendable, Equatable {
  public var text: String
  public init(text: String) { self.text = text }
}
public struct ApiCancel: Codable, Sendable, Equatable {
  public var origin: String?
  public init(origin: String? = nil) { self.origin = origin }
}
public struct ApiAnswerAsk: Codable, Sendable, Equatable {
  public var interactionId: String
  public var answers: [ChannelAskAnswer]
  public init(interactionId: String, answers: [ChannelAskAnswer]) {
    self.interactionId = interactionId
    self.answers = answers
  }
}
public struct ApiAuthStart: Codable, Sendable, Equatable {
  public var providerId: String
  public var authType: String
  public var strategy: String
  public init(providerId: String, authType: String, strategy: String) {
    self.providerId = providerId
    self.authType = authType
    self.strategy = strategy
  }
}
public struct ApiAuthInput: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var promptId: String
  public var value: String
  public init(promptId: String, value: String) {
    self.promptId = promptId
    self.value = value
  }
  public var description: String { "Provider authentication input (redacted)" }
  public var debugDescription: String { description }
}
public struct ApiAuthCheckStart: Codable, Sendable, Equatable {
  public var idempotencyKey: String
  public init(idempotencyKey: String) { self.idempotencyKey = idempotencyKey }
}
public struct ApiCronAction: Codable, Sendable, Equatable {
  public var idempotencyKey: String
  public var confirmationToken: String?
  public init(idempotencyKey: String, confirmationToken: String? = nil) {
    self.idempotencyKey = idempotencyKey
    self.confirmationToken = confirmationToken
  }
}
public struct ApiCronEnable: Codable, Sendable, Equatable {
  public var idempotencyKey: String
  public var confirmationToken: String?
  public var enabled: Bool
  public init(idempotencyKey: String, confirmationToken: String? = nil, enabled: Bool) {
    self.idempotencyKey = idempotencyKey
    self.confirmationToken = confirmationToken
    self.enabled = enabled
  }
}
public struct ApiCronReply: Codable, Sendable, Equatable {
  public var operationId: String
  public var snapshotKind: String
  public init(operationId: String, snapshotKind: String) {
    self.operationId = operationId
    self.snapshotKind = snapshotKind
  }
}
public struct ApiMcpAppRequest: Codable, Sendable, Equatable {
  public var method: String
  public var params: JSONValue?
  public var confirmed: Bool?
  public init(method: String, params: JSONValue? = nil, confirmed: Bool? = nil) {
    self.method = method
    self.params = params
    self.confirmed = confirmed
  }
}
public typealias ApiCreateWake = WebWakeScheduleDefinition
/// PUT flattens the definition alongside the optimistic-concurrency revision.
public struct ApiPutWake: Codable, Sendable, Equatable {
  public var expectedRevision: Int
  public var kind: String
  public var timezone: String
  public var localAt: String?
  public var days: [Int]?
  public var times: [String]?
  public var message: String?
  public var compactFirst: Bool?
  public init(expectedRevision: Int, definition: WebWakeScheduleDefinition) {
    self.expectedRevision = expectedRevision
    kind = definition.kind
    timezone = definition.timezone
    localAt = definition.localAt
    days = definition.days
    times = definition.times
    message = definition.message
    compactFirst = definition.compactFirst
  }
}
public struct ApiPatchWake: Codable, Sendable, Equatable {
  public var expectedRevision: Int
  public var state: String
  public init(expectedRevision: Int, state: String) {
    self.expectedRevision = expectedRevision
    self.state = state
  }
}
public struct ApiDeleteWake: Codable, Sendable, Equatable {
  public var expectedRevision: Int
  public init(expectedRevision: Int) { self.expectedRevision = expectedRevision }
}
public struct ApiCreateUpload: Codable, Sendable, Equatable {
  public var name: String
  public var contentType: String
  public var sizeBytes: Int?
  public init(name: String, contentType: String, sizeBytes: Int? = nil) {
    self.name = name
    self.contentType = contentType
    self.sizeBytes = sizeBytes
  }
}
public struct ApiPushSubscriptionInput: Codable, Sendable, Equatable {
  public struct Keys: Codable, Sendable, Equatable {
    public var p256dh: String
    public var auth: String
  }
  public var endpoint: String
  public var previousSubscriptionId: String?
  public var previousEndpoint: String?
  public var expirationTime: InputField<Double>
  public var keys: Keys
}
public struct ApiPushAck: Codable, Sendable, Equatable {
  public var subscriptionId: String
  public var ackToken: String
}

public struct ApiBootstrapQuery: Codable, Sendable, Equatable {
  public var sourceId: String?
  public var archived: Bool?
  public var limit: Int?
  public var scope: String?
  public init(
    sourceId: String? = nil, archived: Bool? = nil, limit: Int? = nil, scope: String? = nil
  ) {
    self.sourceId = sourceId
    self.archived = archived
    self.limit = limit
    self.scope = scope
  }
}
public struct ApiProviderQuery: Codable, Sendable, Equatable {
  public var provider: String?
  public init(provider: String? = nil) { self.provider = provider }
}
public struct ApiCronRunsQuery: Codable, Sendable, Equatable {
  public var limit: Int?
  public var before: String?
  public init(limit: Int? = nil, before: String? = nil) {
    self.limit = limit
    self.before = before
  }
}
public struct ApiModelsQuery: Codable, Sendable, Equatable {
  public var limit: Int?
  public var provider: String?
  public var q: String?
  public var cursor: String?
  public init(limit: Int? = nil, provider: String? = nil, q: String? = nil, cursor: String? = nil) {
    self.limit = limit
    self.provider = provider
    self.q = q
    self.cursor = cursor
  }
}
public struct ApiSourceQuery: Codable, Sendable, Equatable {
  public var sourceId: String
  public init(sourceId: String) { self.sourceId = sourceId }
}
public struct ApiThreadsQuery: Codable, Sendable, Equatable {
  public var sourceId: String
  public var archived: Bool
  public var scope: String?
  public var limit: Int?
  public var before: String?
  public var tagId: String?
  public var projectId: String?
  public init(
    sourceId: String, archived: Bool = false, scope: String? = nil, limit: Int? = nil,
    before: String? = nil, tagId: String? = nil, projectId: String? = nil
  ) {
    self.sourceId = sourceId
    self.archived = archived
    self.scope = scope
    self.limit = limit
    self.before = before
    self.tagId = tagId
    self.projectId = projectId
  }
}
public struct ApiSearchQuery: Codable, Sendable, Equatable {
  public var sourceId: String
  public var q: String?
  public var limit: Int?
  public var scope: String?
  public init(sourceId: String, q: String? = nil, limit: Int? = nil, scope: String? = nil) {
    self.sourceId = sourceId
    self.q = q
    self.limit = limit
    self.scope = scope
  }
}
public struct ApiFullQuery: Codable, Sendable, Equatable {
  public var full: String?
  public init(full: String? = nil) { self.full = full }
}
public struct ApiMessagesQuery: Codable, Sendable, Equatable {
  public var before: String?
  public var limit: Int?
  public var full: String?
  public init(before: String? = nil, limit: Int? = nil, full: String? = nil) {
    self.before = before
    self.limit = limit
    self.full = full
  }
}
public struct ApiCapabilityQuery: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var expires: String
  public var token: String
  public init(expires: String, token: String) {
    self.expires = expires
    self.token = token
  }
  public var description: String { "Capability (redacted)" }
  public var debugDescription: String { description }
}
public struct ApiDeleteThreadQuery: Codable, Sendable, Equatable {
  public var emptyOnly: Bool?
  public init(emptyOnly: Bool? = nil) { self.emptyOnly = emptyOnly }
}
public struct ApiEventsQuery: Codable, Sendable, Equatable {
  public var thread: String?
  public init(thread: String? = nil) { self.thread = thread }
}
