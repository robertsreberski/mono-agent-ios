// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Per-conversation model and reasoning-effort override (web ModelSelector): agent default,
/// the agent's allowed routes and efforts, and explained entries that cannot be chosen here.
struct ModelSelectorMenu: View {
  let controller: ComposerController
  /// Icon only; the summary stays in the accessibility value.
  var compact = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    let agent = controller.agent
    let summary = ModelOptions.summary(
      agent, model: controller.runModel, effort: controller.runEffort)
    Menu {
      if let agent { ModelMenuContent(controller: controller, agent: agent) }
    } label: {
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: controller.hasRunOverride ? "cpu.fill" : "cpu")
        if !compact {
          Text(summary).lineLimit(1).fixedSize()
          if controller.hasRunOverride && sizeClass == .regular {
            Text("custom").designFont(.caption).foregroundStyle(.secondary).fixedSize()
          }
        }
        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
      }
      .designFont(.supporting)
      .frame(minHeight: 32)
    }
    .buttonStyle(.borderless)
    .disabled(agent == nil || agent?.status == "offline")
    .accessibilityLabel("Model and reasoning effort")
    .accessibilityValue(
      summary + (controller.hasRunOverride ? ", custom for this conversation" : "")
    )
    .accessibilityIdentifier("composer-model")
  }
}

private struct ModelMenuContent: View {
  let controller: ComposerController
  let agent: WebAgentSummary
  var body: some View {
    let rows = ModelOptions.rows(agent, selectedModel: controller.runModel)
    let selected = rows.first { $0.id == controller.runModel } ?? rows.first
    Section("Model") {
      ForEach(rows) { row in
        Button {
          controller.setModel(row.id)
        } label: {
          if row.id == controller.runModel {
            Label(row.name, systemImage: "checkmark")
          } else {
            Text(row.name)
          }
          Text(subtitle(row))
        }
        .disabled(!row.selectable)
        .accessibilityIdentifier("model-option-" + (row.id.isEmpty ? "default" : row.id))
      }
    }
    if let efforts = selected?.efforts, !efforts.isEmpty {
      Section("Thinking") {
        ForEach(efforts) { effort in
          Button {
            controller.setEffort(effort.id)
          } label: {
            if effort.id == controller.runEffort {
              Label(effort.name, systemImage: "checkmark")
            } else {
              Text(effort.name)
            }
          }
          .accessibilityIdentifier("effort-option-" + (effort.id.isEmpty ? "default" : effort.id))
        }
      }
    } else {
      Section("Thinking") { Text("This model has no reasoning effort setting") }
    }
    if controller.hasRunOverride {
      Button("Reset to Agent Default", systemImage: "arrow.uturn.backward") {
        controller.resetRunSettings()
      }
      .accessibilityIdentifier("model-reset")
    }
    if controller.threadID != nil {
      Section {
        Text("Changing the model rebuilds context on the next reply. Effort changes don't.")
      }
    }
  }
  private func subtitle(_ row: ModelOption) -> String {
    [row.isAgentDefault ? "agent default" : nil, row.note ?? row.detail].compactMap { $0 }
      .joined(separator: " · ")
  }
}

/// The `/settings` command target: the same choices as a sheet (a Menu cannot be opened
/// programmatically).
struct RunSettingsSheet: View {
  let controller: ComposerController
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        if let agent = controller.agent {
          let rows = ModelOptions.rows(agent, selectedModel: controller.runModel)
          Section("Model") {
            ForEach(rows) { row in
              Button {
                controller.setModel(row.id)
              } label: {
                ChoiceRow(
                  row.name, detail: row.note ?? row.detail,
                  selected: row.id == controller.runModel, multiple: false)
              }
              .buttonStyle(.plain)
              .disabled(!row.selectable)
            }
          }
          let efforts =
            (rows.first { $0.id == controller.runModel } ?? rows.first)?.efforts ?? []
          Section("Thinking") {
            if efforts.isEmpty { Text("This model has no reasoning effort setting") }
            ForEach(efforts) { effort in
              Button {
                controller.setEffort(effort.id)
              } label: {
                ChoiceRow(effort.name, selected: effort.id == controller.runEffort, multiple: false)
              }
              .buttonStyle(.plain)
            }
          }
          if controller.hasRunOverride {
            Button("Reset to Agent Default") { controller.resetRunSettings() }
          }
        }
      }
      .navigationTitle("Run settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Browse every skill for the agent (web SkillBrowser): search names and descriptions;
/// selecting one only inserts its reference at the saved caret.
struct SkillBrowserSheet: View {
  let agentLabel: String?
  let registry: SkillRegistryState?
  let onRefresh: () async -> Void
  let onSelect: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Browse skills for \(agentLabel ?? "the active agent"). Selecting one only inserts its reference."
          )
          .designFont(.supporting).foregroundStyle(.secondary)
          if let notice { StatusIndicator(.stale, label: notice) }
        }
        let visible = SkillDiscovery.rank(
          registry?.items ?? [], query: query, includeUnavailable: true, limit: 256)
        ForEach(visible, id: \.name) { skill in
          let selectable = registry?.canInsert == true && SkillDiscovery.isUsable(skill)
          Button {
            guard selectable else { return }
            dismiss()
            onSelect(skill.name)
          } label: {
            SuggestionRow(
              skill.reference ?? skill.name, subtitle: skill.description,
              badge: SkillDiscovery.statusLabel(skill), enabled: selectable)
          }
          .buttonStyle(.plain)
          .disabled(!selectable)
          .accessibilityIdentifier("skill-browse-" + skill.name)
        }
        if case .ready(let items, _, _, _)? = registry, visible.isEmpty {
          Text(items.isEmpty ? "No skills are installed for this agent." : "No matching skills.")
            .foregroundStyle(.secondary)
        }
      }
      .searchable(text: $query, prompt: "Search names and descriptions")
      .refreshable { await onRefresh() }
      .navigationTitle("Skills")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }.accessibilityIdentifier("skills-close")
        }
      }
    }
    .accessibilityIdentifier("skill-browser")
  }

  private var notice: String? {
    switch registry {
    case nil, .loading?: "Loading skills…"
    case .ready(let items, let total, let truncated, let stale)?:
      stale
        ? "Showing a stale snapshot. Reconnect before inserting a skill."
        : truncated ? "Showing \(items.count) of \(total ?? items.count) skills." : nil
    case .unavailable(let status)?:
      switch status {
      case "unsupported": "This agent version does not expose skill discovery."
      case "offline": "This agent is offline."
      default: "The agent could not load its skill registry."
      }
    }
  }
}
