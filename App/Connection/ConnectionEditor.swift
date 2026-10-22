// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ConnectionEditor: View {
  let registry: ConnectionRegistry
  let console: SavedConsole?
  let onSaved: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
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
      Form {
        Section("Console") {
          TextField("Display name (optional)", text: $name)
          TextField("http:// or https:// root URL", text: $address)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("console-url")
          Text(
            "Use a hostname or IP and optional port, with no path prefix. No request is made until you tap Connect."
          )
          .font(.caption)
        }
        if let endpoint, endpoint.isInsecure {
          Section("Insecure HTTP") {
            Label(
              "HTTP traffic is not encrypted and can be read or changed by others on the network.",
              systemImage: "lock.open")
            if !endpoint.isLocalHost {
              Toggle(
                "I understand the risk of plaintext HTTP to this non-local host",
                isOn: $acknowledged)
            }
          }
        }
        Section {
          Text(
            "Use only a trusted network or secure private tunnel. The console has no application login and grants powerful access to its agents."
          )
          Text(
            "On a physical device, localhost and loopback point to that device. Use your computer's LAN IP or Tailscale HTTPS URL instead."
          )
        }
        if let error { Section("Could not save") { Text(error).foregroundStyle(.red) } }
        Button(saving ? "Saving…" : "Connect") { save() }
          .disabled(
            saving
              || (endpoint?.isInsecure == true && endpoint?.isLocalHost == false && !acknowledged)
          )
          .accessibilityIdentifier("connect-console")
      }
      .navigationTitle(console == nil ? "Add console" : "Edit console")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
