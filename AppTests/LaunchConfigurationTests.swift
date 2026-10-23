// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgent

#if DEBUG
  @Test func unknownScenarioFailsExplicitly() {
    #expect(throws: LaunchError.self) {
      try LaunchConfiguration(arguments: ["--scenario", "unknown"])
    }
    #expect(throws: LaunchError.self) { try LaunchConfiguration(arguments: ["--scenario"]) }
    #expect(throws: LaunchError.self) {
      try LaunchConfiguration(arguments: ["--scenario", "design-catalog-sunset"])
    }
  }

  @Test func resetUsesIsolatedEmptyScenario() throws {
    let configuration = try LaunchConfiguration(arguments: ["--reset-test-data"])
    #expect(configuration.scenario?.rawValue == "connection-empty")
    #expect(configuration.catalog == nil)
  }

  @Test(arguments: DesignCatalogScenario.allCases)
  func catalogScenariosUseIsolatedEmptyStorage(_ catalog: DesignCatalogScenario) throws {
    let configuration = try LaunchConfiguration(arguments: ["--scenario", catalog.rawValue])
    #expect(configuration.catalog == catalog)
    #expect(configuration.scenario?.rawValue == "connection-empty")
  }

  @Test func catalogVariantsCoverEveryThemeAndAccessibilityFallback() {
    let themes = Set(DesignCatalogScenario.allCases.map(\.theme))
    #expect(themes.count == 4)
    #expect(DesignCatalogScenario.allCases.contains { $0.largeText })
    #expect(DesignCatalogScenario.allCases.contains { $0.opaqueSurfaces })
    #expect(DesignCatalogScenario.allCases.allSatisfy { $0.rawValue.hasPrefix("design-catalog") })
  }

  @Test func connectionScenariosDoNotOpenTheCatalog() throws {
    let configuration = try LaunchConfiguration(arguments: ["--scenario", "console-online"])
    #expect(configuration.catalog == nil)
    #expect(configuration.scenario?.rawValue == "console-online")
  }
#endif

#if DEBUG
  @Test(arguments: StoreScenario.allCases)
  func everyStoreScenarioLaunchesTheConnectedFixture(_ scenario: StoreScenario) throws {
    let configuration = try LaunchConfiguration(arguments: ["--scenario", scenario.rawValue])
    #expect(configuration.storeScenario == scenario)
    #expect(configuration.catalog == nil)
    #expect(configuration.fixtureTheme == "evergreen")
  }
#endif
