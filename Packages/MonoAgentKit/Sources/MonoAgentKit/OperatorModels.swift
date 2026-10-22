// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ProviderUsageWindow: Codable, Sendable, Equatable {
  public var kind: String
  public var label: String
  public var usedPercent: Double
  public var resetsAt: String?
  public var periodMs: Double
}
public struct ProviderUsage: Codable, Sendable, Equatable {
  public var providerId: String
  public var label: String
  public var plan: String?
  public var windows: [ProviderUsageWindow]
  public var fetchedAt: String
  public var stale: Bool
  public var error: RunError?
}
public struct ProviderUsageSnapshot: Codable, Sendable, Equatable {
  public var schema: String
  public var providers: [ProviderUsage]
}
public struct ProviderAuthMethod: Codable, Sendable, Equatable {
  public var authType: String
  public var strategy: String
  public var label: String
  public var recommended: Bool
}
public struct ProviderAuthUsage: Codable, Sendable, Equatable {
  public var kind: String
  public var model: String
  public var label: String
}
public struct ProviderAuthProviderStatus: Codable, Sendable, Equatable {
  public struct Failure: Codable, Sendable, Equatable {
    public var kind: String
    public var message: String
    public var model: String?
    public var observedAt: String
  }
  public var providerId: String
  public var label: String
  public var usages: [ProviderAuthUsage]
  public var state: String
  public var credentialType: String?
  public var source: String?
  public var expiresAt: String?
  public var verification: String
  public var verifiedAt: String?
  public var methods: [ProviderAuthMethod]
  public var unavailableReason: String?
  public var lastFailure: Failure?
}
public struct ProviderAuthStatusSnapshot: Codable, Sendable, Equatable {
  public var schema: String
  public var generatedAt: String
  public var providers: [ProviderAuthProviderStatus]
}
public struct ProviderAuthPrompt: Codable, Sendable, Equatable {
  public struct Option: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var description: String?
  }
  public var id: String
  public var type: String
  public var message: String
  public var placeholder: String?
  public var allowEmpty: Bool?
  public var options: [Option]?
}
public struct ProviderAuthSessionSnapshot: Codable, Sendable, Equatable {
  public struct AuthURL: Codable, Sendable, Equatable {
    public var url: String
    public var instructions: String
  }
  public struct DeviceCode: Codable, Sendable, Equatable {
    public var verificationUri: String
    public var userCode: String
    public var expiresAt: String?
  }
  public var schema: String
  public var id: String
  public var providerId: String
  public var authType: String
  public var strategy: String
  public var state: String
  public var createdAt: String
  public var updatedAt: String
  public var expiresAt: String
  public var authUrl: AuthURL?
  public var deviceCode: DeviceCode?
  public var prompt: ProviderAuthPrompt?
  public var progress: String?
  public var error: RunError?
}
public struct ProviderAuthCheckResult: Codable, Sendable, Equatable {
  public var providerId: String
  public var label: String
  public var state: String
  public var model: String?
  public var selectionBasis: String?
  public var checkedAt: String?
  public var code: String?
  public var message: String?
}
public struct ProviderAuthCheckSessionSnapshot: Codable, Sendable, Equatable {
  public var schema: String
  public var id: String
  public var state: String
  public var createdAt: String
  public var updatedAt: String
  public var expiresAt: String
  public var results: [ProviderAuthCheckResult]
}
public struct ChannelAskOption: Codable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var description: String
}
public struct ChannelAskQuestion: Codable, Sendable, Equatable {
  public var id: String
  public var header: String
  public var question: String
  public var options: [ChannelAskOption]
  public var multiSelect: Bool
}
public struct ChannelAskAnswer: Codable, Sendable, Equatable {
  public var questionId: String
  public var selectedOptionIds: [String]
  public var customReply: String?
  public init(questionId: String, selectedOptionIds: [String], customReply: String? = nil) {
    self.questionId = questionId
    self.selectedOptionIds = selectedOptionIds
    self.customReply = customReply
  }
}
public struct ChannelAskSnapshot: Codable, Sendable, Equatable {
  public var interactionId: String
  public var message: String?
  public var questions: [ChannelAskQuestion]
  public var answers: [ChannelAskAnswer]
  public var activeQuestionIndex: Int
  public var status: String
  public var createdAt: String
  public var expiresAt: String?
}
public struct ChannelAskSubmissionResult: Codable, Sendable, Equatable {
  public var accepted: Bool
  public var code: String?
  public var snapshot: ChannelAskSnapshot?
}
public struct AgentReplyPartDeliveryOutcome: Codable, Sendable, Equatable {
  public var partIndex: Int
  public var partType: String
  public var status: String
  public var code: String
  public var message: String
  public var affectedPartCount: Int?
}
public struct WebCronRunSummary: Codable, Sendable, Equatable {
  public var runId: String
  public var jobId: String
  public var scheduledAt: String
  public var orderedAt: String
  public var sequence: Int
  public var trigger: String
  public var status: String
  public var turnDisposition: String?
  public var startedAt: String?
  public var completedAt: String?
  public var artifactRunId: String?
  public var text: String?
  public var error: String?
  public var failureKind: String?
  public var blockedByRunId: String?
  public var blockedByTrigger: String?
  public var queueDepth: Int?
  public var replyPartOutcomes: [AgentReplyPartDeliveryOutcome]?
  public var eventCount: Int
  public var fieldsTruncated: [String]?
  public var eventsTruncated: Bool?
  public var projection: String
}
public struct WebCronJob: Codable, Sendable, Equatable {
  public var jobId: String
  public var expression: String?
  public var timezone: String?
  public var conversationId: String
  public var configured: Bool
  public var declaredEnabled: Bool
  public var effectiveEnabled: Bool
  public var nextRunAt: String?
  public var health: String
  public var lastRun: WebCronRunSummary?
  public var activeRunId: String?
  public var threadId: String
}
public struct WebCronOverview: Codable, Sendable, Equatable {
  public var generatedAt: String
  public var actionsEnabled: Bool
  public var degradedReason: String?
  public var jobsTruncated: Bool?
  public var jobs: [WebCronJob]
}
public struct WebCronRunPage: Codable, Sendable, Equatable {
  public var runs: [WebCronRunSummary]
  public var nextCursor: String?
  public var messages: [WebMessage]?
}
public struct WebChannelConfigViewField: Codable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var value: String
  public var source: String
  public var redacted: Bool?
  public var envKey: String?
}
public struct WebChannelConfigView: Codable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var status: String
  public var fields: [WebChannelConfigViewField]
}
public struct WebCronReplyReceipt: Codable, Sendable, Equatable {
  public var operationId: String
  public var sourceId: String
  public var jobId: String
  public var runId: String
  public var duplicate: Bool
  public var thread: WebThread
  public var messages: [WebMessage]
}
public struct WebCronConfirmation: Codable, Sendable, Equatable {
  public var token: String
  public var expiresAt: String
  public var message: String
}
public enum WebCronMutationResult<Value: Codable & Sendable & Equatable>: Codable, Sendable,
  Equatable
{
  case confirmationRequired(WebCronConfirmation)
  case completed(value: Value, replayed: Bool)
  private enum CodingKeys: String, CodingKey { case kind, confirmation, value, replayed }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "confirmation_required":
      self = .confirmationRequired(try c.decode(WebCronConfirmation.self, forKey: .confirmation))
    case "completed":
      self = .completed(
        value: try c.decode(Value.self, forKey: .value),
        replayed: try c.decode(Bool.self, forKey: .replayed))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "Unknown cron result")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .confirmationRequired(let v):
      try c.encode("confirmation_required", forKey: .kind)
      try c.encode(v, forKey: .confirmation)
    case .completed(let v, let replayed):
      try c.encode("completed", forKey: .kind)
      try c.encode(v, forKey: .value)
      try c.encode(replayed, forKey: .replayed)
    }
  }
}
public struct WebCronReplyContextPart: Codable, Sendable, Equatable {
  public struct Source: Codable, Sendable, Equatable {
    public var sourceId: String
    public var jobId: String
    public var runId: String
  }
  public struct Run: Codable, Sendable, Equatable {
    public var sequence: Int
    public var trigger: String
    public var status: String
    public var scheduledAt: String
    public var orderedAt: String
    public var startedAt: String?
    public var completedAt: String?
    public var blockedByRunId: String?
    public var blockedByTrigger: String?
    public var queueDepth: Int?
  }
  public struct Snapshot: Codable, Sendable, Equatable {
    public var capturedAt: String
    public var kind: String
    public var sourceTruncationKnown: Bool
    public var sourceFieldsTruncated: [String]
    public var maxBytes: Int
    public var originalErrorBytes: Int
    public var retainedErrorBytes: Int
    public var originalResultBytes: Int
    public var retainedResultBytes: Int
    public var truncatedFields: [String]
  }
  public struct Result: Codable, Sendable, Equatable { public var text: String }
  public struct Failure: Codable, Sendable, Equatable {
    public var code: String?
    public var message: String?
  }
  public var type: String
  public var schema: String
  public var untrusted: Bool
  public var source: Source
  public var run: Run
  public var snapshot: Snapshot
  public var result: Result
  public var failure: Failure
  public var prefix: String
  public var rawJson: String
  public var rawText: String
}
public struct ProcessJobProjection: Codable, Sendable, Equatable {
  public struct Origin: Codable, Sendable, Equatable {
    public var conversationId: String
    public var channel: String
    public var runId: String
    public var historyBoundary: String
    public var bucket: String?
  }
  public struct Timestamps: Codable, Sendable, Equatable {
    public var admittedAt: String
    public var queueDeadlineAt: String
    public var startedAt: String?
    public var runtimeDeadlineAt: String?
    public var completedAt: String?
  }
  public struct Limits: Codable, Sendable, Equatable {
    public var maxRuntimeMs: Double
    public var maxOutputBytes: Int
    public var previewChars: Int
    public var chainDepth: Int
  }
  public struct Output: Codable, Sendable, Equatable {
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var truncated: Bool
    public var preview: String
    public var stdoutRef: String?
    public var stderrRef: String?
  }
  public struct Wake: Codable, Sendable, Equatable {
    public var state: String
    public var attempts: Int
    public var deliveryKey: String
    public var lastAttemptAt: String?
  }
  public struct Question: Codable, Sendable, Equatable {
    public var question: String
    public var options: [String]?
  }
  public var tool: String
  public var schema: String
  public var jobId: String
  public var state: String
  public var summary: String
  public var origin: Origin
  public var timestamps: Timestamps
  public var limits: Limits
  public var output: Output
  public var wake: Wake
  public var exitCode: Int?
  public var signal: String?
  public var durationMs: Double?
  public var cancelRequested: Bool
  public var lastError: RunError?
  public var kind: String?
  public var instanceId: String?
  public var childStillBusy: Bool?
  public var subagentProgress: ProcessJobSubagentProgress?
  public var subagentQuestion: Question?
  public var peerQuestion: PeerProcessJobQuestion?
}
public struct ProcessJobSubagentProgress: Codable, Sendable, Equatable {
  public struct Route: Codable, Sendable, Equatable {
    public var requested: WebRunSelection
    public var executed: WebRunExecution?
    public var disposition: String?
  }
  public struct Recent: Codable, Sendable, Equatable {
    public var id: String
    public var toolName: String
    public var argsSummary: String?
    public var workdir: String?
    public var status: String
    public var executionMs: Double?
  }
  public var revision: Int
  public var profile: String
  public var label: String?
  public var route: Route?
  public var toolCalls: Int
  public var failedCalls: Int
  public var costUsd: Double?
  public var knownCostUsd: Double?
  public var costUnknown: Bool?
  public var usage: WebUsageTokens?
  public var recent: [Recent]
  public var answerHead: String?
  public var answerTruncated: Bool?
}
public struct PeerProcessJobQuestion: Codable, Sendable, Equatable {
  public var state: String
  public var questionId: String
  public var peer: String
  public var thread: String
  public var message: String
  public var requestedSchema: [String: JSONValue]
  public var expiresAt: String
}
public struct AgentCompactionAccounting: Codable, Sendable, Equatable {
  public struct Request: Codable, Sendable, Equatable {
    public var requestId: String
    public var model: String?
    public var providerInvoked: Bool?
    public var status: String
    public var input: Double?
    public var output: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var costUsd: Double?
    public var costUnknown: Bool?
  }
  public var version: Int
  public var usageIncluded: Bool
  public var requests: [Request]
}
public struct AgentManualCompactionResult: Codable, Sendable, Equatable {
  public var status: String
  public var operationId: String
  public var trigger: String
  public var tokensBefore: Double?
  public var tokensAfter: Double?
  public var tokenCountsExact: Bool?
  public var accounting: AgentCompactionAccounting?
  public var reason: String?
}
public struct AgentMcpAppResource: Codable, Sendable, Equatable {
  public var app: McpAppPart
  public var html: String
  public var toolInput: JSONValue?
  public var toolResult: JSONValue?
  public var resourceMetadata: [String: JSONValue]?
  public var connected: Bool
}

extension ProviderAuthSessionSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "ProviderAuthSessionSnapshot (private fields redacted)" }
  public var debugDescription: String { description }
}

extension ProviderAuthPrompt: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "ProviderAuthPrompt (private fields redacted)" }
  public var debugDescription: String { description }
}

extension ProviderAuthStatusSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "ProviderAuthStatusSnapshot (private fields redacted)" }
  public var debugDescription: String { description }
}

extension ProviderAuthCheckSessionSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "ProviderAuthCheckSessionSnapshot (private fields redacted)" }
  public var debugDescription: String { description }
}
