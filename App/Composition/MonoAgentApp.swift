// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct MonoAgentApp: App {
  @State private var model = AppModel()
  var body: some Scene {
    WindowGroup {
      ConsoleShell(model: model)
        .preferredColorScheme(model.appearance)
        .task { await model.start() }
    }
  }
}
