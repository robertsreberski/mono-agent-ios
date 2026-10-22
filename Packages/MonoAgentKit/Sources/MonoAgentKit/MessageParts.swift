// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct TextPart: Codable, Sendable, Equatable {
  public var type: String
  public var text: String
  public var interruptedQuestion: Bool?
  public init(type: String = "text", text: String, interruptedQuestion: Bool? = nil) {
    self.type = type
    self.text = text
    self.interruptedQuestion = interruptedQuestion
  }
}
public struct SessionToolHistoryEventMetadata: Codable, Sendable, Equatable {
  public struct Artifact: Codable, Sendable, Equatable {
    public var id: String
    public var available: Bool
  }
  public var recordId: String?
  public var sequence: Int?
  public var persistence: String
  public var terminalState: String?
  public var truncated: Bool?
  public var originalBytes: Int?
  public var retainedBytes: Int?
  public var artifactReferences: [Artifact]?
  public var errorCode: String?
  public var untrusted: Bool
}
public struct WebToolCall: Codable, Sendable, Equatable {
  public var type: String?
  public var toolCallId: String
  public var toolName: String?
  public var name: String?
  public var label: String?
  public var args: JSONValue?
  public var result: JSONValue?
  public var structuredResult: JSONValue?
  public var status: String
  public var executionMs: Double?
  public var history: SessionToolHistoryEventMetadata?
  public var resultTruncated: Bool?
  public var resultBytes: Int?
  public var resultDigest: String?
  public var argsTruncated: Bool?
  public var argsBytes: Int?
  public var argsDigest: String?
  public var calls: [WebToolCall]?
  public var costUsd: Double?
  public var knownCostUsd: Double?
  public var costUnknown: Bool?
  public var usage: WebUsageTokens?
  public var attribution: WebRunAttribution?
}
public struct ReplyOptionsPart: Codable, Sendable, Equatable {
  public var type: String
  public var id: String
  public var options: [String]
}
public struct RestartProposalPart: Codable, Sendable, Equatable {
  public struct Availability: Codable, Sendable, Equatable {
    public var state: String
    public var reason: String?
    public var operationId: String?
  }
  public var type: String
  public var id: String
  public var reason: String?
  public var restartable: Availability?
}
public struct WebRouteSelection: Codable, Sendable, Equatable {
  public var model: String?
  public var effort: String?
}
public struct WebProjectIdentity: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var color: String
}
public enum MarkerValue: Codable, Sendable, Equatable {
  case route(WebRouteSelection)
  case project(WebProjectIdentity)
  case null
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let p = try? c.decode(WebProjectIdentity.self) {
      self = .project(p)
    } else {
      self = .route(try c.decode(WebRouteSelection.self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .route(let v): try v.encode(to: encoder)
    case .project(let v): try v.encode(to: encoder)
    case .null:
      var c = encoder.singleValueContainer()
      try c.encodeNil()
    }
  }
}
public struct WebConversationMarkerPart: Codable, Sendable, Equatable {
  public var type: String
  public var at: String
  public var kind: String
  public var before: MarkerValue?
  public var after: MarkerValue?
  public var previousMessageAt: String?
  public var idleMs: Double?
  public var operationId: String?
  public var trigger: String?
  public var status: String?
  public var tokensBefore: Double?
  public var tokensAfter: Double?
  public var tokenCountsExact: Bool?
  public var reason: String?
}
public struct ProcessJobPart: Codable, Sendable, Equatable {
  public var type: String
  public var job: ProcessJobProjection
  public var responseText: String?
}
public struct ScheduledWakePart: Codable, Sendable, Equatable {
  public var type: String
  public var occurrenceId: String
  public var scheduledAt: String
  public var firedAt: String
  public var timezone: String
  public var message: String?
}
public struct ProcessJobWakePart: Codable, Sendable, Equatable {
  public var type: String
  public var jobId: String
  public var deliveryKey: String
  public var disposition: String
}
public struct SteerPart: Codable, Sendable, Equatable {
  public var type: String
  public var inputId: String
  public var messageId: String
  public var text: String
  public var receivedAt: String?
  public var quote: WebQuote?
}
public struct TelemetryPart: Codable, Sendable, Equatable {
  public var type: String
  public var event: String
  public var kind: String?
  public var data: JSONValue?
}
public struct ErrorPart: Codable, Sendable, Equatable {
  public var type: String
  public var code: String?
  public var message: String
}
public struct ReplyAttachmentPart: Codable, Sendable, Equatable {
  public var type: String
  public var id: String
  public var artifactId: String
  public var name: String
  public var mediaType: String
  public var sizeBytes: Int
  public var integrityId: String
  public var expiresAt: String?
  public var storedUrl: String?
  public var contentUrl: String?
}
public struct McpAppPart: Codable, Sendable, Equatable {
  public var type: String
  public var id: String
  public var invocationId: String
  public var connectionId: String
  public var serverName: String
  public var toolName: String
  public var resourceUri: String
  public var mediaType: String
  public var protocolVersion: String
  public var title: String?
  public var description: String?
  public var expiresAt: String?
  public var resourceUrl: String?
  public var bridgeUrl: String?
}
public struct FailurePart: Codable, Sendable, Equatable {
  public var type: String
  public var id: String
  public var code: String
  public var message: String
  public var relatedPartId: String?
}

public enum WebMessagePart: Codable, Sendable, Equatable {
  case text(TextPart)
  case reasoning(TextPart)
  case replyOptions(ReplyOptionsPart)
  case restartProposal(RestartProposalPart)
  case conversationMarker(WebConversationMarkerPart)
  case cronReplyContext(WebCronReplyContextPart)
  case toolCall(WebToolCall)
  case subagent(WebToolCall)
  case processJob(ProcessJobPart)
  case scheduledWake(ScheduledWakePart)
  case processJobWake(ProcessJobWakePart)
  case steer(SteerPart)
  case telemetry(TelemetryPart)
  case error(ErrorPart)
  case attachment(ReplyAttachmentPart)
  case mcpApp(McpAppPart)
  case failure(FailurePart)
  case unknown(JSONValue)

