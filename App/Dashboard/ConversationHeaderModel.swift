// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit

/// Header and dashboard describe the same held thread and confirmation evidence.
enum ConversationHeaderModel {
  static func status(_ thread: WebThread, confirmed: Bool) -> (kind: StatusKind, label: String) {
    if thread.runState.status == "running" {
      return confirmed
        ? (
          .connecting,
          thread.runState.activity?.phase == "asking" ? "Asking you a question" : "Running"
        )
        : (.stale, "Last known running")
    }
    if DashboardModel.presentation(thread).active {
      return confirmed
        ? (.connecting, "Background jobs active") : (.stale, "Last known background jobs")
    }
    if let error = DashboardModel.outcomeError(thread) { return (.failed, error) }
    return (.disconnected, "Idle")
  }
  static func hasReportedModel(_ attribution: WebRunAttribution) -> Bool {
    [attribution.executed?.model, attribution.attempted?.model].contains { $0?.isEmpty == false }
  }
  struct Route: Equatable {
    var model: String?
    var effort: String?
    var provenance: String
    var label: String { model ?? "Model not reported" }
    var detail: String { provenance + " · " + TranscriptPresentation.route(model, effort) }
  }
  static func route(_ thread: WebThread, agent: WebAgentSummary?, latest: WebRunAttribution?)
    -> Route
  {
    func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    func reported(_ value: WebRunAttribution?) -> (String?, String?) {
      for route in [value?.executed, value?.attempted] {
        if let model = nonempty(route?.model) {
          return (model, nonempty(route?.effectiveEffort) ?? nonempty(route?.effort))
        }
      }
      return (nil, nil)
    }
    let run = reported(thread.runState.attribution)
    let message = reported(latest)
    let model: String?
    let effort: String?
    let provenance: String
    if let override = nonempty(thread.runModel) {
      model = override
      effort = nonempty(thread.runEffort) ?? nonempty(agent?.modelOptions?[override]?.effort)
      provenance = "Current settings · conversation override"
    } else if let known = nonempty(thread.runState.model) ?? run.0 {
      model = known
      effort = nonempty(thread.runEffort) ?? nonempty(thread.runState.effort) ?? run.1
      provenance = "Latest reported thread route"
    } else if let known = message.0 {
      model = known
      effort = nonempty(thread.runEffort) ?? message.1
      provenance = "Latest reported message route"
    } else {
      model = nonempty(agent?.runSettings.effective.model)
      effort = nonempty(thread.runEffort) ?? nonempty(agent?.runSettings.effective.effort)
      provenance = model == nil ? "No route reported" : "Inherited agent defaults"
    }
    return Route(
      model: model, effort: effort,
      provenance: provenance + (agent == nil ? " · agent unavailable" : ""))
  }
}
