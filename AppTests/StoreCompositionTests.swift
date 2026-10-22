// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentTestSupport
import Testing

@testable import MonoAgent
@testable import MonoAgentStore

#if DEBUG
  @MainActor
  struct StoreCompositionTests {
    @Test func failedReconnectRetainsOfflineStoreWithoutCrossConsoleReplacement() async throws {
      let model = AppModel(scenario: .consoleOnline)
      await model.start()
      let initial = try #require(model.store)
      let id = try #require(model.registry.selectedID)
      // The per-instance probe script is exhausted. This retry fails closed, never goes live.
      await model.registry.connect(id)
      await model.synchronizeStore()
      #expect(model.store === initial)
      #expect(initial.connection == .offline)
      #expect(initial.bootstrap != nil)
      #expect(!initial.enabled)
      await model.scenePhaseChanged(.background)
      await model.scenePhaseChanged(.active)
      #expect(initial.connection == .offline)
      await initial.stop()
    }

    @Test(arguments: StoreScenario.allCases)
    func scenariosLoadThroughComposition(_ scenario: StoreScenario) async throws {
      let configuration = try LaunchConfiguration(arguments: ["--scenario", scenario.rawValue])
      #expect(configuration.storeScenario == scenario)
      #expect(configuration.scenario == .consoleOnline)
      let model = AppModel(scenario: .consoleOnline, storeScenario: scenario)
      await model.start()
      let store = try #require(model.store)
      #expect(store.hydrated)
      switch scenario {
      case .offline:
        #expect(store.connection == .offline)
        #expect(store.conversations["thread-example"]?.freshness == .stale)
      case .streaming:
        #expect(store.conversations["thread-example"]?.thread.runState.status == "running")
        #expect(store.conversations["thread-example"]?.runningConfirmed == true)
      case .unread:
        let thread = try #require(store.conversations["thread-example"]?.thread)
        #expect(store.isUnread(thread))
      case .uncertain: #expect(store.pendingSubmissions.count == 1)
      }
      await model.scenePhaseChanged(.inactive)
      await model.scenePhaseChanged(.background)
      #expect(store.connection == .offline)
      await store.stop()
    }
  }
#endif
