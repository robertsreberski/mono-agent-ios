// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct MonoAgentApp: App {
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
    }
  }
}
