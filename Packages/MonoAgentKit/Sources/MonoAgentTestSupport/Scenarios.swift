// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  public enum Scenario: String, CaseIterable, Sendable {
    case connectionEmpty = "connection-empty"
    case connectionFailed = "connection-failed"
    case consoleOnline = "console-online"

    public var steps: [ScriptedTransport.Step] {
      switch self {
      case .connectionEmpty: []
      case .connectionFailed: [.failure(.cannotConnectToHost)]
      case .consoleOnline: [.response(Self.health), .response(Self.bootstrap)]
      }
    }

    public static let endpoint = try! ConsoleEndpoint("https://console.example.ts.net")
    public static let health = HTTPResponse(
      data: Data(#"{"status":"ok","version":1,"push":"ok"}"#.utf8))
    public static let bootstrap = HTTPResponse(
      data: Data(
        #"{"version":1,"console":{"hostName":"console.example.ts.net","displayName":"Flockbox","theme":"evergreen"},"push":{"applicationServerKey":"fictional-public-key","keyFingerprint":"example","serviceWorkerVersion":2},"agents":[{"sourceId":"agent-example","label":"Example agent","status":"online","pinned":false,"supportsAttachments":true,"runSettings":{"config":{},"override":null,"effective":{"modelSource":"config","effortSource":"config"}},"updatedAt":"2030-01-02T12:00:00.000Z"}],"threads":[{"id":"thread-example","sourceId":"agent-example","title":"Morgan's sample project","archivedAt":null,"projectId":null,"tagIds":[],"createdAt":"2030-01-02T12:00:00.000Z","updatedAt":"2030-01-02T12:00:00.000Z","revision":1,"messageCount":3,"runState":{"status":"idle"},"canSend":true,"canUpload":true,"runModel":null,"runEffort":null}],"threadsSourceId":"agent-example","threadsNextCursor":null,"tags":[{"id":"tag-example","sourceId":"agent-example","name":"Examples","color":"blue","createdAt":"2030-01-02T12:00:00.000Z","updatedAt":"2030-01-02T12:00:00.000Z","revision":1}],"projects":[{"id":"project-example","sourceId":"agent-example","name":"Sample project","context":"Fictional examples only.","archivedAt":null,"createdAt":"2030-01-02T12:00:00.000Z","updatedAt":"2030-01-02T12:00:00.000Z","revision":1,"conversationCount":1,"runningCount":0,"monthCostUnknown":true,"monthKnownUsd":0.02}],"projectsSourceId":"agent-example","limits":{"maxFileBytes":20971520,"maxFilesPerTurn":10,"maxTurnBytes":67108864,"accept":["text/plain"]}}"#
          .utf8
      ))
  }

  /// Per-instance scripts: exhaustion fails closed and can never fall through to a real session.
  public actor ScriptedTransport: HTTPTransport {
    public enum Step: Sendable {
      case response(HTTPResponse)
      case failure(URLError.Code)
    }
    public private(set) var requests: [URLRequest] = []
    private var steps: [Step]
    public init(_ steps: [Step]) { self.steps = steps }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
      requests.append(request)
      guard !steps.isEmpty else { throw URLError(.resourceUnavailable) }
      switch steps.removeFirst() {
      case .response(let response): return response
      case .failure(let code): throw URLError(code)
      }
    }
  }

  public struct FixtureEnvironment: Sendable {
    public let now: Date
    public let identifier: UUID
    public let directory: URL
    public init(directory: URL) {
      now = Date(timeIntervalSince1970: 1_700_000_000)
      identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
      self.directory = directory
    }
  }
#endif
