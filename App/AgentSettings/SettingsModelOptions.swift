// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore

/// What one route says about its own reasoning and context (web `EffortAdvertisement`). A
/// shortlist `modelOptions` entry and a `/models` catalog row are read by the same rule.
struct EffortAdvertisement: Equatable {
  var effortLevels: [String]?
  var effort: String?
  var reasoning: Bool?
  var reasoningMode: String?
  var label: String?
  var contextWindow: Double?
  var supportsContext1M: Bool?
  var context1M: Bool?

  init(_ option: WebModelOption) {
    effortLevels = option.effortLevels
    effort = option.effort
    reasoning = option.reasoning
    reasoningMode = option.reasoningMode
    label = option.label
    contextWindow = option.contextWindow
    supportsContext1M = option.supportsContext1M
    context1M = option.context1M
  }

  init(_ model: WebCatalogModel) {
    effortLevels = model.effortLevels
    reasoning = model.reasoning
    reasoningMode = model.reasoningMode
    label = model.name
    contextWindow = model.contextWindow
    supportsContext1M = model.supportsContext1M
    context1M = model.context1M
  }
}

/// One New-conversations selector row. `id == ""` is the automatic row (the agent config).
struct SettingsModelRow: Equatable, Identifiable {
  let id: String
  let name: String
  let detail: String
  let efforts: [ModelEffortOption]
  var provider: String?
  var providerLabel: String?
  var supportsContext1M = false
  /// Advertised standard capacity, when the 1M overlay is not already configured.
  var standardContextWindow: Double?
  var context1M: Bool?
}

/// The agent-settings projection of web `model-catalog.ts`/`settings-labels.ts`: the shortlist
/// widened by fetched provider catalogs. Separate from `ModelOptions`, which keeps the
/// composer's shortlist-only rows unchanged.
enum SettingsModelOptions {
  typealias Catalog = [(provider: String, models: [WebCatalogModel])]

  static func catalog(_ value: AgentModelCatalog) -> Catalog {
    value.ordered.map { ($0.provider, $0.state.models) }
  }

  /// Web `catalogModelReference`: canonical `<provider>:<model>`.
  static func reference(_ model: WebCatalogModel) -> String {
    model.provider.isEmpty ? model.id : model.provider + ":" + model.id
  }

  /// Web `findCatalogModel`: by canonical reference or by the bare provider-local id.
  static func findCatalogModel(_ catalog: Catalog, _ id: String) -> WebCatalogModel? {
    for entry in catalog {
      if let model = entry.models.first(where: { reference($0) == id || $0.id == id }) {
        return model
      }
    }
    return nil
  }

  /// Web `advertisedEffortLevels`; `nil` means the advertisement said nothing.
  static func advertisedLevels(_ advertisement: EffortAdvertisement?) -> [String]? {
    guard let advertisement else { return nil }
    if advertisement.reasoning == false || advertisement.reasoningMode == "none" { return [] }
    if advertisement.effortLevels?.isEmpty == true { return [] }
    if advertisement.reasoningMode == "toggle" { return ModelOptions.toggleEffortLevels }
    if let levels = advertisement.effortLevels { return levels }
    if advertisement.reasoningMode == "effort" { return ModelOptions.globalEffortLevels }
    if advertisement.reasoning != nil { return [] }
    return nil
  }

  /// Web `effortLevelsForModel`: shortlist entry, then the catalog row, then the floor.
  static func effortLevels(
    _ agent: WebAgentSummary, model: String?, catalogModel: WebCatalogModel?
  ) -> [String] {
    if let advertised = advertisedLevels(
      model.flatMap { agent.modelOptions?[$0] }.map(EffortAdvertisement.init))
    {
      return advertised
    }
    if let levels = advertisedLevels(catalogModel.map(EffortAdvertisement.init)) { return levels }
    if agent.modelOptions == nil { return agent.efforts ?? ModelOptions.globalEffortLevels }
    return ModelOptions.globalEffortLevels
  }

