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

extension ConsoleTheme {
  /// Only a live, connected identity selects a theme; anything else uses the fallback.
  init(connection state: ConnectionState?) {
    if case .connected(let identity) = state {
      self.init(serverValue: identity.theme)
    } else {
      self = .fallback
    }
  }
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

  /// The routed console's theme, else the selected console's, else evergreen.
  private var theme: ConsoleTheme {
    var id = model.registry.selectedID
    if case .console(let routed) = route { id = routed }
    return ConsoleTheme(connection: id.flatMap { model.registry.states[$0] })
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
          sidebar
            .scrollContentBackground(.hidden)
            .background(theme.palette.canvas.color)
            .navigationDestination(for: AppRoute.self) { destination($0) }
        }
      }
    }
    .consoleTheme(theme)
    .sheet(item: $editor) { destination in
      ConnectionEditor(registry: model.registry, console: destination.console) { id in
        route = .console(id)
      }
      .consoleTheme(theme)
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
        Section {
          ConnectionBanner(.storage, title: "Storage warning", message: error)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
      }
      Section {
        ConnectionBanner(
          .notice, title: "Connect only to a console you trust",
          message:
            "There is no login: anyone with network access may control its agents. Loopback on an iPhone or iPad means that device, not your computer."
        )
        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
      }
      Section {
        if model.registry.consoles.isEmpty {
          EmptyStateView(
            "No consoles yet", systemImage: "network",
            message: "Add the root URL of your web console to begin.",
            actionTitle: "Add console", action: { editor = EditorDestination(console: nil) }
          )
          .disabled(!model.registry.isLoaded)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("connection-empty")
        }
        ForEach(model.registry.consoles) { console in
          ConsoleRow(
            console: console, state: model.registry.states[console.id],
            open: {
              route = .console(console.id)
              Task { await model.registry.select(console.id) }
            },
            edit: { editor = EditorDestination(console: console) },
            remove: { deleting = console })
        }
      } header: {
        SectionHeader("Saved consoles")
      }
    }
    // Identifier metadata on an existing container adds no visible or spoken content.
    .accessibilityIdentifier(model.isReady ? "scenario-ready" : "connection-loading")
    .navigationTitle("Consoles")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add console", systemImage: "plus") { editor = EditorDestination(console: nil) }
          .accessibilityIdentifier("add-console")
          .disabled(!model.registry.isLoaded)
      }
    }
  }

  @ViewBuilder
  private func destination(_ route: AppRoute?) -> some View {
    if case .console(let id) = route,
      let console = model.registry.consoles.first(where: { $0.id == id })
    {
      ConsoleDetail(console: console, registry: model.registry, ready: model.isReady)
    } else {
      EmptyStateView(
        "Choose a console", systemImage: "sidebar.left",
        message: "Saved consoles stay separate on this device."
      )
      .frame(maxHeight: .infinity)
      .background(theme.palette.canvas.color)
    }
  }
}

private struct EditorDestination: Identifiable {
  let id = UUID()
  let console: SavedConsole?
}

extension ConnectionState? {
  fileprivate var status: (kind: StatusKind, label: String) {
    switch self ?? .disconnected {
    case .disconnected: (.disconnected, "Not connected")
    case .connecting: (.connecting, "Checking…")
    case .failed: (.failed, "Connection failed")
    case .connected: (.online, "Online")
    }
  }
}

private struct ConsoleRow: View {
  let console: SavedConsole
  let state: ConnectionState?
  let open: () -> Void
  let edit: () -> Void
  let remove: () -> Void

  private var title: String {
    console.name.isEmpty
      ? console.lastIdentity?.displayName ?? console.endpoint.origin : console.name
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Button(action: open) {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          Text(title).designFont(.headline).foregroundStyle(.primary)
          // One line in the list; the detail screen shows the full, selectable address.
          Text(console.endpoint.origin).designFont(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSpacing.md) { indicators }
            VStack(alignment: .leading, spacing: DesignSpacing.xs) { indicators }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      // Plain keeps status colours and text hierarchy instead of tinting the whole label.
      .buttonStyle(.plain)
      HStack(spacing: DesignSpacing.lg) {
        Button("Edit", action: edit)
        Button("Remove", role: .destructive, action: remove)
      }
      .buttonStyle(.borderless)
      .designFont(.caption)
    }
    .padding(.vertical, DesignSpacing.xs)
  }

  @ViewBuilder private var indicators: some View {
    StatusIndicator(state.status.kind, label: state.status.label)
    if console.endpoint.isInsecure {
      StatusIndicator(.insecure)
    }
  }
}

private struct ConsoleDetail: View {
  let console: SavedConsole
  let registry: ConnectionRegistry
  let ready: Bool
  @Environment(\.consoleTheme) private var theme

  private var state: ConnectionState { registry.states[console.id] ?? .disconnected }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignSpacing.lg) {
        if let error = registry.storageError {
          ConnectionBanner(.storage, title: "Storage warning", message: error)
        }
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
          Text("Address").designFont(.caption).foregroundStyle(.secondary)
          Text(console.endpoint.origin).designFont(.code).textSelection(.enabled)
        }
        .contentSurface()
        if console.endpoint.isInsecure {
          ConnectionBanner(
            .insecureHTTP, title: "Insecure HTTP",
            message: "Traffic can be read or changed on the network.")
        }
        status
      }
      .padding(DesignSpacing.lg)
      .frame(maxWidth: DesignMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.palette.canvas.color)
    .safeAreaBar(edge: .bottom) { actionBar }
    .scrollEdgeEffectStyle(.hard, for: .bottom)
    .accessibilityIdentifier(ready ? "scenario-ready" : "connection-loading")
    .navigationTitle(console.name.isEmpty ? "Console" : console.name)
  }

  @ViewBuilder private var status: some View {
    switch state {
    case .disconnected:
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        StatusIndicator(.disconnected)
        Text("A saved identity does not confirm connectivity.")
          .designFont(.supporting).foregroundStyle(.secondary)
      }
      .contentSurface()
    case .connecting:
      LoadingStateView("Checking console…").contentSurface()
    case .failed(let error):
      ErrorStateView("Connection failed", message: error.localizedDescription)
        .contentSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-failed")
    case .connected(let identity):
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        StatusChip(.online, label: "Connected to \(identity.displayName)")
          .accessibilityIdentifier("console-online")
        Text("Console ready").designFont(.sectionTitle)
        Text("Agents and conversations will appear here in a future update.")
          .designFont(.supporting).foregroundStyle(.secondary)
      }
      .contentSurface()
    }
  }

  /// The detail's single action floats above content as an intentional glass control.
  @ViewBuilder private var actionBar: some View {
    let title: String? =
      switch state {
      case .disconnected: "Connect"
      case .connecting: nil
      case .failed: "Retry"
      case .connected: "Check connection again"
      }
    if let title {
      GlassEffectContainer {
        Button {
          Task { await registry.connect(console.id) }
        } label: {
          Text(title).frame(maxWidth: .infinity)
        }
        .designButtonStyle(.primary, placement: .floating)
        .controlSize(.large)
        .frame(maxWidth: 420)
      }
      .padding(.horizontal, DesignSpacing.lg)
      .padding(.bottom, DesignSpacing.sm)
    }
  }
}
