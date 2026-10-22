// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import SwiftUI

  #Preview("Synthetic fixture — empty") {
    let model = AppModel(scenario: .connectionEmpty)
    ConsoleShell(model: model).task { await model.start() }
  }

  #Preview("Synthetic fixture — failed") {
    let model = AppModel(scenario: .connectionFailed)
    ConsoleShell(model: model).task { await model.start() }
  }

  #Preview("Synthetic fixture — online") {
    let model = AppModel(scenario: .consoleOnline)
    ConsoleShell(model: model).task { await model.start() }
  }
#endif
