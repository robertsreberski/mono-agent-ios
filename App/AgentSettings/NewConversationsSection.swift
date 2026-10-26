// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Web `NewConversationsSection`: the model/effort (and eligible 1M context) new conversations
/// start with. Edits change a memory-only draft; Save writes (PUT), "Use agent config" then Save
/// removes the override (DELETE). Existing conversations keep theirs.
struct NewConversationsSection: View {
  let store: ConsoleStore
  let agent: WebAgentSummary
  let wide: Bool
  @State private var pickerOpen = false
  @AccessibilityFocusState private var triggerFocused: Bool
  @Environment(\.consoleTheme) private var theme

  private var state: AgentSettingsState { store.agentSettingsState(agent.sourceId) }
  private var saved: RunDefaultsDraft { RunDefaultsDraft(saved: agent.runSettings.override) }
  private var model: String { state.draft?.model ?? saved.model }
  private var effort: String { state.draft?.effort ?? saved.effort }
  private var storedContext: Bool? { state.draft == nil ? saved.context1M : state.draft?.context1M }
  private var catalog: SettingsModelOptions.Catalog {
    SettingsModelOptions.catalog(store.modelCatalog(sourceID: agent.sourceId))
  }
  private var rows: [SettingsModelRow] {
    SettingsModelOptions.rows(agent, catalog: catalog, selectedModel: model)
  }
  private var selectedRow: SettingsModelRow? { rows.first { $0.id == model } }
  private var eligible: Bool { selectedRow?.supportsContext1M == true }
  private var context1M: Bool? { eligible ? storedContext : nil }
  private var offline: Bool { agent.status == "offline" }
  private var dirty: Bool { store.runDefaultsDirty(agent.sourceId) }
  private var summary: String {
    SettingsModelOptions.startSummary(agent, model: model, effort: effort, catalog: catalog)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      field
      overrideBox
      Text("A fallback or model mismatch is shown on the run it affected.")
        .webFont(.settingsSummary).foregroundStyle(WebColor.textMuted.color)
      if dirty { saveBar }
    }
    .task(id: agent.sourceId + "\u{0}" + (agent.generation ?? "")) {
      await loadCatalogs()
    }
    .onAppear { dropIneligibleContext() }
    .onChange(of: eligible) { dropIneligibleContext() }
    .onChange(of: state.noticeSerial) {
      guard let notice = state.notice else { return }
      AccessibilityNotification.Announcement(notice).post()
      triggerFocused = true
    }
    .onChange(of: state.saveError) { _, error in
      if let error { AccessibilityNotification.Announcement("Saving failed. " + error).post() }
    }
  }

  private func loadCatalogs() async {
    let providers = SettingsModelOptions.catalogProviders(agent)
    await withTaskGroup(of: Void.self) { group in
      for provider in providers {
        group.addTask { [store, agent] in
          await store.ensureProviderCatalog(sourceID: agent.sourceId, provider: provider)
        }
      }
    }
  }

  /// Web: a draft keeps no 1M choice for a model that cannot take one.
  private func dropIneligibleContext() {
    guard let draft = state.draft, !eligible, draft.context1M != nil else { return }
    var next = draft
    next.context1M = nil
    store.editRunDefaults(sourceID: agent.sourceId, next)
  }

  private func update(model: String, effort: String, context: Bool?) {
    let supports = rows.first { $0.id == model }?.supportsContext1M == true
    store.editRunDefaults(
      sourceID: agent.sourceId,
      RunDefaultsDraft(model: model, effort: effort, context1M: supports ? context : nil))
  }

  private func choose(model next: String) {
    let nextEffort = SettingsModelOptions.effortAfterSwitching(
      agent, to: next, currentEffort: effort, catalog: catalog)
    update(model: next, effort: nextEffort, context: context1M)
  }

  // MARK: Start with

  private var chip: SettingsChip {
    if state.saving { return SettingsChip("Saving…", tone: .warning) }
    if dirty { return SettingsChip("Unsaved", tone: .warning) }
    return SettingsChip(agent.runSettings.override == nil ? "Agent config" : "Custom override")
  }

  private var field: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Eyebrow("Start with")
        Spacer(minLength: 8)
        chip.accessibilityIdentifier("settings-start-chip")
      }
      trigger
      if offline {
        Text("Reconnect \(agent.label) to pick a model. Using the agent config works offline.")
          .webFont(.settingsSummary).foregroundStyle(WebColor.warning.color)
          .accessibilityIdentifier("settings-offline-note")
      }
    }
  }

  private var triggerParts: (model: String, effort: String?) {
    let name = (selectedRow?.name ?? (model.isEmpty ? "Select model" : model))
      .replacingOccurrences(of: "Default · ", with: "")
    let effortName =
      selectedRow?.efforts.first { $0.id == effort }?.name
      ?? (effort.isEmpty ? nil : ModelOptions.effortName(effort))
    return (name, effortName?.replacingOccurrences(of: "Default · ", with: ""))
  }

  /// Web settings `.model-selector__trigger`: full width, 44 pt, subtle fill, strong edge.
  private var trigger: some View {
    let parts = triggerParts
    let disabled = state.saving || offline
    return Button {
      pickerOpen = true
      Task { await loadCatalogs() }
    } label: {
      HStack(spacing: 8) {
        Text(parts.model).webFont(.modelName).foregroundStyle(WebColor.text.color)
          .lineLimit(1).truncationMode(.middle)
        if let effort = parts.effort {
          Text(effort).webFont(.effortBadge).foregroundStyle(theme.palette.accent.color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
        }
        if context1M == true {
          Text("1M").webFont(.effortBadge).foregroundStyle(WebColor.textSoft.color).fixedSize()
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(WebColor.textMuted.color)
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.lineStrong.color, lineWidth: 1)
      }
      .opacity(disabled ? 0.55 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel("Model and reasoning effort")
    .accessibilityValue(
      [parts.model, parts.effort, context1M == true ? "1M context" : nil].compactMap { $0 }
        .joined(separator: " · ")
    )
    .accessibilityIdentifier("settings-model-trigger")
    .accessibilityFocused($triggerFocused)
    .popover(isPresented: $pickerOpen, arrowEdge: .top) {
      SettingsModelPicker(
        store: store, agent: agent, rows: rows, model: model, effort: effort,
        context1M: context1M, eligible: eligible, disabled: disabled,
        choose: { choose(model: $0) },
        chooseEffort: { update(model: model, effort: $0, context: context1M) },
        chooseContext: { update(model: model, effort: effort, context: $0) }
      )
      .frame(minWidth: 380, idealWidth: 420, minHeight: 520, idealHeight: 600)
      .presentationDetents([.medium, .large])
      .presentationCompactAdaptation(.sheet)
    }
  }

  // MARK: Agent config / Console override

  private var overrideBox: some View {
    let config = agent.runSettings.config
    let override = agent.runSettings.override
    let effective = agent.runSettings.effective
    return SettingsBox {
      SettingsFactRow("Agent config", wide: wide, identifier: "settings-agent-config") {
        Text(SettingsModelOptions.configSummary(agent, catalog: catalog))
          .webFont(.rowTitle).foregroundStyle(WebColor.text.color)
        Text((config.model ?? "provider default") + " · " + (config.effort ?? "provider default"))
          .webFont(.settingsMono).foregroundStyle(WebColor.textSoft.color)
      }
      SettingsFactRow("Console override", wide: wide, identifier: "settings-console-override") {
        if override != nil {
          Text(
            SettingsModelOptions.modelName(
              agent, effective.model ?? config.model ?? agent.defaultModel, catalog: catalog)
              + " · "
              + SettingsModelOptions.effortName(
                effective.effort ?? config.effort ?? agent.defaultEffort)
          )
          .webFont(.rowTitle).foregroundStyle(WebColor.text.color)
          Text(
            (saved.model.isEmpty
              ? config.model.map { "agent config: " + $0 } ?? "provider default" : saved.model)
              + " · "
              + (saved.effort.isEmpty
                ? config.effort.map { "agent config: " + $0 } ?? "provider default"
                : saved.effort)
          )
          .webFont(.settingsMono).foregroundStyle(WebColor.textSoft.color)
        } else {
          Text("None").webFont(.rowTitle).foregroundStyle(WebColor.text.color)
        }
        if dirty {
          Text(
            model.isEmpty && effort.isEmpty && context1M == nil
              ? "Removed on save" : override != nil ? "Replaced on save" : "Set on save"
          )
          .webFont(.settingsNote).fontWeight(.semibold).foregroundStyle(WebColor.warning.color)
        }
      } trailing: {
        if !model.isEmpty || !effort.isEmpty || override != nil {
          Button("Use agent config") { update(model: "", effort: "", context: nil) }
            .buttonStyle(SettingsButtonStyle(kind: .ghost))
            .disabled(state.saving)
            .accessibilityIdentifier("settings-use-agent-config")
        }
      }
    }
  }

  // MARK: Save bar

  /// Web `.settings-savebar`: the unsaved summary (or the error), Discard and Save/Retry.
  private var saveBar: some View {
    let error = state.saveError
    let blocked = store.runDefaultsSaveBlocked(agent.sourceId)
    return HStack(spacing: 10) {
      Group {
        if let error {
          Text("Couldn't save: " + error).foregroundStyle(WebColor.danger.color)
            .accessibilityIdentifier("settings-save-error")
        } else {
          HStack(spacing: 8) {
            Circle().fill(WebColor.warning.color).frame(width: 6, height: 6)
              .accessibilityHidden(true)
            Text(
              "Unsaved \(Text(summary).fontWeight(.semibold).foregroundStyle(WebColor.text.color))"
            )
            .foregroundStyle(WebColor.textSoft.color)
            .lineLimit(2)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("settings-unsaved-summary")
        }
      }
      .webFont(.settingsSummary)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Discard") {
        store.discardRunDefaults(sourceID: agent.sourceId)
        triggerFocused = true
      }
      .buttonStyle(SettingsButtonStyle(kind: .ghost))
      .disabled(state.saving)
      .accessibilityIdentifier("settings-discard")
      Button(state.saving ? "Saving…" : error != nil ? "Retry" : "Save") {
        store.saveRunDefaults(sourceID: agent.sourceId, summary: summary)
      }
      .buttonStyle(SettingsButtonStyle(kind: .primary))
      .disabled(state.saving || blocked != nil)
      .accessibilityLabel(
        state.saving
          ? "Saving"
          : error != nil ? "Retry saving for new conversations" : "Save for new conversations"
      )
      .accessibilityHint(blocked ?? "")
      .accessibilityIdentifier("settings-save")
    }
    .padding(.vertical, 9).padding(.leading, 14).padding(.trailing, 10)
    .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(
        error == nil ? WebColor.lineStrong.color : WebColor.danger.color.opacity(0.45),
        lineWidth: 1)
    }
    .webShadow(.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-savebar")
  }
}

/// The settings model selector: a popover on iPad, a medium/large sheet on iPhone. One system
/// material with the frosted veil, the plain ✕, translucent selection inks; no solid panels.
struct SettingsModelPicker: View {
  let store: ConsoleStore
  let agent: WebAgentSummary
  let rows: [SettingsModelRow]
  let model: String
  let effort: String
  let context1M: Bool?
  let eligible: Bool
  let disabled: Bool
  let choose: (String) -> Void
  let chooseEffort: (String) -> Void
  let chooseContext: (Bool) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var loading: Bool {
    store.modelCatalog(sourceID: agent.sourceId).providers.values.contains { $0.status == .loading }
  }

  /// Web `groupSelectorModels`: the automatic row, then one group per provider, first seen.
  private var groups: [(provider: String?, label: String?, rows: [SettingsModelRow])] {
    let visible = rows.filter {
      query.isEmpty
        || ($0.name + " " + $0.detail + " " + ($0.providerLabel ?? ""))
          .localizedCaseInsensitiveContains(query)
    }
    var result: [(provider: String?, label: String?, rows: [SettingsModelRow])] = []
    for row in visible {
      if let index = result.firstIndex(where: { $0.provider == row.provider }) {
        result[index].rows.append(row)
      } else {
        result.append((row.provider, row.provider.map { row.providerLabel ?? $0 }, [row]))
      }
    }
    return result
  }

  var body: some View {
    let selected = rows.first { $0.id == model } ?? rows.first
    VStack(spacing: 0) {
      WebSheetHeader(
        "Start with", subtitle: "Model and reasoning effort for new conversations",
        closeLabel: "Done", closeIdentifier: "settings-picker-close"
      ) { dismiss() }
      WebSearchField("Search models", text: $query)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(groups, id: \.provider) { group in
            if let label = group.label {
              Text(label).webFont(.contextEyebrow).foregroundStyle(WebGlass.textMuted.color)
                .padding(.top, 10).padding(.horizontal, 10).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            }
            ForEach(group.rows) { row in
              Button {
                choose(row.id)
              } label: {
                WebModelRow(row.name, detail: row.detail, selected: row.id == model)
              }
              .buttonStyle(.plain)
              .disabled(disabled)
              .accessibilityIdentifier(
                "settings-model-option-" + (row.id.isEmpty ? "default" : row.id))
            }
          }
          if groups.isEmpty {
            Text(loading ? "Loading models…" : "No models match.")
              .webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color)
              .padding(16)
          } else if loading {
            Text("Loading models…").webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color)
              .padding(.vertical, 8).padding(.horizontal, 10)
          }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
      }
      .scrollBounceBehavior(.basedOnSize)
      VStack(alignment: .leading, spacing: 6) {
        let efforts = selected?.efforts ?? []
        Text("Thinking").webFont(.effortOption).foregroundStyle(WebGlass.textMuted.color)
        if efforts.isEmpty {
          Text("This model has no reasoning effort setting").webFont(.contextNote)
            .foregroundStyle(WebGlass.textMuted.color)
        }
        WebFlowLayout(spacing: 4, lineSpacing: 4) {
          ForEach(efforts) { option in
            Button(option.name) { chooseEffort(option.id) }
              .buttonStyle(WebEffortButtonStyle(selected: option.id == effort))
              .disabled(disabled)
              .accessibilityIdentifier(
                "settings-effort-option-" + (option.id.isEmpty ? "default" : option.id))
          }
        }
        if eligible {
          let enabled = context1M ?? selected?.context1M ?? false
          Text("Context window").webFont(.effortOption).foregroundStyle(WebGlass.textMuted.color)
            .padding(.top, 4)
          HStack(spacing: 4) {
            Button(SettingsModelOptions.standardLabel(selected?.standardContextWindow)) {
              chooseContext(false)
            }
            .buttonStyle(WebEffortButtonStyle(selected: !enabled))
            .accessibilityIdentifier("settings-context-standard")
            Button("1M") { chooseContext(true) }
              .buttonStyle(WebEffortButtonStyle(selected: enabled))
              .accessibilityIdentifier("settings-context-1m")
          }
          .disabled(disabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 10).padding(.horizontal, 12)
      .overlay(alignment: .top) { WebHairline() }
    }
    .webSheetVeil()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-picker")
  }
}
