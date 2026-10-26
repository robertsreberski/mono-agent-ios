// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

#if DEBUG
  @MainActor struct SettingsModelOptionsTests {
    private func agent(_ scenario: StoreScenario = .agentSettings) throws -> WebAgentSummary {
      try AgentSettingsFixture.bootstrap(scenario, theme: "evergreen").agents.first {
        $0.sourceId == DashboardFixture.atlas
      }!
    }

    private func catalog() throws -> SettingsModelOptions.Catalog {
      func page(_ provider: String, _ cursor: String?) throws -> WebModelPage {
        try AgentSettingsFixture.decode(
          AgentSettingsFixture.catalogPage(provider: provider, cursor: cursor))
      }
      return [
        ("sample", try page("sample", nil).models),
        ("grove", try page("grove", nil).models + page("grove", "grove-2").models),
      ]
    }

    @Test func rowsWidenTheShortlistWithCatalogOnlyModelsInFetchOrder() throws {
      let rows = SettingsModelOptions.rows(try agent(), catalog: try catalog(), selectedModel: "")
      #expect(
        rows.map(\.id) == [
          "", "sample:large", "sample:small", "sample:max", "grove:fast", "grove:deep",
        ])
      #expect(rows[0].name == "Default · Sample Large")
      #expect(rows[3].providerLabel == "Sample" && rows[4].providerLabel == "Grove")
      #expect(rows[2].providerLabel == "Sample", "advertised labels keep one group per provider")
      #expect(rows[1].supportsContext1M && rows[1].standardContextWindow == 200_000)
      #expect(rows[0].supportsContext1M, "the automatic row inherits the default route's context")
      #expect(!rows[2].supportsContext1M)
    }

    @Test func shortlistOnlyRowsMatchTheComposerWithoutACatalog() throws {
      let agent = try agent()
      let settings = SettingsModelOptions.rows(agent, catalog: [], selectedModel: "")
      let composer = ModelOptions.rows(agent, selectedModel: "").filter(\.selectable)
      #expect(settings.map(\.id) == composer.map(\.id))
      #expect(settings.map(\.efforts) == composer.map(\.efforts))
    }

    @Test func unlistedSavedChoiceIsKeptNotReplacedByTheAutomaticRow() throws {
      let rows = SettingsModelOptions.rows(
        try agent(), catalog: [], selectedModel: "grove:fast")
      #expect(rows.last?.id == "grove:fast" && rows.last?.providerLabel == "Grove")
    }

    @Test func catalogLaddersApplyWhereTheShortlistIsSilent() throws {
      let agent = try agent()
      let catalog = try catalog()
      let max = SettingsModelOptions.rows(agent, catalog: catalog, selectedModel: "")
        .first { $0.id == "sample:max" }
      #expect(max?.efforts.map(\.id) == ["", "medium", "high", "max"])
      #expect(max?.efforts.first?.name == "Default · Medium")
      let deep = SettingsModelOptions.rows(agent, catalog: catalog, selectedModel: "")
        .first { $0.id == "grove:deep" }
      #expect(deep?.efforts.map(\.name) == ["Default · Provider", "On", "Off"])
      #expect(
        SettingsModelOptions.effortAfterSwitching(
          agent, to: "grove:fast", currentEffort: "high", catalog: catalog) == "")
      #expect(
        SettingsModelOptions.effortAfterSwitching(
          agent, to: "sample:max", currentEffort: "high", catalog: catalog) == "high")
    }

    @Test func labelsUseAdvertisedNamesAndFallBackThroughConfig() throws {
      let agent = try agent()
      let catalog = try catalog()
      #expect(SettingsModelOptions.modelName(agent, nil, catalog: catalog) == "Provider default")
      #expect(SettingsModelOptions.modelName(agent, "grove:fast", catalog: catalog) == "Grove Fast")
      #expect(SettingsModelOptions.modelName(agent, "other:x", catalog: catalog) == "other:x")
      #expect(SettingsModelOptions.effortName(nil) == "Provider default")
      #expect(
        SettingsModelOptions.startSummary(agent, model: "", effort: "", catalog: catalog)
          == "Sample Large · Medium")
      #expect(
        SettingsModelOptions.startSummary(
          agent, model: "grove:fast", effort: "low", catalog: catalog)
          == "Grove Fast · Low")
      #expect(SettingsModelOptions.catalogProviders(agent) == ["sample", "grove"])
      #expect(SettingsModelOptions.standardLabel(200_000) == "200K")
      #expect(SettingsModelOptions.standardLabel(nil) == "Standard")
    }

    @Test func settingsLaunchDestinationParsesSectionsAndFailsClosed() throws {
      let index = try LaunchConfiguration(
        arguments: ["--scenario", "agent-settings", "--open-settings", "index"])
      #expect(index.settings == AgentSettingsTarget())
      let section = try LaunchConfiguration(
        arguments: ["--scenario", "agent-settings", "--open-settings", "new-conversations"])
      #expect(section.settings?.section == .newConversations)
      #expect(throws: LaunchError.self) {
        try LaunchConfiguration(arguments: ["--open-settings", "elsewhere"])
      }
      #expect(try LaunchConfiguration(arguments: ["--scenario", "agent-settings"]).settings == nil)
    }

    /// Web `run-controls.ts`: a blank new-conversation choice shows the console's saved run
    /// defaults (`runSettings.effective`), immediately after a save; threads keep their own.
    @Test func newConversationSelectorShowsSavedRunDefaultsAfterASave() async throws {
      let model = AppModel(scenario: .consoleOnline, storeScenario: .agentSettings)
      await model.start()
      let store = try #require(model.store)
      for _ in 0..<600 where store.connection != .live || !store.canWriteAgentSettings {
        try await Task.sleep(for: .milliseconds(10))
      }
      let atlas = DashboardFixture.atlas
      let composer = ComposerController(store: store, sourceID: atlas, threadID: nil)
      let existing = ComposerController(
        store: store, sourceID: atlas, threadID: DashboardFixture.openThreadID)
      func summary(_ controller: ComposerController) -> String {
        ModelOptions.summary(
          controller.selectorAgent, model: controller.runModel, effort: controller.runEffort)
      }
      #expect(summary(composer) == "Sample Large · Medium")
      store.editRunDefaults(sourceID: atlas, .init(model: "sample:small", effort: "low"))
      store.saveRunDefaults(sourceID: atlas, summary: "Sample Small · Low")
      for _ in 0..<600 where store.agent(atlas)?.runSettings.override == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(summary(composer) == "Sample Small · Low", "the new conversation inherits the save")
      #expect(!composer.hasRunOverride, "inheriting is not a local choice; creation omits it")
      #expect(summary(existing) == "Sample Large · Medium", "existing conversations keep theirs")
      composer.setModel("sample:large")
      #expect(summary(composer).hasPrefix("Sample Large"), "an explicit choice wins")
      await store.stop()
    }

    @Test func settingsScenariosAreServedByTheSettingsScript() {
      for scenario in StoreScenario.allCases {
        #expect(
          scenario.isAgentSettings
            == (scenario.rawValue.hasPrefix("agent-settings")
              || scenario.rawValue.hasPrefix("notifications-")))
      }
      #expect(StoreScenario.notificationsInsecure.usesInsecureEndpoint)
      #expect(AgentSettingsFixture.insecureEndpoint.isInsecure)
    }
  }
#endif
