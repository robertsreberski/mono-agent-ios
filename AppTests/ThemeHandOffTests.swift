// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

@Suite("Connection theme hand-off")
struct ThemeHandOffTests {
  private func identity(_ theme: String) -> ConsoleIdentity {
    ConsoleIdentity(hostName: "console.example.ts.net", displayName: "Flockbox", theme: theme)
  }

  @Test(arguments: ConsoleTheme.allCases)
  func connectedIdentitySelectsItsTheme(_ theme: ConsoleTheme) {
    #expect(ConsoleTheme(connection: .connected(identity(theme.rawValue))) == theme)
  }

  @Test func unknownThemeOrNoLiveConnectionFallsBackToEvergreen() {
    #expect(ConsoleTheme(connection: .connected(identity("sunset"))) == .evergreen)
    #expect(ConsoleTheme(connection: nil) == .evergreen)
    #expect(ConsoleTheme(connection: .disconnected) == .evergreen)
    #expect(ConsoleTheme(connection: .connecting) == .evergreen)
    #expect(ConsoleTheme(connection: .failed(.connectivity)) == .evergreen)
  }
}
