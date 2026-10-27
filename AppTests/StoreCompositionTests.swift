// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgent
@testable import MonoAgentStore

#if DEBUG
  @MainActor
  struct StoreCompositionTests {
    @Test func scenePrivacyIsPublishedBeforeAsyncLifecycleWork() async throws {
      let model = AppModel(scenario: .consoleOnline, storeScenario: .providerAuthSecret)
      model.scenePrivacyChanged(.inactive)
      await model.start()
      let store = try #require(model.store)
      #expect(
        store.providerPrivacyCovered, "a replacement Store inherits the synchronous scene cover")
      model.scenePrivacyChanged(.inactive)
      #expect(store.providerPrivacyCovered)
      #expect(!store.backgrounded, "inactive alone must not cancel a Safari flow")
      model.scenePrivacyChanged(.active)
      #expect(!store.providerPrivacyCovered)
      await store.stop()
    }

    @Test func providerScriptsAdvertiseAndConsumeEachPromptWithoutEchoingSecrets() async throws {
      for scenario in [
        StoreScenario.providerAuthSecret, .providerAuthManualCode, .providerAuthSelect,
        .providerAuthDeviceCode,
      ] {
        let model = AppModel(scenario: .consoleOnline, storeScenario: scenario)
        await model.start()
        let store = try #require(model.store)
        // Exercise typed routes against the same per-instance script used by XCUI.
        let status = try await store.api.providerAuth(id: AgentSettingsFixture.atlas, etag: nil)
          .valueRequired()
        let provider = try #require(status.providers.first)
        let method = try #require(provider.methods.first)
        var session = try await store.api.startAuth(
          id: AgentSettingsFixture.atlas,
          body: .init(
            providerId: provider.providerId, authType: method.authType, strategy: method.strategy))
        if session.error?.code == "device_code_unavailable" {
          session = try await store.api.startAuth(
            id: AgentSettingsFixture.atlas,
            body: .init(providerId: provider.providerId, authType: "oauth", strategy: "paste_back"))
        }
        if let prompt = session.prompt {
          var result = try await store.api.authInput(
            id: AgentSettingsFixture.atlas, sessionId: session.id,
            body: .init(promptId: prompt.id, value: "fictional-input"))
          if let next = result.prompt {
            result = try await store.api.authInput(
              id: AgentSettingsFixture.atlas, sessionId: result.id,
              body: .init(promptId: next.id, value: "Fictional account"))
          }
          #expect(result.state == "succeeded" && result.prompt == nil)
          #expect(!String(reflecting: result).contains("fictional-input"))
        } else {
          #expect(session.deviceCode?.userCode == "FLOCK-2048")
        }
        await store.stop()
      }
    }

    @Test func wakeConflictUsesTypedErrorAndDoesNotCloseEditor() async throws {
      let model = AppModel(scenario: .consoleOnline, storeScenario: .wakeConflict)
      await model.start()
      let store = try #require(model.store)
      await store.select(sourceID: DashboardFixture.atlas, threadID: "t-atlas-launch")
      let id = try #require(store.openWakeEditor(threadID: "t-atlas-launch"))
      await store.refreshWakeEditor(id)
      #expect(store.wakeEditor?.schedule?.revision == 1)
      var draft = try #require(store.wakeEditor?.draft)
      draft.compactFirst = false
      store.editWakeDraft(id, draft: draft)
      store.mutateWakeEditor(id, action: .save)
      try? await store.settleThreadWrites("t-atlas-launch")
      #expect(store.wakeEditor?.failure?.conflict == true)
      #expect(store.wakeEditor?.schedule?.revision == 1)
      await store.stop()
    }

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
      case .automations, .automationsFiltered, .automationsEmpty, .automationsOffline,
        .automationsDegraded, .cronConversation, .cronConfirm, .cronConfig:
        let snapshot = store.automationState(DashboardFixture.atlas)
        #expect(snapshot.overview != nil)
        #expect(model.launchAutomations)
        #expect(store.conversations[AutomationsFixture.threadID] != nil)
        let result = try await store.api.cronOverview(id: DashboardFixture.atlas, etag: nil)
          .valueRequired()
        #expect(result.jobs.count == (scenario == .automationsEmpty ? 0 : 3))
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
      case .dashboardPopulated, .dashboardSearch, .conversationPlaceholder,
        .conversationTranscript, .conversationStreaming, .conversationTools, .conversationLong,
        .conversationMarkdown, .conversationJobs, .conversationJobStack, .conversationSubagents,
        .conversationContext, .conversationReplyFiles, .conversationImages,
        .conversationRestartCard, .conversationImagesSingle, .conversationImagesEmpty,
        .conversationAttachments, .conversationMcpApp, .conversationMcpUnavailable,
        .conversationMcpLongTitle:
        #expect(store.agents.count == 4)
        #expect(store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.threads.count == 8)
        #expect(store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.nextCursor != nil)
        let active =
          try scenario.isTranscript
          ? DashboardModel.presentation(TranscriptFixture.thread(scenario)).active : true
        #expect(store.activeFleet?.runningCounts[DashboardFixture.atlas] == (active ? 3 : 2))
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
      case .composerEmpty, .composerDraftAttachments, .composerSkillPicker,
        .composerModelSelector, .composerRunning, .composerSendFailed, .composerQuote,
        .conversationAskForm, .conversationQuickReplies, .peerQuestionSheet:
        #expect(model.composerScript != nil)
        #expect(model.offersSampleAttachments)
        #expect(store.agents.first { $0.sourceId == DashboardFixture.atlas }?.models?.count == 3)
        #expect(store.conversations[DashboardFixture.openThreadID] != nil)
        #expect(model.launchThreadID == scenario.launchThreadID)
        #expect(
          (scenario.launchThreadID == nil) == (scenario == .composerEmpty),
          "every composer scenario but the new conversation opens the sample thread")
        if scenario == .composerDraftAttachments {
          #expect(
            store.draft(sourceID: DashboardFixture.atlas, threadID: DashboardFixture.openThreadID)?
              .text == ComposerFixture.draftText)
        }
      case .fidelityChat, .fidelityDashboard, .conversationActions, .projectPage, .projectSettings,
        .tagMenu, .tagSettings, .wakeNew, .wakeOnce, .wakeWeekly, .wakeConflict, .organizeLong,
        .organizeArchivedSearch:
        #expect(store.agents.map(\.label) == ["Atlas", "Grove"])
        #expect(
          store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.threads.map(\.title) == [
            "Garden planner", "Seed catalog", "Seedling notes",
          ])
        #expect(store.projects.first?.name == "Garden planner")
        #expect(store.tags.first?.name == "Research")
        #expect(store.activeFleet?.threads.first?.title == "Seed catalog")
        #expect(model.launchThreadID == scenario.launchThreadID)
        let rows = try ScreenFixture.messages()
        #expect(rows.map(\.role) == ["system", "user", "assistant"])
        #expect(QuoteFormatting.text(of: rows[1]) == ScreenFixture.question)
        #expect(rows[2].parts == [.text(.init(text: ScreenFixture.plan))])
        #expect(
          store.isUnread(
            try #require(store.buckets[BucketKey(sourceID: DashboardFixture.atlas)]?.threads.last)))
      case .agentRestart, .agentRestartConfirm, .agentRestartProgress, .agentRestartSuccess,
        .agentRestartFailure, .agentRestartUncertain, .agentRestartNotConfirmed,
        .providerAuthDense, .providerAuthDeviceCode, .providerAuthSecret,
        .providerAuthManualCode, .providerAuthSelect, .providerChecks, .providerUsageStale,
        .agentSettings, .agentSettingsUnsaved, .agentSettingsSaveError, .agentSettingsOffline,
        .agentSettingsDegraded, .notificationsExplainer, .notificationsInsecure:
        let atlas = try #require(store.agents.first { $0.sourceId == DashboardFixture.atlas })
        #expect(store.agents.count == 4)
        #expect(atlas.models == ["sample:large", "sample:small"])
        #expect(atlas.generation == "generation-1")
        #expect(
          atlas.status
            == (scenario == .agentSettingsOffline
              ? "offline" : scenario == .agentSettingsDegraded ? "degraded" : "online"))
        #expect((atlas.runSettings.override != nil) == (scenario == .agentSettingsDegraded))
        #expect(store.profile.endpoint.isInsecure == scenario.usesInsecureEndpoint)
        #expect(model.launchSettings == nil, "only --open-settings opens settings")
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
