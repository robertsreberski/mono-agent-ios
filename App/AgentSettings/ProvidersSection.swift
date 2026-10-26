// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Web provider rows: auth and usage are independent resources, never a shared loading gate.
struct ProvidersSection: View {
  let store: ConsoleStore
  let agent: WebAgentSummary
  let compact: Bool
  private var state: ProviderState { store.providerState(agent.sourceId) }
  private var actionBlocked: Bool {
    state.busy || state.usageRefreshing || !store.canWriteAgentSettings
  }
  private let disclosure =
    "Check access sends one small model request per configured authentication provider and may use quota or refresh OAuth."

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if agent.status == "offline" {
        note("Provider status needs a live connection")
      } else if agent.supportsProviderAuth != true && agent.supportsProviderUsage != true {
        note("Not available on this agent.")
      } else {
        actions
        if state.statusLoading && state.status == nil { note("Loading provider status…") }
        if state.usageLoading && state.usage == nil { note("Loading subscription usage…") }
        SettingsBox {
          if agent.supportsProviderAuth == true {
            ForEach(state.status?.providers ?? [], id: \.providerId) { provider in
              row(provider)
            }
            if state.status?.providers.isEmpty == true {
              note("No authentication providers available.").padding(14)
            }
          } else {
            ForEach(state.usage?.providers ?? [], id: \.providerId) { usage in
              VStack(alignment: .leading, spacing: 10) {
                Text(usage.label).webFont(.rowTitle)
                if let plan = usage.plan { SettingsChip(plan) }
                ProviderUsageMeters(usage: usage, compact: compact)
              }.padding(14)
            }
            if state.usage?.providers.isEmpty == true {
              note("No subscription usage available.").padding(14)
            }
          }
        }
        if let check = state.check {
          note(ProviderPresentation.checkSummary(check)).accessibilityIdentifier(
            "provider-check-summary")
        }
        if let error = state.authError {
          Text(verbatim: error).webFont(.settingsNote).foregroundStyle(WebColor.danger.color)
            .accessibilityIdentifier("provider-auth-error")
          Button("Retry provider status") { store.reloadProviderStatus(sourceID: agent.sourceId) }
            .buttonStyle(SettingsButtonStyle())
        }
        if let error = state.usageError {
          note(error).accessibilityIdentifier("provider-usage-error")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("providers-section")
    .task(id: store.providerScope(agent.sourceId)) {
      guard !Task.isCancelled else { return }
      store.openProviders(sourceID: agent.sourceId)
    }
    .onDisappear { store.closeProviders(sourceID: agent.sourceId) }
    .onChange(of: state.noticeSerial) {
      if let notice = state.notice { AccessibilityNotification.Announcement(notice).post() }
    }
  }
  private var actions: some View {
    VStack(alignment: .leading, spacing: 6) {
      WebFlowLayout(spacing: 8, lineSpacing: 8) {
        if agent.supportsProviderUsage == true && agent.supportsProviderUsageRefresh == true {
          Button(
            state.usageRefreshing ? "Refreshing usage…" : "Refresh usage",
            systemImage: "arrow.clockwise"
          ) {
            store.refreshProviderUsage(sourceID: agent.sourceId)
          }
          .buttonStyle(SettingsButtonStyle())
          .disabled(actionBlocked || state.checkActive || state.sessionActive)
          .accessibilityHint("Refresh usage reads subscription limits without inference.")
          .accessibilityIdentifier("provider-refresh-usage")
        }
        if agent.supportsProviderAuthChecks == true {
          Button(state.checkActive ? "Cancel checks" : "Check access") {
            if state.checkActive {
              store.cancelProviderCheck(sourceID: agent.sourceId)
            } else {
              store.startProviderCheck(sourceID: agent.sourceId)
            }
          }
          .buttonStyle(SettingsButtonStyle())
          .disabled(
            actionBlocked || !state.checkActive && (state.status == nil || state.sessionActive)
          )
          .accessibilityHint(disclosure)
          .accessibilityIdentifier("provider-check-access")
        }
      }
      if let feedback = state.usageFeedback {
        note(feedback).accessibilityIdentifier("provider-usage-feedback")
      }
      if agent.supportsProviderAuthChecks == true {
        note("Check access may use quota").accessibilityLabel(disclosure)
      }
    }
  }
  private func row(_ provider: ProviderAuthProviderStatus) -> some View {
    let usage = state.usage?.providers.first { $0.providerId == provider.providerId }
    return VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top) {
          heading(provider, usage: usage)
          Spacer(minLength: 8)
          authenticate(provider)
        }
        VStack(alignment: .leading, spacing: 8) {
          heading(provider, usage: usage)
          authenticate(provider)
        }
      }
      if let usage {
        ProviderUsageMeters(usage: usage, compact: compact)
      } else if provider.state == "missing" {
        note(
          agent.supportsProviderUsage == true
            ? "Sign in to read subscription limits." : "Sign in to use this provider.")
      }
      if state.sessionProviderID == provider.providerId
        || state.methodProviderID == provider.providerId
      {
        // Remove the complete subtree, including UIKit-backed input accessibility, while covered.
        if store.providerPrivacyCovered {
          Label("Authentication hidden while inactive", systemImage: "lock.fill")
            .webFont(.settingsNote).accessibilityIdentifier("provider-privacy-cover")
        } else {
          ProviderAuthFlow(store: store, sourceID: agent.sourceId, provider: provider)
            .privacySensitive()
        }
      }
    }
    .padding(14)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("provider-row-" + provider.providerId)
  }
  private func heading(_ provider: ProviderAuthProviderStatus, usage: ProviderUsage?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(provider.label).webFont(.rowTitle).foregroundStyle(WebColor.text.color)
      WebFlowLayout(spacing: 6, lineSpacing: 5) {
        if let plan = usage?.plan { SettingsChip(plan) }
        Label(ProviderPresentation.authLabel(provider), systemImage: authSymbol(provider))
          .webFont(.settingsNote).foregroundStyle(WebColor.textSoft.color)
          .accessibilityIdentifier("provider-auth-state-" + provider.providerId)
        if let check = state.check?.results.first(where: { $0.providerId == provider.providerId }) {
          SettingsChip(ProviderPresentation.checkLabel(check.state))
            .accessibilityLabel(
              "Live check for \(provider.label): \(ProviderPresentation.checkLabel(check.state))."
            )
            .accessibilityIdentifier("provider-check-result-" + provider.providerId)
        }
      }
    }
  }
  @ViewBuilder private func authenticate(_ provider: ProviderAuthProviderStatus) -> some View {
    if !provider.methods.isEmpty {
      Button(provider.state == "missing" ? "Authenticate" : "Re-authenticate") {
        store.openProviderAuth(sourceID: agent.sourceId, providerID: provider.providerId)
      }
      .buttonStyle(SettingsButtonStyle())
      .disabled(actionBlocked || state.checkActive)
      .accessibilityLabel(
        "\(provider.state == "missing" ? "Authenticate" : "Re-authenticate") \(provider.label)"
      )
      .accessibilityIdentifier("provider-authenticate-" + provider.providerId)
    }
  }
  private func authSymbol(_ provider: ProviderAuthProviderStatus) -> String {
    switch ProviderPresentation.authLabel(provider) {
    case "OK", "Credential OK": "checkmark.circle"
    case "Not verified": "questionmark.circle"
    case "Not applicable": "minus.circle"
    default: "exclamationmark.triangle"
    }
  }
  private func note(_ text: String) -> some View {
    Text(verbatim: text).webFont(.settingsNote).foregroundStyle(WebColor.textMuted.color)
  }
}