  private enum CodingKeys: String, CodingKey { case type }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "text": self = .text(try TextPart(from: decoder))
    case "reasoning": self = .reasoning(try TextPart(from: decoder))
    case "reply_options": self = .replyOptions(try ReplyOptionsPart(from: decoder))
    case "restart_proposal": self = .restartProposal(try RestartProposalPart(from: decoder))
    case "conversation-marker":
      self = .conversationMarker(try WebConversationMarkerPart(from: decoder))
    case "cron-reply-context": self = .cronReplyContext(try WebCronReplyContextPart(from: decoder))
    case "tool-call": self = .toolCall(try WebToolCall(from: decoder))
    case "subagent": self = .subagent(try WebToolCall(from: decoder))
    case "process-job": self = .processJob(try ProcessJobPart(from: decoder))
    case "scheduled-wake": self = .scheduledWake(try ScheduledWakePart(from: decoder))
    case "process-job-wake": self = .processJobWake(try ProcessJobWakePart(from: decoder))
    case "steer": self = .steer(try SteerPart(from: decoder))
    case "telemetry": self = .telemetry(try TelemetryPart(from: decoder))
    case "error": self = .error(try ErrorPart(from: decoder))
    case "attachment": self = .attachment(try ReplyAttachmentPart(from: decoder))
    case "mcp_app": self = .mcpApp(try McpAppPart(from: decoder))
    case "failure": self = .failure(try FailurePart(from: decoder))
    default: self = .unknown(try JSONValue(from: decoder))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .text(let v), .reasoning(let v): try v.encode(to: encoder)
    case .replyOptions(let v): try v.encode(to: encoder)
    case .restartProposal(let v): try v.encode(to: encoder)
    case .conversationMarker(let v): try v.encode(to: encoder)
    case .cronReplyContext(let v): try v.encode(to: encoder)
    case .toolCall(let v), .subagent(let v): try v.encode(to: encoder)
    case .processJob(let v): try v.encode(to: encoder)
    case .scheduledWake(let v): try v.encode(to: encoder)
    case .processJobWake(let v): try v.encode(to: encoder)
    case .steer(let v): try v.encode(to: encoder)
    case .telemetry(let v): try v.encode(to: encoder)
    case .error(let v): try v.encode(to: encoder)
    case .attachment(let v): try v.encode(to: encoder)
    case .mcpApp(let v): try v.encode(to: encoder)
    case .failure(let v): try v.encode(to: encoder)
    case .unknown(let v): try v.encode(to: encoder)
    }
  }
}

extension ReplyAttachmentPart: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "ReplyAttachmentPart (private fields redacted)" }
  public var debugDescription: String { description }
}

extension McpAppPart: CustomDebugStringConvertible {
  public var debugDescription: String { "McpAppPart (private fields redacted)" }
}

extension KeyedDecodingContainer {
  public func decodeIfPresent(_ type: MarkerValue.Type, forKey key: Key) throws -> MarkerValue? {
    contains(key) ? try decode(type, forKey: key) : nil
  }
}
