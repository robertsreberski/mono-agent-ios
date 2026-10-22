// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// IDs, never DTOs, are navigation identity. Feature PRs can extend these routes.
enum AppRoute: Hashable {
  case console(UUID)
  case agent(profile: UUID, id: String)
}

struct ConsoleShell: View {
  let model: AppModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var route: AppRoute?
  @State private var editor: EditorDestination?
  @State private var deleting: SavedConsole?

  private var path: Binding<[AppRoute]> {
    Binding(get: { route.map { [$0] } ?? [] }, set: { route = $0.last })
  }

  var body: some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView {
          sidebar
        } detail: {
          NavigationStack { destination(route) }
        }
      } else {
        NavigationStack(path: path) {
          sidebar.navigationDestination(for: AppRoute.self) { destination($0) }
        }
      }
    }
    .sheet(item: $editor) { destination in
      ConnectionEditor(registry: model.registry, console: destination.console) { id in
        route = .console(id)
      }
    }
    .confirmationDialog(
      "Remove saved console and its local profile data?",
      isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } }
      ), titleVisibility: .visible
    ) {
      if let deleting {
        Button("Remove console", role: .destructive) {
          Task {
            await model.registry.remove(deleting.id)
            route = model.registry.selectedID.map(AppRoute.console)
            self.deleting = nil
          }
        }
      }
    }
    .onChange(of: model.isReady) { _, ready in
      if ready { route = model.registry.selectedID.map(AppRoute.console) }
    }
  }

  private var sidebar: some View {
    List {
      if let error = model.registry.storageError {
        Section("Storage warning") { Text(error).foregroundStyle(.red) }
      }
      Section {
        Text(
          "Connect only to a console you trust. There is no login: anyone with network access may control its agents."
        )
        Text("Loopback on an iPhone or iPad means that device, not your computer.")
          .foregroundStyle(.secondary)
      }
      Section("Saved consoles") {
        if model.registry.consoles.isEmpty {
          ContentUnavailableView(
            "No consoles yet", systemImage: "network",
            description: Text("Add the root URL of your web console to begin.")
          )
          .accessibilityIdentifier("connection-empty")
        }
        ForEach(model.registry.consoles) { console in
          VStack(alignment: .leading, spacing: 8) {
            Button {
              route = .console(console.id)
              Task { await model.registry.select(console.id) }
            } label: {
              VStack(alignment: .leading) {
                Text(
                  console.name.isEmpty
                    ? console.lastIdentity?.displayName ?? console.endpoint.origin : console.name)
                Text(console.endpoint.origin).font(.caption).foregroundStyle(.secondary)
                if console.endpoint.isInsecure {
                  Label("Insecure HTTP", systemImage: "lock.open").font(.caption)
                }
              }
            }
            HStack {
              Button("Edit") { editor = EditorDestination(console: console) }
              Button("Remove", role: .destructive) { deleting = console }
            }
            .font(.caption)
          }
          .buttonStyle(.borderless)
        }
      }
      Button("Add console", systemImage: "plus") { editor = EditorDestination(console: nil) }
        .accessibilityIdentifier("add-console")
        .disabled(!model.registry.isLoaded)
      if model.isReady {
        Text("Ready").font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("scenario-ready")
      }
    }
    .navigationTitle("Consoles")
  }

  @ViewBuilder
  private func destination(_ route: AppRoute?) -> some View {
    if case .console(let id) = route,
      let console = model.registry.consoles.first(where: { $0.id == id })
    {
      ConsoleDetail(console: console, registry: model.registry, ready: model.isReady)
    } else {
      ContentUnavailableView(
        "Choose a console", systemImage: "sidebar.left",
        description: Text("Saved consoles stay separate on this device."))
    }
  }
}

private struct EditorDestination: Identifiable {
  let id = UUID()
  let console: SavedConsole?
}

private struct ConsoleDetail: View {
  let console: SavedConsole
  let registry: ConnectionRegistry
  let ready: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: FoundationToken.contentSpacing) {
        if let error = registry.storageError {
          Label(error, systemImage: "externaldrive.badge.exclamationmark")
        }
        Text(console.endpoint.origin).font(.callout).textSelection(.enabled)
        if console.endpoint.isInsecure {
          Label(
            "Insecure HTTP — traffic can be read or changed on the network.",
            systemImage: "lock.open")
        }
        switch registry.states[console.id] ?? .disconnected {
        case .disconnected:
          Text("Not connected. A saved identity does not confirm connectivity.")
          connectButton("Connect")
        case .connecting:
          ProgressView("Checking console…")
        case .failed(let error):
          Label("Connection failed", systemImage: "exclamationmark.triangle")
            .font(.headline).accessibilityIdentifier("connection-failed")
          Text(error.localizedDescription)
          connectButton("Retry")
        case .connected(let identity):
          Label("Connected to \(identity.displayName)", systemImage: "checkmark.circle")
            .font(.headline).accessibilityIdentifier("console-online")
          Text("Console ready")
          Text("Agents and conversations will appear here in a future update.")
            .foregroundStyle(.secondary)
          connectButton("Check connection again")
        }
        if ready {
          Text("Ready").font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("scenario-ready")
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(console.name.isEmpty ? "Console" : console.name)
  }

  private func connectButton(_ title: String) -> some View {
    Button(title) { Task { await registry.connect(console.id) } }
      .buttonStyle(.borderedProminent)
  }
}