  /// Web `inheritedEffortForModel`. Decoding cannot tell an explicit `null` route effort from an
  /// absent one, so both use the capability rule (as `ModelOptions.inheritedEffort` does).
  static func inheritedEffort(
    _ agent: WebAgentSummary, model: String, catalogModel: WebCatalogModel?,
    defaultEffort: String?
  ) -> String? {
    let effective = ModelOptions.effectiveModel(agent, model)
    let primary = agent.defaultModel.flatMap { $0.isEmpty ? nil : $0 } ?? agent.models?.first
    guard let effective, effective != primary else { return defaultEffort }
    let shortlist = agent.modelOptions?[effective].map(EffortAdvertisement.init)
    if let pinned = shortlist?.effort { return pinned }
    guard let defaultEffort else { return nil }
    guard let advertisement = shortlist ?? catalogModel.map(EffortAdvertisement.init) else {
      return defaultEffort
    }
    if advertisement.reasoning == false || advertisement.reasoningMode == "none" { return nil }
    if advertisement.effortLevels?.isEmpty == true { return nil }
    if advertisement.reasoningMode == "toggle" {
      return ModelOptions.toggleEffortLevels.contains(defaultEffort) ? defaultEffort : nil
    }
    if let levels = advertisement.effortLevels {
      return levels.contains(defaultEffort) ? defaultEffort : nil
    }
    if advertisement.reasoningMode == "effort" {
      return ModelOptions.globalEffortLevels.contains(defaultEffort) ? defaultEffort : nil
    }
    return defaultEffort
  }

  /// The effort a new conversation inherits from the agent config.
  static func configEffort(_ agent: WebAgentSummary) -> String? {
    let value = agent.runSettings.config.effort ?? agent.defaultEffort
    return value?.isEmpty == true ? nil : value
  }

  /// Web `buildEffortOptions`.
  static func effortOptions(
    _ agent: WebAgentSummary, reference: String, catalogModel: WebCatalogModel?
  ) -> [ModelEffortOption] {
    let effective = ModelOptions.effectiveModel(agent, reference) ?? ""
    let toggle =
      agent.modelOptions?[effective]?.reasoningMode == "toggle"
      || catalogModel?.reasoningMode == "toggle"
    let levels = effortLevels(agent, model: effective, catalogModel: catalogModel)
    guard !levels.isEmpty else { return [] }
    let inherited = inheritedEffort(
      agent, model: reference, catalogModel: catalogModel, defaultEffort: configEffort(agent))
    let defaultName: String =
      if let inherited {
        toggle ? (inherited == "none" ? "Off" : "On") : ModelOptions.effortName(inherited)
      } else {
        "Provider"
      }
    return [ModelEffortOption(id: "", name: "Default · " + defaultName)]
      + levels.map {
        ModelEffortOption(
          id: $0, name: toggle ? ($0 == "none" ? "Off" : "On") : ModelOptions.effortName($0))
      }
  }

  /// Web `buildSelectorModels`: the automatic row, the configured shortlist (widened by catalog
  /// metadata), catalog-only rows in first-fetched order, then a kept saved choice the catalog
  /// does not list yet. Never substitutes the automatic row for an unlisted choice.
  static func rows(_ agent: WebAgentSummary, catalog: Catalog, selectedModel: String)
    -> [SettingsModelRow]
  {
    let shortlist = agent.models ?? []
    let listed = Set(shortlist)
    func display(_ reference: String?) -> String? {
      guard let reference, !reference.isEmpty else { return nil }
      return agent.modelOptions?[reference]?.label
        ?? findCatalogModel(catalog, reference)?.name ?? reference
    }
    func providerOf(_ reference: String) -> (String, String) {
      if let model = findCatalogModel(catalog, reference), !model.provider.isEmpty {
        return (model.provider, model.providerLabel.isEmpty ? model.provider : model.providerLabel)
      }
      let provider = ModelOptions.providerOf(reference)
      return (provider, provider)
    }
    func context(_ row: inout SettingsModelRow, _ reference: String) {
      guard
        let advertisement = agent.modelOptions?[reference].map(EffortAdvertisement.init)
          ?? findCatalogModel(catalog, reference).map(EffortAdvertisement.init),
        advertisement.supportsContext1M == true
      else { return }
      row.supportsContext1M = true
      if advertisement.context1M != true, let window = advertisement.contextWindow, window > 0 {
        row.standardContextWindow = window
      }
      row.context1M = advertisement.context1M
    }
    let defaultModel = agent.defaultModel ?? ""
    var automatic = SettingsModelRow(
      id: "", name: "Default · " + (display(agent.defaultModel) ?? "agent"),
      detail: agent.defaultModel.map { "Agent default · " + $0 } ?? "Use the agent default",
      efforts: effortOptions(
        agent, reference: "", catalogModel: findCatalogModel(catalog, defaultModel)))
    context(&automatic, defaultModel)
    var rows = [automatic]
    for reference in shortlist {
      let (provider, label) = providerOf(reference)
      var row = SettingsModelRow(
        id: reference, name: display(reference) ?? reference, detail: reference,
        efforts: effortOptions(
          agent, reference: reference, catalogModel: findCatalogModel(catalog, reference)),
        provider: provider, providerLabel: label)
      context(&row, reference)
      rows.append(row)
    }
    for entry in catalog {
      for model in entry.models {
        let id = reference(model)
        guard !id.isEmpty, !listed.contains(id), !rows.contains(where: { $0.id == id }) else {
          continue
        }
        let provider = model.provider.isEmpty ? ModelOptions.providerOf(id) : model.provider
        var row = SettingsModelRow(
          id: id, name: model.name, detail: id,
          efforts: effortOptions(agent, reference: id, catalogModel: model),
          provider: provider,
          providerLabel: model.providerLabel.isEmpty ? provider : model.providerLabel)
        context(&row, id)
        rows.append(row)
      }
    }
    if !selectedModel.isEmpty, !rows.contains(where: { $0.id == selectedModel }) {
      let provider = ModelOptions.providerOf(selectedModel)
      rows.append(
        SettingsModelRow(
          id: selectedModel, name: display(selectedModel) ?? selectedModel, detail: selectedModel,
          efforts: effortOptions(
            agent, reference: selectedModel,
            catalogModel: findCatalogModel(catalog, selectedModel)),
          provider: provider,
          providerLabel: agent.providers?.first { $0.id == provider }?.label ?? provider))
    }
    return rows
  }

