// SPDX-License-Identifier: GPL-3.0-only
import Foundation
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
      #expect(scenario.isDashboard == !scenario.rawValue.hasPrefix("store-"))
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
      case .dashboardPopulated, .dashboardSearch, .conversationPlaceholder:
        #expect(store.agents.count == 4)
        #expect(store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.threads.count == 8)
        #expect(store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.nextCursor != nil)
        #expect(store.activeFleet?.runningCounts[DashboardFixture.atlas] == 3)
        #expect(store.isRunningConfirmed(threadID: "t-atlas-launch"))
        let notes = try #require(
          store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.threads.first {
            $0.id == "t-atlas-notes"
          })
        #expect(store.isUnread(notes))
        #expect(store.projects.count == 3 && store.tags.count == 4)
        #expect(model.referenceDate == DashboardFixture.now)
        #expect(model.launchQuery == scenario.launchQuery)
        #expect(model.launchThreadID == scenario.launchThreadID)
        if scenario == .dashboardSearch {
          let result = try await store.searchThreads(
            sourceID: DashboardFixture.atlas, query: DashboardFixture.searchQuery)
          #expect(result.hits.count == 3)
        }
      case .dashboardEmpty:
        #expect(store.agents.count == 1)
        #expect(store.buckets.values.allSatisfy { $0.threads.isEmpty })
        #expect(store.activeFleet?.threads.isEmpty == true)
      case .dashboardOffline:
        #expect(store.connection == .offline)
        #expect(store.errorMessage != nil)
        // The cache still shows running work, but nothing confirms it.
        #expect(store.activeFleet?.threads.count == 4)
        #expect(!store.isRunningConfirmed(threadID: "t-atlas-launch"))
        await #expect(throws: (any Error).self) {
          try await store.searchThreads(sourceID: DashboardFixture.atlas, query: "notes")
        }
      }
      await model.scenePhaseChanged(.inactive)
      await model.scenePhaseChanged(.background)
      #expect(store.connection == .offline)
      await store.stop()
    }
  }
#endif

#if DEBUG
  @MainActor
  struct DashboardFixtureCompositionTests {
    @Test func fixtureThemeReachesTheConsoleIdentityAndBootstrap() async throws {
      let configuration = try LaunchConfiguration(
        arguments: ["--scenario", "dashboard-populated", "--fixture-theme", "plum"])
      #expect(configuration.fixtureTheme == "plum")
      let model = AppModel(
        scenario: .consoleOnline, storeScenario: .dashboardPopulated, fixtureTheme: "plum")
      await model.start()
      let id = try #require(model.registry.selectedID)
      guard case .connected(let identity) = model.registry.states[id] else {
        Issue.record("fixture console did not connect")
        return
      }
      #expect(identity.theme == "plum")
      #expect(model.store?.bootstrap?.console.theme == "plum")
      await model.store?.stop()
    }

    @Test func unknownFixtureThemeFailsExplicitly() {
      #expect(throws: LaunchError.self) {
        try LaunchConfiguration(arguments: [
          "--scenario", "dashboard-populated", "--fixture-theme", "sunset",
        ])
      }
    }

    @Test func fixtureTransportFailsClosedForUnknownRoutes() async throws {
      let transport = ScenarioConsoleTransport(.dashboardPopulated)
      var request = URLRequest(url: URL(string: "https://console.example.ts.net/api/v1/unknown")!)
      request.httpMethod = "GET"
      await #expect(throws: URLError.self) { try await transport.send(request) }
      let missing = URLRequest(
        url: URL(string: "https://console.example.ts.net/api/v1/threads/t-missing")!)
      await #expect(throws: URLError.self) { try await transport.send(missing) }
    }

    @Test func consoleOnlineReconciliationReadsSucceedWithoutAProblemBanner() async throws {
      let model = AppModel(scenario: .consoleOnline)
      await model.start()
      let store = try #require(model.store)
      await store.reconcile()
      #expect(store.errorMessage == nil)
      #expect(model.isReady)
      await store.stop()
    }
  }
#endif
