// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ConnectionEditor: View {
  let registry: ConnectionRegistry
  let console: SavedConsole?
  let onSaved: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.webMaterial) private var material
  @Environment(\.consoleTheme) private var theme
  @State private var name: String
  @State private var address: String
  @State private var acknowledged: Bool
  @State private var error: String?
  @State private var saving = false

  init(registry: ConnectionRegistry, console: SavedConsole?, onSaved: @escaping (UUID) -> Void) {
    self.registry = registry
    self.console = console
    self.onSaved = onSaved
    _name = State(initialValue: console?.name ?? "")
    _address = State(initialValue: console?.endpoint.origin ?? "")
    _acknowledged = State(initialValue: console?.httpAcknowledged ?? false)
  }

  private var endpoint: ConsoleEndpoint? { try? ConsoleEndpoint(address) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Name")
            TextField("Display name (optional)", text: $name).settingsField()
              .accessibilityLabel("Name")
              .accessibilityIdentifier("console-name")
          }
          VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Address")
            TextField("http:// or https:// root URL", text: $address).settingsField()
              .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityLabel("Address")
              .accessibilityIdentifier("console-url")
            Text(
              "Use a hostname or IP and optional port, with no path prefix. No request is made until you tap Connect."
            )
            .webFont(.notice).foregroundStyle(material.textMuted.color)
          }
          if let endpoint, endpoint.isInsecure {
            VStack(alignment: .leading, spacing: 10) {
              Label("Insecure HTTP", systemImage: "lock.open")
                .webFont(.rowTitle).foregroundStyle(DesignColor.warning.color)
              Text(
                "HTTP traffic is not encrypted and can be read or changed by others on the network."
              )
              .webFont(.notice).foregroundStyle(material.textMuted.color)
              if !endpoint.isLocalHost {
                Toggle(
                  "I understand the risk of plaintext HTTP to this non-local host",
                  isOn: $acknowledged
                )
                .accessibilityIdentifier("console-http-acknowledgement")
              }
            }
            .padding(.vertical, 10)
          }
          VStack(alignment: .leading, spacing: 10) {
            Text(
              "Use only a trusted network or secure private tunnel. The console has no application login and grants powerful access to its agents."
            )
            Text(
              "On a physical device, localhost and loopback point to that device. Use your computer's LAN IP or Tailscale HTTPS URL instead."
            )
          }
          .webFont(.notice).foregroundStyle(material.textMuted.color)
          if let error {
            SettingsGroup("Could not save") { StatusIndicator(.failed, label: error) }
          }
        }
        .webFont(.notice)
        .padding(.horizontal, 17)
        .padding(.vertical, 20)
        .frame(maxWidth: 674)
        .frame(maxWidth: .infinity)
      }
      .webPanelBackground(theme.palette.panel)
      .navigationTitle(console == nil ? "Add console" : "Edit console")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Cancel")
        }
        .sharedBackgroundVisibility(.hidden)
        // System toolbars supply Liquid Glass; the confirmation action is prominent.
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Connect") { save() }
            .disabled(
              saving
                || (endpoint?.isInsecure == true && endpoint?.isLocalHost == false && !acknowledged)
            )
            .accessibilityIdentifier("connect-console")
        }
      }
      .onChange(of: address) { _, _ in acknowledged = false }
    }
  }

  private func save() {
    saving = true
    Task {
      do {
        let endpoint = try ConsoleEndpoint(address)
        let id: UUID
        if let console {
          id = try await registry.edit(
            id: console.id, name: name, endpoint: endpoint, httpAcknowledged: acknowledged)
        } else {
          id = try await registry.add(
            name: name, endpoint: endpoint, httpAcknowledged: acknowledged)
        }
        await registry.select(id)
        onSaved(id)
        dismiss()
        await registry.connect(id)
      } catch { self.error = error.localizedDescription }
      saving = false
    }
  }
}
