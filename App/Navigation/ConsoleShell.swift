// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

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

/// The single scene's root. A console with a retained identity opens on its dashboard; the
/// saved-console screens stay the root until then and remain reachable from the dashboard.
struct ConsoleShell: View {
  let model: AppModel
  @State private var managingConsoles = false

  private var theme: ConsoleTheme {
    ConsoleTheme(connection: model.registry.selectedID.flatMap { model.registry.states[$0] })
  }

  var body: some View {
    Group {
      if let store = model.store {
        DashboardShell(model: model, store: store) { managingConsoles = true }
          .id(store.namespace)
      } else if model.expectsStore {
        NavigationStack {
          LoadingStateView("Opening console…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .webPanelBackground(theme.palette.panel)
            .accessibilityIdentifier("connection-loading")
        }
      } else {
        ConsoleManager(model: model, presentation: .root)
      }
    }
    .consoleTheme(theme)
    .sheet(isPresented: $managingConsoles) {
      // A sheet over the dashboard: the frosted veil on the system material; the same screens
      // drop their panel fills and settings cards become glass inks (GLASS-RULES.md).
      ConsoleManager(model: model, presentation: .sheet).webSheetVeil()
    }
    .onChange(of: model.expectsStore) { _, expects in
      // The dashboard behind the sheet is gone (removed, edited or never-connected console):
      // the connection screens become the root again.
      if !expects { managingConsoles = false }
    }
  }
}

/// Saved-console management: list, add/edit/remove and the connection detail. The root
/// presentation adapts to the size class; the sheet presentation always stacks.
struct ConsoleManager: View {
  enum Presentation { case root, sheet }