  /// Web `settingsModelName`: advertised label, catalog name, then the reference itself.
  static func modelName(_ agent: WebAgentSummary, _ reference: String?, catalog: Catalog)
    -> String
  {
    guard let reference, !reference.isEmpty else { return "Provider default" }
    if let label = agent.modelOptions?[reference]?.label?.trimmingCharacters(
      in: .whitespacesAndNewlines), !label.isEmpty
    {
      return label
    }
    return findCatalogModel(catalog, reference)?.name ?? reference
  }

  /// Web `settingsEffortName`.
  static func effortName(_ effort: String?) -> String {
    guard let effort, !effort.isEmpty else { return "Provider default" }
    return ModelOptions.effortName(effort)
  }

  /// The "model · effort" new conversations start with for this draft (web `startModel` /
  /// `startEffort`): blank fields fall back to the agent config, then the agent default.
  static func startSummary(
    _ agent: WebAgentSummary, model: String, effort: String, catalog: Catalog
  ) -> String {
    let config = agent.runSettings.config
    let modelName = Self.modelName(
      agent, model.nonEmpty ?? config.model?.nonEmpty ?? agent.defaultModel, catalog: catalog)
    let effortName = Self.effortName(
      effort.nonEmpty ?? config.effort?.nonEmpty ?? agent.defaultEffort)
    return modelName + " · " + effortName
  }

  /// The agent-config summary line (web `Agent config` value).
  static func configSummary(_ agent: WebAgentSummary, catalog: Catalog) -> String {
    startSummary(agent, model: "", effort: "", catalog: catalog)
  }

  /// Web `chooseModel`: switching model clears an effort the new model cannot run.
  static func effortAfterSwitching(
    _ agent: WebAgentSummary, to model: String, currentEffort: String, catalog: Catalog
  ) -> String {
    guard !currentEffort.isEmpty else { return "" }
    let effective = ModelOptions.effectiveModel(agent, model) ?? ""
    let allowed = effortLevels(
      agent, model: effective, catalogModel: findCatalogModel(catalog, effective))
    return allowed.contains(currentEffort) ? currentEffort : ""
  }

  /// Providers whose catalogs can name the agent's routes: shortlist providers and every
  /// advertised provider (web `NewConversationsSection` catalog effect).
  static func catalogProviders(_ agent: WebAgentSummary) -> [String] {
    var seen: Set<String> = []
    var providers: [String] = []
    for id in (agent.models ?? []).map(ModelOptions.providerOf) + (agent.providers ?? []).map(\.id)
    where !id.isEmpty && seen.insert(id).inserted {
      providers.append(id)
    }
    return providers
  }

  /// Web context-window choice label: compact advertised capacity, else "Standard".
  static func standardLabel(_ window: Double?) -> String {
    guard let window, window.isFinite, window > 0 else { return "Standard" }
    return window.formatted(
      .number.notation(.compactName).precision(.fractionLength(0...1)).locale(
        Locale(identifier: "en")))
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
