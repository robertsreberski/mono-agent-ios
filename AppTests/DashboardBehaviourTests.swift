// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

#if DEBUG
  /// A sleep that only returns when the test releases it, recording each requested wait.
  private actor ManualSleeper {
    private(set) var waits: [Duration] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func sleep(_ duration: Duration) async throws {
      waits.append(duration)
      try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func releaseAll() {
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }

    func pending() -> Int { waiters.count }
  }

  @MainActor
  private final class SearchRecorder {
    var queries: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdFirst = false
    var failing = false

    func search(_ source: String, _ query: String) async throws -> ThreadSearchResult {
      queries.append(query)
      if holdFirst && queries.count == 1 {
        await withCheckedContinuation { gate = $0 }
      }
      if failing { throw URLError(.notConnectedToInternet) }
      let page = try JSONDecoder().decode(
        WebThreadSearchPage.self,
        from: JSONEncoder().encode(
          try DashboardFixture.searchPage(query: query, source: source)))
      return ThreadSearchResult(hits: query == "notes" ? page.hits : [], truncated: false)
    }
  }

  @MainActor
  private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<10_000 {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("Condition did not become true")
  }

  @MainActor @Suite("Thread search")
  struct ThreadSearchTests {
    @Test func highlightSegmentsSplitSentinelsAndDegradeWhenUnbalanced() {
      #expect(
        SearchHighlight.segments("a \u{2}b\u{3} c")
          == [
            .init(text: "a ", match: false), .init(text: "b", match: true),
            .init(text: " c", match: false),
          ])
      #expect(
        SearchHighlight.segments("open \u{2}never closed") == [
          .init(text: "open never closed", match: false)
        ])
      #expect(
        SearchHighlight.segments("stray \u{3}close") == [.init(text: "stray close", match: false)])
      #expect(SearchHighlight.segments("") == [])
      #expect(
        SearchHighlight.title("Weekly Field Notes", query: " notes ")
          == [.init(text: "Weekly Field ", match: false), .init(text: "Notes", match: true)])
      #expect(SearchHighlight.title("Plain", query: "zz") == [.init(text: "Plain", match: false)])
      let attributed = SearchHighlight.attributed(SearchHighlight.segments("x\u{2}y\u{3}"))
      #expect(String(attributed.characters) == "xy")
    }

    @Test func queriesBelowTheMinimumNeverSearch() async {
      let recorder = SearchRecorder()
      let sleeper = ManualSleeper()
      let model = ThreadSearchModel(
        search: recorder.search, sleep: { try await sleeper.sleep($0) })
      model.update(query: "n", sourceID: DashboardFixture.atlas, lean: false)
      model.update(query: "  n  ", sourceID: DashboardFixture.atlas, lean: false)
      #expect(model.status == .idle)
      model.update(query: "notes", sourceID: nil, lean: false)
      #expect(model.status == .idle)
      await model.settle()
      #expect(recorder.queries.isEmpty)
      #expect(await sleeper.waits.isEmpty)
      #expect(ConsoleStore.minimumSearchQuery == 2)
      #expect(!ThreadSearchModel.isSearching(" a "))
      #expect(ThreadSearchModel.isSearching(" ab "))
    }

    @Test func debounceCoalescesTypingIntoOneTrimmedRequest() async {
      let recorder = SearchRecorder()
      let sleeper = ManualSleeper()
      let model = ThreadSearchModel(
        search: recorder.search, sleep: { try await sleeper.sleep($0) })
      for prefix in ["no", "not", "note", " notes "] {
        model.update(query: prefix, sourceID: DashboardFixture.atlas, lean: false)
      }
      #expect(model.status == .loading)
      await waitUntil { await sleeper.pending() == 4 }
      await sleeper.releaseAll()
      await model.settle()
      #expect(recorder.queries == ["notes"])
      #expect(model.status == .ready)
      #expect(model.hits.count == 3)
      #expect(model.answeredQuery == "notes")
      #expect(await sleeper.waits.allSatisfy { $0 == ThreadSearchModel.debounce })
    }

    @Test func leanModeWaitsLonger() async {
      let sleeper = ManualSleeper()
      let model = ThreadSearchModel(
        search: SearchRecorder().search, sleep: { try await sleeper.sleep($0) })
      model.update(query: "notes", sourceID: DashboardFixture.atlas, lean: true)
      await waitUntil { await sleeper.pending() == 1 }
      #expect(await sleeper.waits == [ThreadSearchModel.leanDebounce])
      #expect(ThreadSearchModel.leanDebounce > ThreadSearchModel.debounce)
      await sleeper.releaseAll()
      await model.settle()
    }

    @Test func staleAnswerCannotOverwriteANewerQueryAndResultsStayWhileLoading() async {
      let recorder = SearchRecorder()
      recorder.holdFirst = true
      let model = ThreadSearchModel(search: recorder.search, sleep: { _ in })
      model.update(query: "notes", sourceID: DashboardFixture.atlas, lean: false)
      await waitUntil { recorder.gate != nil }
      model.update(query: "other", sourceID: DashboardFixture.atlas, lean: false)
      await model.settle()
      #expect(model.answeredQuery == "other")
      #expect(model.hits.isEmpty)
      recorder.gate?.resume()
      await Task.yield()
      await waitUntil { recorder.queries.count == 2 }
      for _ in 0..<50 { await Task.yield() }
      #expect(model.answeredQuery == "other", "the held first answer must be discarded")

      // A ready result stays on screen while the next query loads.
      model.update(query: "notes", sourceID: DashboardFixture.atlas, lean: false)
      await model.settle()
      #expect(model.hits.count == 3)
      let sleeper = ManualSleeper()
      let slow = ThreadSearchModel(search: recorder.search, sleep: { try await sleeper.sleep($0) })
      slow.update(query: "notes", sourceID: DashboardFixture.atlas, lean: false)
      await waitUntil { await sleeper.pending() == 1 }
      await sleeper.releaseAll()
      await slow.settle()
      slow.update(query: "notesx", sourceID: DashboardFixture.atlas, lean: false)
      #expect(slow.status == .loading && slow.hits.count == 3)
      slow.cancel()
      await sleeper.releaseAll()
    }

    @Test func failureIsReportedAndCleared() async {
      let recorder = SearchRecorder()
      recorder.failing = true
      let model = ThreadSearchModel(search: recorder.search, sleep: { _ in })
      model.update(query: "notes", sourceID: DashboardFixture.atlas, lean: false)
      await model.settle()
      #expect(model.status == .error && model.hits.isEmpty)
      model.update(query: "", sourceID: DashboardFixture.atlas, lean: false)
      #expect(model.status == .idle)
    }
  }

  @Suite("Dashboard banners")
  struct DashboardBannerTests {
    private func inputs(
      registry: ConnectionState? = .connected(
        .init(hostName: "console.example.ts.net", displayName: "Flockbox", theme: "evergreen")),
      started: Bool = true, sync: SyncState = .live, freshness: Freshness = .fresh,
      error: String? = nil, storage: [PersistenceState] = [.durable], insecure: Bool = false
    ) -> DashboardBanner.Inputs {
      .init(
        registry: registry, started: started, sync: sync, freshness: freshness,
        errorMessage: error, storage: storage, insecure: insecure)
    }

    @Test func liveFreshConsoleDrawsNothingAndSpeaksOnline() {
      #expect(DashboardBanner.banners(inputs()).isEmpty)
      #expect(
        DashboardBanner.subtitle(console: "Flockbox", inputs: inputs()) == "Flockbox · Online")
      // Startup before the stream is ready must not flash an offline banner.
      #expect(DashboardBanner.banners(inputs(sync: .offline)).isEmpty)
      #expect(
        DashboardBanner.subtitle(console: "Flockbox", inputs: inputs(sync: .offline))
          == "Flockbox · Connecting")
    }

    @Test func offlineStatesOfferTheRightAction() {
      let hydrated = DashboardBanner.banners(inputs(registry: .disconnected, started: false))
      #expect(hydrated.map(\.identifier) == ["banner-offline"])
      #expect(hydrated.first?.action == .connect)
      let failed = DashboardBanner.banners(inputs(registry: .failed(.connectivity), started: false))
      #expect(failed.first?.action == .connect && failed.first?.actionTitle == "Retry")
      let lost = DashboardBanner.banners(
        inputs(
          sync: .offline, freshness: .stale,
          error: "Console refresh failed; cached data may be stale."))
      #expect(
        lost.map(\.identifier) == ["banner-offline"], "the error folds into the offline banner")
      #expect(lost.first?.action == .reconcile)
      #expect(lost.first?.message?.contains("Console refresh failed") == true)
      #expect(DashboardBanner.banners(inputs(sync: .waiting)).first?.identifier == "banner-offline")
      #expect(
        DashboardBanner.subtitle(
          console: "Flockbox", inputs: inputs(registry: .disconnected, started: false))
          == "Flockbox · Offline")
      let catchingUp = DashboardBanner.banners(inputs(sync: .connecting, freshness: .stale))
      #expect(catchingUp.map(\.identifier) == ["banner-connecting"])
    }

    @Test func problemsStorageAndInsecureHTTPAreSeparateBanners() {
      let banners = DashboardBanner.banners(
        inputs(
          error: "Conversation list could not be refreshed.", storage: [.durable, .memoryOnly],
          insecure: true))
      #expect(banners.map(\.identifier) == ["banner-problem", "banner-storage", "banner-insecure"])
      #expect(banners[0].action == .reconcile)
      #expect(banners[1].message?.contains("memory only") == true)
      let offlineProblem = DashboardBanner.banners(
        inputs(registry: .disconnected, started: false, error: "Drafts could not be restored."))
      #expect(offlineProblem.last?.action == nil, "a stopped Store cannot reconcile")
    }
  }

  @Suite("Dashboard navigation")
  struct DashboardNavigationTests {
    let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    @Test func routesRoundTripForSceneRestoration() throws {
      let routes: [AppRoute] = [
        .conversation(profile: profile, sourceID: "agent-atlas", threadID: "t-1", archived: true),
        .newConversation(profile: profile, sourceID: "agent-atlas"),
        .project(profile: profile, sourceID: "agent-atlas", projectID: "p-1"),
        .console(profile),
      ]
      for route in routes {
        #expect(AppRoute(encoded: try #require(route.encoded)) == route)
        #expect(route.profile == profile)
      }
      #expect(AppRoute(encoded: "") == nil)
      #expect(AppRoute(encoded: "{not json") == nil)
      #expect(!AppRoute.console(profile).isDashboardDestination)
      #expect(routes[0].threadID == "t-1" && routes[1].threadID == nil)
    }

    @Test func transcriptIsVisibleOnlyOnScreenActiveAndSelected() {
      #expect(
        TranscriptVisibility.command(
          onScreen: true, sceneActive: true, selectedThreadID: "t-1", threadID: "t-1") == true)
      #expect(
        TranscriptVisibility.command(
          onScreen: false, sceneActive: true, selectedThreadID: "t-1", threadID: "t-1") == false)
      #expect(
        TranscriptVisibility.command(
          onScreen: true, sceneActive: false, selectedThreadID: "t-1", threadID: "t-1") == false)
      // Another destination owns the Store's selection: leave it alone.
      #expect(
        TranscriptVisibility.command(
          onScreen: false, sceneActive: true, selectedThreadID: "t-2", threadID: "t-1") == nil)
      #expect(
        TranscriptVisibility.command(
          onScreen: true, sceneActive: true, selectedThreadID: nil, threadID: nil) == nil)
    }

    @Test func switchingAgentsClosesOnlyAnotherAgentsDestination() {
      let open = AppRoute.conversation(
        profile: profile, sourceID: "agent-atlas", threadID: "t-1", archived: false)
      #expect(AgentSwitch.route(afterSelecting: "agent-atlas", current: open) == open)
      #expect(AgentSwitch.route(afterSelecting: "agent-quill", current: open) == nil)
      #expect(AgentSwitch.route(afterSelecting: "agent-quill", current: nil) == nil)
      #expect(
        AgentSwitch.route(afterSelecting: "agent-quill", current: .console(profile))
          == .console(profile))
    }
  }
#endif

#if DEBUG
  @MainActor @Suite("Thread search repeats")
  struct ThreadSearchRepeatTests {
    @Test func reReportingTheSameQueryKeepsTheAnswerWithoutANewRequest() async {
      var count = 0
      let model = ThreadSearchModel(
        search: { _, _ in
          count += 1
          return ThreadSearchResult()
        }, sleep: { _ in })
      model.update(query: "notes", sourceID: DashboardFixture.atlas, lean: false)
      await model.settle()
      model.update(query: " notes ", sourceID: DashboardFixture.atlas, lean: true)
      await model.settle()
      #expect(count == 1)
      #expect(model.status == .ready)
      model.update(query: "notes", sourceID: DashboardFixture.quill, lean: false)
      await model.settle()
      #expect(count == 2, "another agent is another search")
    }
  }
#endif