  let model: AppModel
  let presentation: Presentation
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  @Environment(\.webMaterial) private var material
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
      if sizeClass == .regular && presentation == .root {
        NavigationSplitView {
          sidebar
        } detail: {
          NavigationStack { destination(route) }
        }
      } else {
        NavigationStack(path: path) {
          sidebar
            .scrollContentBackground(.hidden)
            .webPanelBackground(theme.palette.panel)
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
      .webSheetVeil()
    }
    .confirmationDialog(
      "Remove saved console and all its retained local data?",
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
    .onAppear {
      if presentation == .root, model.isReady, route == nil {
        route = model.registry.selectedID.map(AppRoute.console)
      }
    }
    .onChange(of: model.isReady) { _, ready in
      if ready && presentation == .root {
        route = model.registry.selectedID.map(AppRoute.console)
      }
    }
  }
  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let error = model.registry.localDataError {
          Group { ConnectionBanner(.storage, title: "Deletion warning", message: error) }
        }
        if let error = model.registry.storageError {
          Group {
            ConnectionBanner(.storage, title: "Storage warning", message: error)
              .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Saved consoles").webFont(.settingsSectionTitle).accessibilityAddTraits(.isHeader)
          Text(
            "Connect only to a console you trust. There is no login: anyone with network access may control its agents. Loopback on an iPhone or iPad means that device, not your computer."
          )
          .webFont(.notice).foregroundStyle(material.textMuted.color)
          .fixedSize(horizontal: false, vertical: true)
        }
        if model.registry.consoles.isEmpty {
          EmptyStateView(
            "No consoles yet", systemImage: "network",
            message: "Add the root URL of your web console to begin.",
            actionTitle: "Add console", action: { editor = EditorDestination(console: nil) }
          )
          .disabled(!model.registry.isLoaded)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("connection-empty")
        } else {
          SettingsGroup {
            ForEach(model.registry.consoles) { console in
              ConsoleRow(
                console: console, state: model.registry.states[console.id],
                open: {
                  route = .console(console.id)
                  Task { await model.registry.select(console.id) }
                },
                edit: { editor = EditorDestination(console: console) },
                remove: { deleting = console })
              if console.id != model.registry.consoles.last?.id { WebHairline() }
            }
          }
        }
      }
      .padding(.horizontal, 17)
      .padding(.vertical, 20)
      .frame(maxWidth: 674)
      .frame(maxWidth: .infinity)
    }
    .webPanelBackground(theme.palette.panel)
    // Identifier metadata on an existing container adds no visible or spoken content.
    .accessibilityIdentifier(model.isReady ? "scenario-ready" : "connection-loading")
    .navigationTitle("Consoles")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if presentation == .sheet {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Done")
          .accessibilityIdentifier("consoles-done")
        }
        .sharedBackgroundVisibility(.hidden)
      }
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
      ConsoleDetail(
        console: console, registry: model.registry, ready: model.isReady,
        dashboardOpen: model.store?.profile.id == console.id)
    } else {
      EmptyStateView(
        "Choose a console", systemImage: "sidebar.left",
        message: "Saved consoles stay separate on this device."
      )
      .frame(maxHeight: .infinity)
      .webPanelBackground(theme.palette.panel)
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
  @Environment(\.webMaterial) private var material

  private var title: String {
    console.name.isEmpty
      ? console.lastIdentity?.displayName ?? console.endpoint.origin : console.name
  }

  @Environment(\.dynamicTypeSize) private var textSize

  var body: some View {
    HStack(spacing: 4) {
      Button(action: open) {
        HStack(spacing: 10) {
          if !textSize.isAccessibilitySize {
            Image(systemName: "network")
              .foregroundStyle(material.textMuted.color)
              .frame(width: 30, height: 30)
              .webLayeredSurface(
                RoundedRectangle(cornerRadius: 8), fill: WebColor.surfaceSubtle.color
              )
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 5) {
            Text(title).webFont(.rowTitle).foregroundStyle(WebColor.text.color)
            Text(console.endpoint.origin).webFont(.settingsAddress)
              .foregroundStyle(material.textMuted.color)
              .lineLimit(1).truncationMode(.middle)
            if textSize.isAccessibilitySize { indicators }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if !textSize.isAccessibilitySize { indicators }
          Image(systemName: "chevron.right")
            .webFont(.chip).foregroundStyle(material.textMuted.color)
            .accessibilityHidden(true)
        }
        .frame(minHeight: WebMetrics.rowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("console-row-" + console.id.uuidString)
      .contextMenu { actions }
      Menu {
        actions
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(material.textMuted.color)
      .accessibilityLabel("Actions for " + title)
      .accessibilityIdentifier("console-actions-" + console.id.uuidString)
    }
  }

  @ViewBuilder private var actions: some View {
    Button("Edit", systemImage: "pencil", action: edit)
    Button("Remove", systemImage: "trash", role: .destructive, action: remove)
  }

  @ViewBuilder private var indicators: some View {
    VStack(alignment: .leading, spacing: 4) {
      ConsoleStatus(kind: state.status.kind, label: state.status.label)
      if console.endpoint.isInsecure { ConsoleStatus(kind: .insecure, label: "HTTP") }
    }
  }
}

/// Web settings status: compact uppercase text, a dot and an explicit non-colour label.
private struct ConsoleStatus: View {
  let kind: StatusKind
  let label: String
  @Environment(\.consoleTheme) private var theme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "circle.fill").font(.system(size: 5))
      Text(label.uppercased()).webFont(.chip)
    }
    .foregroundStyle(kind.tone.color(in: theme).color)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }
}

private struct ConsoleDetail: View {
  let console: SavedConsole
  let registry: ConnectionRegistry
  let ready: Bool
  let dashboardOpen: Bool
  @Environment(\.webMaterial) private var material
  @Environment(\.consoleTheme) private var theme

  private var state: ConnectionState { registry.states[console.id] ?? .disconnected }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let error = registry.storageError {
          ConnectionBanner(.storage, title: "Storage warning", message: error)
        }
        SettingsGroup {
          VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Address")
            Text(console.endpoint.origin).webFont(.code).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          WebHairline()
          HStack {
            Eyebrow("Status")
            Spacer()
            ConsoleStatus(kind: Optional(state).status.kind, label: Optional(state).status.label)
          }
          if console.endpoint.isInsecure {
            WebHairline()
            Text("Insecure HTTP — traffic can be read or changed on the network.")
              .webFont(.notice).foregroundStyle(material.textMuted.color)
          }
        }
        status
      }
      .padding(17)
      .frame(maxWidth: DesignMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .webPanelBackground(theme.palette.panel)
    .accessibilityIdentifier(ready ? "scenario-ready" : "connection-loading")
    .navigationTitle(console.name.isEmpty ? "Console" : console.name)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var status: some View {
    switch state {
    case .disconnected:
      VStack(alignment: .leading, spacing: 12) {
        Text("A saved identity does not confirm connectivity.")
          .webFont(.notice).foregroundStyle(material.textMuted.color)
        connectionAction("Connect")
      }
    case .connecting:
      LoadingStateView("Checking console…")
        .accessibilityIdentifier("connection-checking")
    case .failed(let error):
      ErrorStateView(
        "Connection failed", message: error.localizedDescription,
        retryTitle: "Retry", retry: { connect() }
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("connection-failed")
    case .connected(let identity):
      VStack(alignment: .leading, spacing: 12) {
        ConsoleStatus(kind: .online, label: "Connected to \(identity.displayName)")
          .accessibilityIdentifier("console-online")
        Text(
          dashboardOpen
            ? "Its agents and conversations are on the dashboard behind this sheet."
            : "Its dashboard opens as soon as this console is selected."
        )
        .webFont(.notice).foregroundStyle(material.textMuted.color)
        connectionAction("Check connection again")
      }
    }
  }

  private func connectionAction(_ title: String) -> some View {
    Button(title) { connect() }
      .buttonStyle(WebStateActionStyle())
      .frame(maxWidth: 320)
  }

  private func connect() { Task { await registry.connect(console.id) } }
}
