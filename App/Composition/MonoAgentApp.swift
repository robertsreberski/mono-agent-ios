// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI

@main
struct MonoAgentApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AppModel()
  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG
          if let catalog = model.catalog {
            DesignCatalogView(scenario: catalog)
          } else {
            ConsoleShell(model: model)
          }
        #else
          ConsoleShell(model: model)
        #endif
      }
      #if DEBUG
        .prefersOpaqueSurfaces(model.opaqueFixtureSurfaces)
        .environment(\.mcpDiagnostics, model.mcpScript?.diagnostics)
      #endif
      .preferredColorScheme(model.appearance)
      .task { await model.start() }
      .task(id: model.storeCompositionKey) { await model.synchronizeStore() }
      .onChange(of: scenePhase) { _, phase in Task { await model.scenePhaseChanged(phase) } }
    }
  }
}
