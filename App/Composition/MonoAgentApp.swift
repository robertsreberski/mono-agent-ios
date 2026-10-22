// SPDX-License-Identifier: GPL-3.0-only
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
      .preferredColorScheme(model.appearance)
      .task { await model.start() }
      .task(id: model.storeCompositionKey) { await model.synchronizeStore() }
      .onChange(of: scenePhase) { _, phase in Task { await model.scenePhaseChanged(phase) } }
    }
  }
}
