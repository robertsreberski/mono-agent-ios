// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Wire timestamps and opaque identifiers remain strings. String vocabularies intentionally
// tolerate additive server values; discriminated message/event unions are decoded separately.
public struct ApiEmpty: Codable, Sendable, Equatable { public init() {} }
public struct ApiHealth: Codable, Sendable, Equatable {
  public var status: String
  public var version: Int
  public var push: String
}
public typealias HealthResponse = ApiHealth
public struct ConsoleIdentity: Codable, Sendable, Equatable {
  public var hostName: String
  public var displayName: String
  public var theme: String
  public init(hostName: String, displayName: String, theme: String) {
    self.hostName = hostName
    self.displayName = displayName
    self.theme = theme
  }
}
public struct UploadLimits: Codable, Sendable, Equatable {
  public var maxFileBytes: Int
  public var maxFilesPerTurn: Int
  public var maxTurnBytes: Int
  public var accept: [String]
  public init(
    maxFileBytes: Int = 20 * 1024 * 1024, maxFilesPerTurn: Int = 10,
    maxTurnBytes: Int = 64 * 1024 * 1024, accept: [String]
  ) {
    self.maxFileBytes = maxFileBytes
    self.maxFilesPerTurn = maxFilesPerTurn
    self.maxTurnBytes = maxTurnBytes
    self.accept = accept
  }
}
public struct WebPushBootstrap: Codable, Sendable, Equatable {
  public var applicationServerKey: String
  public var keyFingerprint: String
  public var serviceWorkerVersion: Int
}
public struct ApiBootstrap: Codable, Sendable, Equatable {
  public var version: Int
  public var console: ConsoleIdentity
  public var push: WebPushBootstrap
  public var agents: [WebAgentSummary]
  public var threads: [WebThread]
  @RequiredNullable public var threadsSourceId: String?
  @RequiredNullable public var threadsNextCursor: String?
  public var tags: [WebTag]
  public var projects: [WebProject]
  @RequiredNullable public var projectsSourceId: String?
  public var activeThreads: WebActiveThreads?
  public var currentThreadId: String?
  public var limits: UploadLimits
}
public typealias BootstrapResponse = ApiBootstrap
public struct RunConfiguration: Codable, Sendable, Equatable {
  public var model: String?
  public var effort: String?
  public var context1M: Bool?
}
public struct EffectiveRunConfiguration: Codable, Sendable, Equatable {
  public var model: String?
  public var effort: String?
  public var context1M: Bool?
  public var modelSource: String
  public var effortSource: String
  public var context1MSource: String?
}
public struct WebAgentRunSettings: Codable, Sendable, Equatable {
  public var config: RunConfiguration
  @RequiredNullable public var override: RunConfiguration?
  public var effective: EffectiveRunConfiguration
}
public struct WebAgentRestartSupport: Codable, Sendable, Equatable {
  public var supported: Bool
  public var reason: String?
}
public struct WebCronCapability: Codable, Sendable, Equatable {
  public var read: Bool
  public var actions: Bool
}
public struct WebModelOption: Codable, Sendable, Equatable {
  public var effortLevels: [String]?
  public var effort: String?
  public var reasoning: Bool?
  public var reasoningMode: String?
  public var label: String?
  public var contextWindow: Double?
  public var supportsContext1M: Bool?
  public var context1M: Bool?
}
public struct WebAgentProvider: Codable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var configured: Bool?
}
public struct WebAgentSummary: Codable, Sendable, Equatable {
  public var sourceId: String
  public var generation: String?
  public var label: String
  public var status: String
  public var pinned: Bool?
  public var health: String?
  public var supportsAttachments: Bool
  public var restart: WebAgentRestartSupport?
  public var supportsProviderAuth: Bool?
  public var supportsManualCompaction: Bool?
  public var supportsProviderUsage: Bool?
  public var supportsProviderUsageRefresh: Bool?
  public var supportsProviderAuthChecks: Bool?
  public var models: [String]?
  public var defaultModel: String?
  public var defaultEffort: String?
  public var efforts: [String]?
  public var modelOptions: [String: WebModelOption]?
  public var runSettings: WebAgentRunSettings
  public var providers: [WebAgentProvider]?
  public var cron: WebCronCapability?
  public var supportsAskById: Bool?
  public var runningCount: Int?
  public var updatedAt: String
}
public struct WebAgentRestartOperation: Codable, Sendable, Equatable {
  public var id: String
  public var sourceId: String
  public var stage: String
  public var outcome: String?
  public var reason: String?
  public var requestedAt: String
  public var deadline: String
  public var approximateRunningTurns: Int?
}
public struct WebRunSelection: Codable, Sendable, Equatable {
  public var model: String?
  public var effort: String?
}
public struct WebRunExecution: Codable, Sendable, Equatable {
  public var model: String?
  public var effort: String?
  public var effectiveEffort: String?
}
public struct WebRunTransition: Codable, Sendable, Equatable {
  public var from: String
  public var to: String
  public var attemptIndex: Int?
  public var reason: String?
}
public struct WebRunRetry: Codable, Sendable, Equatable {
  public var model: String?
  public var retryIndex: Int?
  public var attempts: Int?
  public var reason: String?
}
public struct WebRunAttribution: Codable, Sendable, Equatable {
  public var requested: WebRunSelection
  public var attempted: WebRunExecution?
  public var executed: WebRunExecution?
  public var disposition: String
  public var transitions: [WebRunTransition]
  public var retries: [WebRunRetry]
  public var truncated: Bool?
}
public struct WebRunActivity: Codable, Sendable, Equatable {
  public var toolCallCount: Int
  public var phase: String
  public var cumulativeUsd: Double?
  public var knownCostUsd: Double?
  public var costUnknown: Bool?
  public var cost: CostAmount {
    .init(amount: cumulativeUsd, unknown: costUnknown, knownSpend: knownCostUsd)
  }
}
public struct RunError: Codable, Sendable, Equatable {
  public var code: String?
  public var message: String
}
public struct RunOutcome: Codable, Sendable, Equatable {
  public var status: String
  public var finishedAt: String?
}
public struct WebRunState: Codable, Sendable, Equatable {
  public var context1M: Bool?
  public var cancelOrigin: String?
  public var id: String?
  public var status: String
  public var startedAt: String?
  public var finishedAt: String?
  public var lastOutcome: RunOutcome?
  public var error: RunError?
  public var model: String?
  public var effort: String?
  public var attribution: WebRunAttribution?
  public var activity: WebRunActivity?
}
public struct WebJobActivity: Codable, Sendable, Equatable {
  public struct Terminal: Codable, Sendable, Equatable {
    public var state: String
    public var completedAt: String
    public var replyPreview: String?
  }
  public var queued: Int
  public var starting: Int
  public var running: Int
  public var latestTerminal: Terminal?
}
public struct ThreadCompaction: Codable, Sendable, Equatable {
  public var status: String
  public var trigger: String
  public var startedAt: String
}
public struct WakeSummary: Codable, Sendable, Equatable {
  public var state: String
  public var revision: Int
  public var nextFireAt: String?
  public var kind: String
  public var compactFirst: Bool?
}
public struct PendingProject: Codable, Sendable, Equatable {
  @RequiredNullable public var projectId: String?
  public var turnId: String
}
public struct WebThreadTrigger: Codable, Sendable, Equatable {
  public var kind: String
  public var jobId: String?
  public var configured: Bool?
}
public struct WebThread: Codable, Sendable, Equatable {
  public var compaction: ThreadCompaction?
  public var wakeSchedule: WakeSummary?
  public var id: String
  public var sourceId: String
  public var title: String
  @RequiredNullable public var archivedAt: String?
  public var createdAt: String
  public var updatedAt: String
  public var revision: Int
  public var readRevision: Int?
  public var tagIds: [String]
  @RequiredNullable public var projectId: String?
  public var projectName: String?
  public var pendingProject: PendingProject?
  public var trigger: WebThreadTrigger?
  public var lastMessagePreview: String?
  public var messageCount: Int
  public var runState: WebRunState
  public var jobActivity: WebJobActivity?
  public var canSend: Bool
  public var canUpload: Bool
  @RequiredNullable public var runModel: String?
  @RequiredNullable public var runEffort: String?
  public var runContext1M: Bool?
}
public struct WebTag: Codable, Sendable, Equatable {
  public var id: String
  public var sourceId: String
  public var name: String
  public var color: String
  public var createdAt: String
  public var updatedAt: String
  public var revision: Int
}
public struct WebExternalConversation: Codable, Sendable, Equatable {
  public var id: String
  public var channel: String
  public var label: String
  public var state: String
  @RequiredNullable public var projectId: String?
  public var lastSeenAt: String
}
public struct WebProject: Codable, Sendable, Equatable {
  public var color: String?
  public var id: String
  public var sourceId: String
  public var name: String
  public var context: String
  @RequiredNullable public var archivedAt: String?
  public var createdAt: String
  public var updatedAt: String
  public var revision: Int
  public var conversationCount: Int
  public var runningCount: Int
  public var monthUsd: Double?
  public var monthKnownUsd: Double?
  public var monthCostUnknown: Bool?
  public var external: WebExternalConversation?
  public var monthCost: CostAmount {
    .init(amount: monthUsd, unknown: monthCostUnknown, knownSpend: monthKnownUsd)
  }
}
public struct WebAttachment: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var contentType: String
  public var sizeBytes: Int
  public var kind: String
  public var status: String
  public var uploaded: Bool
  public var createdAt: String
  public var contentUrl: String?
}
public struct WebQuote: Codable, Sendable, Equatable {
  public var text: String
  public var messageId: String
  public init(text: String, messageId: String) {
    self.text = text
    self.messageId = messageId
  }
}
public struct WebMessage: Codable, Sendable, Equatable {
  public var id: String
  public var threadId: String
  public var turnId: String?
  public var role: String
  public var quote: WebQuote?
  public var parts: [WebMessagePart]
  public var attachments: [WebAttachment]
  public var createdAt: String
  public var updatedAt: String
  public var finishedAt: String?
  public var status: String
  public var liveInputStatus: String?
  public var attribution: WebRunAttribution?
  /// Optional for locally minted receipts, not a claim that server snapshots omit it.
  public var seq: Int?
}
public struct WebUsageTokens: Codable, Sendable, Equatable {
  public var input: Double
  public var cacheRead: Double
  public var cacheWrite: Double
  public var output: Double
}
public struct WebUsageSlice: Codable, Sendable, Equatable {
  public var tokens: WebUsageTokens?
  public var costUsd: Double?
  public var knownCostUsd: Double?
  public var costUnknown: Bool?
  public var tokensPartial: Bool?
  public var costPartial: Bool?
  public var requests: Int?
  public var requestsWithUsage: Int?
  public var runs: Int?
  public var runsWithTokens: Int?
  public var model: String?
  public var cost: CostAmount {
    .init(amount: costUsd, unknown: costUnknown, knownSpend: knownCostUsd)
  }
}
public struct WebThreadUsage: Codable, Sendable, Equatable {
  public var total: WebUsageSlice
  public var compaction: WebUsageSlice?
  public var subagents: WebUsageSlice?
  public var byModel: [WebUsageSlice]
  public var computedAt: String
  public var settledAssistantTurns: Int?
}
public struct WebThreadDetail: Codable, Sendable, Equatable {
  public var thread: WebThread
  public var messages: [WebMessage]
  public var messagesNextCursor: String?
}
public struct WebThreadPage: Codable, Sendable, Equatable {
  public var threads: [WebThread]
  public var nextCursor: String?
}
public struct WebMessagePage: Codable, Sendable, Equatable {
  public var messages: [WebMessage]
  public var nextCursor: String?
}
public struct WebActiveThreads: Codable, Sendable, Equatable {
  public var threads: [WebThread]
  public var total: Int
  public var truncated: Bool
  public var runningCounts: [String: Int]
}
public struct WebThreadSearchHit: Codable, Sendable, Equatable {
  public struct Match: Codable, Sendable, Equatable {
    public var messageId: String
    public var role: String
    public var createdAt: String
  }
  public var thread: WebThread
  public var snippet: String?
  public var messageMatches: Int
  public var titleMatch: Bool
  public var messageMatch: Match?
}
public struct WebThreadSearchPage: Codable, Sendable, Equatable {
  public var hits: [WebThreadSearchHit]
  public var truncated: Bool
}
public struct WebCatalogModel: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var provider: String
  public var providerLabel: String
  public var contextWindow: Double?
  public var supportsContext1M: Bool?
  public var context1M: Bool?
  public var reasoning: Bool?
  public var effortLevels: [String]?
  public var reasoningMode: String?
}
public struct WebModelPage: Codable, Sendable, Equatable {
  public var models: [WebCatalogModel]
  public var nextCursor: String?
  public var truncated: Bool
}
public struct WebSkillInfo: Codable, Sendable, Equatable {
  public var name: String
  public var description: String
  public var availability: String
  public var reference: String?
  public var unavailableReason: String?
}
public struct WebSkillRegistry: Codable, Sendable, Equatable {
  public var status: String
  public var items: [WebSkillInfo]
  public var total: Int?
  public var truncated: Bool?
}
public struct WebWakeScheduleDefinition: Codable, Sendable, Equatable {
  public var kind: String
  public var timezone: String
  public var localAt: String?
  public var days: [Int]?
  public var times: [String]?
  public var message: String?
  public var compactFirst: Bool?
  public init(
    kind: String, timezone: String, localAt: String? = nil, days: [Int]? = nil,
    times: [String]? = nil, message: String? = nil, compactFirst: Bool? = nil
  ) {
    self.kind = kind
    self.timezone = timezone
    self.localAt = localAt
    self.days = days
    self.times = times
    self.message = message
    self.compactFirst = compactFirst
  }
}
public struct WebWakeSchedule: Codable, Sendable, Equatable {
  public var scheduleId: String
  public var threadId: String
  public var sourceId: String
  public var definition: WebWakeScheduleDefinition
  public var state: String
  public var revision: Int
  @RequiredNullable public var nextFireAt: String?
  @RequiredNullable public var lastOutcome: String?
  public var createdAt: String
}
public struct WebSubmissionReceipt: Codable, Sendable, Equatable {
  public var submissionId: String
  public var threadId: String
  public var outcome: String
  public var reason: String?
  public var disposition: String?
  public var messageId: String?
  public var turnId: String?
  public var message: WebMessage?
  public var turn: WebRunState?
}
public struct WebLiveInputReceipt: Codable, Sendable, Equatable {
  public var message: WebMessage
  public var disposition: String
}
public struct WebPushSubscriptionStatus: Codable, Sendable, Equatable {
  public var id: String
  public var state: String
  public var keyFingerprint: String
  public var createdAt: String
  public var updatedAt: String
  public var lastSuccessAt: String?
  public var lastErrorAt: String?
  public var lastErrorCode: String?
}

extension WebAttachment: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "WebAttachment (private fields redacted)" }
  public var debugDescription: String { description }
}
