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
  @State private var open = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.consoleTheme) private var theme
  var body: some View {
    let agent = controller.agent
    let summary = ModelOptions.summary(
      agent, model: controller.runModel, effort: controller.runEffort)
    Button {
      open = true
    } label: {
      // Web `.model-selector__trigger` in the composer: model name 12/650, the effort as an
      // uppercase accent badge, and a trailing chevron; transparent, 32 pt high.
      let parts = summary.components(separatedBy: " · ")
      HStack(spacing: 6) {
        if !compact {
          Text(parts.first ?? summary)
            .webFont(.modelName).foregroundStyle(WebColor.text.color)
            .lineLimit(1).truncationMode(.middle)
          if parts.count > 1 {
            Text(parts.dropFirst().joined(separator: " · "))
              .webFont(.effortBadge)
              .foregroundStyle(WebColor.text.color)
              .lineLimit(1)
              .padding(.horizontal, 6).padding(.vertical, 3)
              .background(theme.palette.accentInk, in: RoundedRectangle(cornerRadius: 5))
              .fixedSize()
          }
          if controller.hasRunOverride && sizeClass == .regular {
            Text("custom").webFont(.composerHint).foregroundStyle(WebGlass.textMuted.color)
              .fixedSize()
          }
        } else {
          Image(systemName: controller.hasRunOverride ? "cpu.fill" : "cpu")
            .foregroundStyle(WebColor.textSoft.color)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(WebGlass.textMuted.color)
      }
      .padding(.leading, 7).padding(.trailing, 5)
      .frame(minHeight: WebMetrics.quietControl)
      .frame(minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(agent == nil || agent?.status == "offline")
    .accessibilityLabel("Model and reasoning effort")
    .accessibilityValue(
      summary + (controller.hasRunOverride ? ", custom for this conversation" : "")
    )
    .accessibilityIdentifier("composer-model")
    .sheet(isPresented: $open) {
      RunSettingsSheet(controller: controller, dismissOnSelection: true)
    }
  }
}

/// The `/settings` command target: the same choices as a sheet (a Menu cannot be opened
/// programmatically).
struct RunSettingsSheet: View {
  let controller: ComposerController
  var dismissOnSelection = false
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  var body: some View {
    VStack(spacing: 0) {
      WebSheetHeader("Run settings", closeLabel: "Done") { dismiss() }
      WebSearchField("Search models", text: $query)
      ScrollView {
        if let agent = controller.agent {
          let rows = ModelOptions.rows(agent, selectedModel: controller.runModel)
          VStack(alignment: .leading, spacing: 2) {
            ForEach(
              rows.filter {
                query.isEmpty || ($0.name + " " + $0.detail).localizedCaseInsensitiveContains(query)
              }
            ) { row in
              Button {
                controller.setModel(row.id)
                if dismissOnSelection { dismiss() }
              } label: {
                WebModelRow(
                  row.name, detail: row.note ?? row.detail, selected: row.id == controller.runModel)
              }
              .buttonStyle(.plain)
              .disabled(!row.selectable)
              .opacity(row.selectable ? 1 : 0.58)
              .accessibilityLabel(row.name + (", " + (row.note ?? row.detail)))
              .accessibilityIdentifier("model-option-" + (row.id.isEmpty ? "default" : row.id))
            }
            if controller.threadID != nil {
              Text("Changing the model rebuilds context on the next reply. Effort changes don't.")
                .webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color)
                .padding(.vertical, 12).padding(.horizontal, 10)
            }
          }.padding(.vertical, 6).padding(.horizontal, 8)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      if let agent = controller.agent {
        let rows = ModelOptions.rows(agent, selectedModel: controller.runModel)
        let efforts = (rows.first { $0.id == controller.runModel } ?? rows.first)?.efforts ?? []
        VStack(alignment: .leading, spacing: 6) {
          Text("Thinking").webFont(.effortOption).foregroundStyle(WebGlass.textMuted.color)
          if efforts.isEmpty {
            Text("This model has no reasoning effort setting").webFont(.contextNote)
          }
          WebFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(efforts) { effort in
              Button(effort.name) {
                controller.setEffort(effort.id)
                if dismissOnSelection { dismiss() }
              }
              .buttonStyle(WebEffortButtonStyle(selected: effort.id == controller.runEffort))
              .accessibilityIdentifier(
                "effort-option-" + (effort.id.isEmpty ? "default" : effort.id))
            }
          }
          if controller.hasRunOverride {
            Button("Reset to Agent Default") { controller.resetRunSettings() }
              .designButtonStyle(.secondary, placement: .floating)
              .accessibilityIdentifier("model-reset")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        // On the sheet material: a hairline above, no band of its own (GLASS-RULES.md).
        .overlay(alignment: .top) { WebHairline() }
      }
    }
    .webSheetVeil()
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
    VStack(spacing: 0) {
      WebSheetHeader(
        "Skills",
        subtitle:
          "Browse skills for \(agentLabel ?? "the active agent"). Selecting one only inserts its reference.",
        closeIdentifier: "skills-close"
      ) { dismiss() }
      .accessibilityIdentifier("skills-header")
      WebSearchField("Search names and descriptions", text: $query)
      if let notice {
        Text(notice).webFont(.sheetSubtitle).foregroundStyle(WebGlass.textMuted.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 9).padding(.horizontal, 15)
          .overlay(alignment: .bottom) { WebHairline() }
      }
      ScrollView {
        let visible = SkillDiscovery.rank(
          registry?.items ?? [], query: query, includeUnavailable: true, limit: 256)
        VStack(spacing: 0) {
          ForEach(visible, id: \.name) { skill in
            let selectable = registry?.canInsert == true && SkillDiscovery.isUsable(skill)
            Button {
              guard selectable else { return }
              dismiss()
              onSelect(skill.name)
            } label: {
              SuggestionRow(
                skill.reference ?? skill.name, subtitle: skill.description,
                badge: SkillDiscovery.statusLabel(skill), enabled: selectable, browsing: true)
            }
            .buttonStyle(.plain).disabled(!selectable)
            .accessibilityIdentifier("skill-browse-" + skill.name)
          }
          if case .ready(let items, _, _, _)? = registry, visible.isEmpty {
            Text(items.isEmpty ? "No skills are installed for this agent." : "No matching skills.")
              .webFont(.contextNote).foregroundStyle(WebGlass.textMuted.color).padding(16)
          }
        }.padding(7)
      }
      .refreshable { await onRefresh() }
    }
    .webSheetVeil()
    .presentationDetents([.medium, .large])
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
