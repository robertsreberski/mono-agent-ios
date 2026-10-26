// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Per-instance, fail-closed restart operations. Never contacts or restarts a console.
  actor AgentRestartScript {
    let scenario: StoreScenario
    private var operation: WebAgentRestartOperation?
    private var number = 0
    init(_ scenario: StoreScenario) { self.scenario = scenario }
    func response(_ request: URLRequest) throws -> HTTPResponse? {
      let base = "/api/v1/agents/" + AgentSettingsFixture.atlas + "/restart"
      let method = request.httpMethod ?? "GET"
      switch (method, request.url?.path ?? "") {
      case ("GET", base):
        let json =
          try operation.map {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
          } ?? .null
        return HTTPResponse(data: try JSONEncoder().encode(JSONValue.object(["operation": json])))
      case ("POST", base):
        number += 1
        if scenario == .agentRestartUncertain { throw URLError(.networkConnectionLost) }
        var value: WebAgentRestartOperation = try AgentSettingsFixture.decode(
          #"{"id":"synthetic-restart-\#(number)","sourceId":"\#(AgentSettingsFixture.atlas)","stage":"restarting","requestedAt":"2030-01-02T12:00:00Z","deadline":"2030-01-02T12:02:00Z"}"#
        )
        switch scenario {
        case .agentRestartProgress: break
        case .agentRestartFailure:
          value.outcome = "failure"
          value.reason = "The sample agent could not relaunch."
        case .agentRestartNotConfirmed:
          value.outcome = "not_confirmed"
          value.reason = "The sample agent has not returned."
        default:
          value.outcome = "success"
          value.stage = "back_online"
        }
        operation = value
        return HTTPResponse(data: try JSONEncoder().encode(value))
      case ("GET", base + "/" + (operation?.id ?? "")):
        guard let operation else { throw URLError(.resourceUnavailable) }
        return HTTPResponse(data: try JSONEncoder().encode(operation))
      default: return nil
      }
    }
  }
#endif
