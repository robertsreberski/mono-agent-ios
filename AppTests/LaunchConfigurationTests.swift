// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgent

#if DEBUG
  @Test func unknownScenarioFailsExplicitly() {
    #expect(throws: LaunchError.self) {
      try LaunchConfiguration(arguments: ["--scenario", "unknown"])
    }
    #expect(throws: LaunchError.self) { try LaunchConfiguration(arguments: ["--scenario"]) }
  }

  @Test func resetUsesIsolatedEmptyScenario() throws {
    let configuration = try LaunchConfiguration(arguments: ["--reset-test-data"])
    #expect(configuration.scenario?.rawValue == "connection-empty")
  }
#endif
