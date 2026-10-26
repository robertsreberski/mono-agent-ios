// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// Credentials exist only in this transient view-local field and the in-flight command.
struct ProviderAuthFlow: View {
  let store: ConsoleStore
  let sourceID: String
  let provider: ProviderAuthProviderStatus
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @State private var input = ""
  private var state: ProviderState { store.providerState(sourceID) }
  private var session: ProviderAuthSessionSnapshot? {
    state.sessionProviderID == provider.providerId ? state.session : nil
  }
  private var inputIdentity: String { (session?.id ?? "") + ":" + (session?.prompt?.id ?? "") }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if state.methodProviderID == provider.providerId && provider.methods.count > 1 {
        WebFlowLayout(spacing: 8, lineSpacing: 8) {
          ForEach(provider.methods, id: \.strategy) { method in
            Button(method.label + (method.recommended ? " · Recommended" : "")) {
              input = ""
              store.startProviderAuth(
                sourceID: sourceID, providerID: provider.providerId, method: method)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(state.busy || state.checkActive || state.usageRefreshing)
            .accessibilityIdentifier("provider-method-" + method.strategy)
          }
        }
      }
      if let session {
        if let auth = session.authUrl {
          Text(verbatim: ProviderPresentation.boundedText(auth.instructions)).webFont(.settingsNote)
          externalButton(
            "Open authentication page", url: auth.url, identifier: "provider-open-auth-page")
        }
        if let device = session.deviceCode {
          externalButton(
            "Open device page", url: device.verificationUri, identifier: "provider-open-device-page"
          )
          Text(verbatim: device.userCode).webFont(.settingsMono)
            .textSelection(.disabled)
            .accessibilityIdentifier("provider-device-code")
        }
        if let progress = session.progress {
          Text(verbatim: ProviderPresentation.boundedText(progress)).webFont(.settingsNote)
            .accessibilityIdentifier("provider-auth-progress")
        }
        if let prompt = session.prompt, !ProviderPresentation.authTerminal(session.state) {
          promptView(prompt, session: session)
        }
        if let error = session.error {
          Text(verbatim: ProviderPresentation.boundedText(error.message))
            .webFont(.settingsNote).foregroundStyle(WebColor.danger.color)
            .accessibilityIdentifier("provider-session-error")
          if error.code == "device_code_unavailable",
            let method = provider.methods.first(where: { $0.strategy == "paste_back" })
          {
            Button("Retry with browser paste-back") {
              input = ""
              store.startProviderAuth(
                sourceID: sourceID, providerID: provider.providerId, method: method)
            }
            .buttonStyle(SettingsButtonStyle()).disabled(state.busy || state.checkActive)
            .accessibilityIdentifier("provider-paste-back")
          }
        }
        Button(
          ProviderPresentation.authTerminal(session.state)
            ? "Close authentication" : "Cancel authentication"
        ) {
          input = ""
          store.cancelProviderAuth(sourceID: sourceID)
        }
        .buttonStyle(SettingsButtonStyle(kind: .ghost)).disabled(state.busy)
        .accessibilityIdentifier("provider-cancel-auth")
      } else if state.busy {
        Text("Starting authentication…").webFont(.settingsNote)
      }
    }
    .foregroundStyle(WebColor.text.color)
    .privacySensitive()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("provider-auth-flow")
    .onChange(of: inputIdentity) { input = "" }
    .onChange(of: scenePhase) { if scenePhase != .active { input = "" } }
    .onDisappear { input = "" }
    .confirmationDialog(
      "Replace the stored OpenAI credential?",
      isPresented: Binding(
        get: { state.replacement != nil && state.methodProviderID == provider.providerId },
        set: { if !$0 { store.dismissProviderReplacement(sourceID: sourceID) } }),
      titleVisibility: .visible
    ) {
      if let method = state.replacement {
        Button("Replace with \(method.label)") {
          input = ""
          store.startProviderAuth(
            sourceID: sourceID, providerID: provider.providerId, method: method,
            confirmedReplacement: true)
        }
      }
      Button("Cancel", role: .cancel) { store.dismissProviderReplacement(sourceID: sourceID) }
    } message: {
      Text("The existing credential remains until authentication succeeds.")
    }
  }
  private func promptView(_ prompt: ProviderAuthPrompt, session: ProviderAuthSessionSnapshot)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: ProviderPresentation.boundedText(prompt.message)).webFont(.settingsNote)
      if prompt.type == "select" {
        Picker("Choose…", selection: $input) {
          Text("Choose…").tag("")
          ForEach(prompt.options ?? [], id: \.id) { option in
            Text(verbatim: option.label).tag(option.id)
          }
        }
        .pickerStyle(.menu).accessibilityIdentifier("provider-prompt-select")
      } else if prompt.type == "secret" {
        SecureField(prompt.placeholder ?? "Secret", text: $input)
          .textContentType(.oneTimeCode)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .webInput().accessibilityLabel(prompt.message)
          .accessibilityIdentifier("provider-prompt-secret")
      } else {
        TextField(
          prompt.placeholder ?? "Response", text: $input,
          axis: prompt.type == "manual_code" ? .vertical : .horizontal
        )
        .lineLimit(prompt.type == "manual_code" ? 3...5 : 1...1)
        .textContentType(.oneTimeCode)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .webInput().accessibilityLabel(prompt.message)
        .accessibilityIdentifier("provider-prompt-text")
      }
      Button("Submit once") {
        let submitted = input
        input = ""  // Before creating a Task or any submission suspension.
        store.submitProviderAuth(
          sourceID: sourceID, sessionID: session.id, promptID: prompt.id, value: submitted)
      }
      .buttonStyle(SettingsButtonStyle(kind: .primary))
      .disabled(state.busy || input.isEmpty && prompt.allowEmpty != true)
      .accessibilityIdentifier("provider-submit-once")
    }
    .disabled(state.busy)
    .id(inputIdentity)
  }
  @ViewBuilder private func externalButton(_ label: String, url: String, identifier: String)
    -> some View
  {
    // Only explicitly tapped HTTP(S) URLs leave the app. Never copy URLs or codes.
    if let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil
    {
      Button(label) { openURL(url) }.buttonStyle(SettingsButtonStyle())
        .accessibilityIdentifier(identifier)
    }
  }
}
