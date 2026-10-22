// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct ApiAgent: Codable, Sendable, Equatable { public var agent: WebAgentSummary }
public struct ApiLatestRestart: Codable, Sendable, Equatable {
  public var operation: WebAgentRestartOperation?
}
public struct ApiCronConfig: Codable, Sendable, Equatable {
  public var configView: WebChannelConfigView
}
public struct ApiCronRun: Codable, Sendable, Equatable { public var message: WebMessage }
public struct CronRunValue: Codable, Sendable, Equatable { public var run: WebCronRunSummary }
public struct CronEnableValue: Codable, Sendable, Equatable { public var job: WebCronJob }
public struct ApiThread: Codable, Sendable, Equatable { public var thread: WebThread }
public struct ApiTags: Codable, Sendable, Equatable { public var tags: [WebTag] }
public struct ApiTag: Codable, Sendable, Equatable { public var tag: WebTag }
public struct ApiProjects: Codable, Sendable, Equatable { public var projects: [WebProject] }
public struct ApiProject: Codable, Sendable, Equatable { public var project: WebProject }
public struct ApiToolCall: Codable, Sendable, Equatable { public var part: WebMessagePart }
public struct ApiMessage: Codable, Sendable, Equatable { public var message: WebMessage }
public struct ApiThreadUsage: Codable, Sendable, Equatable { public var usage: WebThreadUsage }
public struct ApiAttachmentAccess: Codable, Sendable, Equatable {
  public var part: ReplyAttachmentPart
}
public struct ApiMcpAppAccess: Codable, Sendable, Equatable { public var part: McpAppPart }
public struct ApiMcpAppResult: Codable, Sendable, Equatable { public var result: JSONValue }
public struct ApiJob: Codable, Sendable, Equatable { public var job: ProcessJobProjection }
public struct ApiWakeSchedule: Codable, Sendable, Equatable {
  public var schedule: WebWakeSchedule?
}
public struct ApiStartedTurn: Codable, Sendable, Equatable {
  public var thread: WebThread
  public var turn: WebRunState
}
public struct ApiCancelled: Codable, Sendable, Equatable {
  public var cancelled: Bool
  public var thread: WebThread
}
public struct ApiAsk: Codable, Sendable, Equatable { public var ask: ChannelAskSnapshot? }
public struct ApiPushSubscription: Codable, Sendable, Equatable {
  public var subscription: WebPushSubscriptionStatus
}
public struct ApiUpload: Codable, Sendable, Equatable { public var attachment: WebAttachment }
public struct DeltaVector: Codable, Sendable, Equatable {
  public var name: String
  public var prev: [WebMessagePart]
  public var next: [WebMessagePart]
  public var ops: [WebMessageDeltaOp]
}
public struct ApiErrorBody: Codable, Sendable, Equatable {
  public enum Detail: Codable, Sendable, Equatable {
    case text(String)
    case coded(code: String, message: String)
    private enum CodingKeys: String, CodingKey { case code, message }
    public init(from decoder: any Decoder) throws {
      if let s = try? decoder.singleValueContainer().decode(String.self) {
        self = .text(s)
        return
      }
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self = .coded(
        code: try c.decode(String.self, forKey: .code),
        message: try c.decode(String.self, forKey: .message))
    }
    public func encode(to encoder: any Encoder) throws {
      switch self {
      case .text(let s):
        var c = encoder.singleValueContainer()
        try c.encode(s)
      case .coded(let code, let message):
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
      }
    }
  }
  public var error: Detail
}
public typealias ApiProviderUsage = ProviderUsageSnapshot
public typealias ApiRestart = WebAgentRestartOperation
public typealias ApiProviderAuth = ProviderAuthStatusSnapshot
public typealias ApiAuthSession = ProviderAuthSessionSnapshot
public typealias ApiAuthCheck = ProviderAuthCheckSessionSnapshot
public typealias ApiSkills = WebSkillRegistry
public typealias ApiCronOverview = WebCronOverview
public typealias ApiCronRuns = WebCronRunPage
public typealias ApiModels = WebModelPage
public typealias ApiCronReceipt = WebCronReplyReceipt
public typealias ApiCronRunResult = WebCronMutationResult<CronRunValue>
public typealias ApiCronEnableResult = WebCronMutationResult<CronEnableValue>
public typealias ApiThreadPage = WebThreadPage
public typealias ApiSearch = WebThreadSearchPage
public typealias ApiActiveThreads = WebActiveThreads
public typealias ApiThreadDetail = WebThreadDetail
public typealias ApiMessagePage = WebMessagePage
public typealias ApiMcpAppResource = AgentMcpAppResource
public typealias ApiCompaction = AgentManualCompactionResult
public typealias ApiSubmissionReceipt = WebSubmissionReceipt
public typealias ApiLiveInputReceipt = WebLiveInputReceipt
public typealias ApiAskResult = ChannelAskSubmissionResult
public typealias ApiDeltaVectors = [DeltaVector]
