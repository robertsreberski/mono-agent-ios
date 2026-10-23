// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

struct ModelEffortOption: Equatable, Identifiable {
  let id: String
  let name: String
}

/// One model row. `id == ""` is the automatic row ("let the agent pick").
struct ModelOption: Equatable, Identifiable {
  let id: String
  let name: String
  let detail: String
  let efforts: [ModelEffortOption]
  var providerLabel: String?
  var isAgentDefault = false
  /// Present when the row cannot be chosen, or is kept only because the conversation uses it.
  var note: String?
  var selectable = true
}

/// Port of the web console's `effort-ladder.ts` and `model-catalog.ts` for the configured
/// shortlist. Provider catalog paging (`/agents/:id/models`) stays on the web console; those
/// providers appear as explained, non-selectable rows.
enum ModelOptions {
  static let globalEffortLevels = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ]
  static let toggleEffortLevels = ["high", "none"]

  static func effortName(_ effort: String) -> String {
    [
      "none": "Off", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High",
      "xhigh": "Extra high", "max": "Max", "ultra": "Ultra",
    ][effort] ?? effort
  }

  /// Mirrors `advertisedEffortLevels`; `nil` means the advertisement said nothing.
  static func advertisedLevels(_ option: WebModelOption?) -> [String]? {
    guard let option else { return nil }
    if option.reasoning == false || option.reasoningMode == "none" { return [] }
    if option.effortLevels?.isEmpty == true { return [] }
    if option.reasoningMode == "toggle" { return toggleEffortLevels }
    if let levels = option.effortLevels { return levels }
    if option.reasoningMode == "effort" { return globalEffortLevels }
    if option.reasoning != nil { return [] }
    return nil
  }

  /// Mirrors `effectiveModelForAgent`: blank means the agent default, then its first route.
  static func effectiveModel(_ agent: WebAgentSummary, _ model: String) -> String? {
    if !model.isEmpty { return model }
    if let value = agent.defaultModel, !value.isEmpty { return value }
    return agent.models?.first
  }

  /// Mirrors `effortLevelsForModel` without provider catalog levels.
  static func effortLevels(_ agent: WebAgentSummary, _ model: String?) -> [String] {
    if let advertised = advertisedLevels(model.flatMap { agent.modelOptions?[$0] }) {
      return advertised
    }
    if agent.modelOptions == nil { return agent.efforts ?? globalEffortLevels }
    return globalEffortLevels
  }

  /// Mirrors `inheritedEffortForModel`. Swift decoding cannot tell an explicit `null` route
  /// effort from an absent one, so both use the capability rule (the older-agent behaviour).
  static func inheritedEffort(_ agent: WebAgentSummary, _ model: String, defaultEffort: String?)
    -> String?
  {
    let effective = effectiveModel(agent, model)
    let primary = agent.defaultModel.flatMap { $0.isEmpty ? nil : $0 } ?? agent.models?.first
    guard let effective, effective != primary else { return defaultEffort }
    let advertisement = agent.modelOptions?[effective]
    if let pinned = advertisement?.effort { return pinned }
    guard let defaultEffort else { return nil }
    guard let advertisement else { return defaultEffort }
    if advertisement.reasoning == false || advertisement.reasoningMode == "none" { return nil }
    if advertisement.effortLevels?.isEmpty == true { return nil }
    if advertisement.reasoningMode == "toggle" {
      return toggleEffortLevels.contains(defaultEffort) ? defaultEffort : nil
    }
    if let levels = advertisement.effortLevels {
      return levels.contains(defaultEffort) ? defaultEffort : nil
    }
    return defaultEffort
  }

  static func effortOptions(_ agent: WebAgentSummary, model: String) -> [ModelEffortOption] {
    let effective = effectiveModel(agent, model) ?? ""
    let toggle = agent.modelOptions?[effective]?.reasoningMode == "toggle"
    let levels = effortLevels(agent, effective)
    guard !levels.isEmpty else { return [] }
    let inherited = inheritedEffort(agent, model, defaultEffort: agent.defaultEffort)
    let defaultName: String =
      if let inherited {
        toggle ? (inherited == "none" ? "Off" : "On") : effortName(inherited)
      } else {
        "Provider"
      }
    return [ModelEffortOption(id: "", name: "Default · " + defaultName)]
      + levels.map {
        ModelEffortOption(id: $0, name: toggle ? ($0 == "none" ? "Off" : "On") : effortName($0))
      }
  }

  static func providerOf(_ model: String) -> String {
    let colon = model.firstIndex(of: ":")
    let slash = model.firstIndex(of: "/")
    if let colon, colon > model.startIndex, slash == nil || colon < slash! {
      return String(model[..<colon])
    }
    if let slash, slash > model.startIndex { return String(model[..<slash]) }
    return model
  }

  /// Mirrors `buildSelectorModels` for the shortlist: the automatic row first, then the
  /// configured routes in advertised order, then a kept conversation override that is no longer
  /// listed, then explained rows for catalog-only providers.
  static func rows(_ agent: WebAgentSummary, selectedModel: String) -> [ModelOption] {
    let shortlist = agent.models ?? []
    func label(_ reference: String?) -> String? {
      guard let reference, !reference.isEmpty else { return nil }
      return agent.modelOptions?[reference]?.label ?? reference
    }
    func providerLabel(_ reference: String) -> String {
      let provider = providerOf(reference)
      return agent.providers?.first { $0.id == provider }?.label ?? provider
    }
    var rows = [
      ModelOption(
        id: "", name: "Default · " + (label(agent.defaultModel) ?? "agent"),
        detail: agent.defaultModel.map { "Agent default · " + $0 } ?? "Use the agent default",
        efforts: effortOptions(agent, model: ""))
    ]
    for reference in shortlist {
      rows.append(
        ModelOption(
          id: reference, name: label(reference) ?? reference, detail: reference,
          efforts: effortOptions(agent, model: reference),
          providerLabel: providerLabel(reference),
          isAgentDefault: reference == agent.defaultModel))
    }
    if !selectedModel.isEmpty, !rows.contains(where: { $0.id == selectedModel }) {
      rows.append(
        ModelOption(
          id: selectedModel, name: label(selectedModel) ?? selectedModel, detail: selectedModel,
          efforts: effortOptions(agent, model: selectedModel),
          providerLabel: providerLabel(selectedModel),
          note: "Not in this agent's list; kept because this conversation uses it"))
    }
    let listed = Set(shortlist.map(providerOf))
    for provider in agent.providers ?? [] where !listed.contains(provider.id) {
      rows.append(
        ModelOption(
          id: "catalog:" + provider.id, name: provider.label + " catalog",
          detail: provider.id, efforts: [], providerLabel: provider.label,
          note: provider.configured == false
            ? "Provider not configured on the agent"
            : "Browse this provider's full catalog on the web console",
          selectable: false))
    }
    return rows
  }

  /// The model/effort the selector shows for a conversation (server override) or a new
  /// conversation (local choice). Unknown efforts are kept (web: authoritative while metadata
  /// is unavailable) but never added to the ladder.
  static func summary(_ agent: WebAgentSummary?, model: String, effort: String) -> String {
    guard let agent else { return "Model" }
    let rows = rows(agent, selectedModel: model)
    let row = rows.first { $0.id == model }
    let name = (row?.name ?? model).replacingOccurrences(of: "Default · ", with: "")
    let effortLabel =
      row?.efforts.first { $0.id == effort }?.name
      ?? (effort.isEmpty ? nil : effortName(effort))
    guard let effortLabel else { return name }
    return name + " · " + effortLabel.replacingOccurrences(of: "Default · ", with: "")
  }

  /// Web `setModel`: switching model clears an effort the new model cannot run.
  static func effortAfterSwitching(
    _ agent: WebAgentSummary, to model: String, currentEffort: String
  ) -> String {
    guard !currentEffort.isEmpty else { return "" }
    let levels = effortLevels(agent, effectiveModel(agent, model))
    return levels.contains(currentEffort) ? currentEffort : ""
  }
}
