// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

#if DEBUG
  private func fixtureThread(_ id: String) throws -> WebThread {
    try #require(try DashboardFixture.allThreads().first { $0.id == id })
  }

  private func decoded<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  @Suite("Dashboard model")
  struct DashboardModelTests {
    @Test func initialsAndShortLabelsAreNeverEmpty() {
      #expect(DashboardModel.initials("Atlas Research") == "AR")
      #expect(DashboardModel.initials("quill") == "QU")
      #expect(DashboardModel.initials("harbor_ops-team") == "HO")
      #expect(DashboardModel.initials(" - ") == "A")
      #expect(DashboardModel.shortLabel("Atlas Research") == "Atlas")
      #expect(DashboardModel.shortLabel("") == "")
    }

    @Test func agentsSortPinnedFirstThenAsciiFoldedLabel() throws {
      let sorted = DashboardModel.sortPinnedFirst(try DashboardFixture.agents())
      #expect(
        sorted.map(\.sourceId) == ["agent-atlas", "agent-dormant", "agent-harbor", "agent-quill"])
    }

    @Test func offlineUnpinnedUnselectedAgentsFoldAway() throws {
      let agents = DashboardModel.sortPinnedFirst(try DashboardFixture.agents())
      let folded = DashboardModel.visibleAgents(agents, selected: "agent-atlas", showOffline: false)
      #expect(folded.hiddenOffline == 1)
      #expect(!folded.visible.contains { $0.sourceId == "agent-dormant" })
      let selected = DashboardModel.visibleAgents(
        agents, selected: "agent-dormant", showOffline: false)
      #expect(selected.hiddenOffline == 0)
      let shown = DashboardModel.visibleAgents(agents, selected: "agent-atlas", showOffline: true)
      #expect(shown.visible.count == 4 && shown.hiddenOffline == 1)
    }

    @Test func presentationFollowsTheWebPrecedence() throws {
      var thread = try fixtureThread("t-atlas-reading")
      #expect(DashboardModel.presentation(thread) == ("", false))
      #expect(DashboardModel.excerpt(thread) == "Added two sample essays on map making.")
      thread.lastMessagePreview = "  Two\n  lines  "
      #expect(DashboardModel.excerpt(thread) == "Two lines")

      let failed = try fixtureThread("t-atlas-import")
      #expect(DashboardModel.presentation(failed) == ("Failed", false))
      #expect(DashboardModel.kind(failed) == .alert)
      #expect(DashboardModel.excerpt(failed) == nil)

      let running = try fixtureThread("t-atlas-survey")
      #expect(DashboardModel.presentation(running) == ("Working…", true))
      #expect(DashboardModel.outcomeError(running) == nil)

      var jobs = try fixtureThread("t-atlas-reading")
      jobs.jobActivity = try decoded(#"{"queued":2,"starting":0,"running":1}"#)
      #expect(
        DashboardModel.presentation(jobs)
          == ("1 background job running · 2 background jobs queued", true))

      var fresh = try fixtureThread("t-atlas-reading")
      fresh.runState = try decoded(#"{"status":"idle"}"#)
      fresh.messageCount = 0
      #expect(DashboardModel.presentation(fresh).text == "New conversation")
      fresh.messageCount = 2
      #expect(DashboardModel.presentation(fresh).text == "No reply yet")
    }

    @Test func laterBackgroundJobFailureWinsOverEarlierSuccess() throws {
      var thread = try fixtureThread("t-atlas-reading")
      thread.jobActivity = try decoded(
        #"{"queued":0,"starting":0,"running":0,"latestTerminal":{"state":"timed_out","completedAt":"2030-01-02T12:00:00Z"}}"#
      )
      #expect(DashboardModel.outcomeError(thread) == "Background job timed out")
      #expect(DashboardModel.kind(thread) == .alert)
    }

    @Test func kindsAndRecentFilter() throws {
      #expect(DashboardModel.kind(try fixtureThread("t-atlas-digest")) == .cron)
      #expect(!DashboardModel.isRecent(try fixtureThread("t-atlas-digest")))
      #expect(DashboardModel.isRecent(try fixtureThread("t-atlas-notes")))
      var hook = try fixtureThread("t-atlas-reading")
      hook.trigger = try decoded(#"{"kind":"webhook"}"#)
      #expect(DashboardModel.kind(hook) == .webhook)
    }

    @Test func projectLabelPrefersLoadedProjectThenRowName() throws {
      let projects = try DashboardFixture.projects()
      let label = DashboardModel.projectLabel(
        try fixtureThread("t-atlas-notes"), projects: projects)
      #expect(label?.name == "Field notes" && label?.color == "blue")
      let other = DashboardModel.projectLabel(
        try fixtureThread("t-harbor-deploy"), projects: projects)
      #expect(other?.name == "Infrastructure" && other?.color == "default")
      #expect(
        DashboardModel.projectLabel(try fixtureThread("t-atlas-reading"), projects: projects) == nil
      )
    }

    @Test func runningGroupsFollowAgentOrderAndDropUnknownAgents() throws {
      let agents = DashboardModel.sortPinnedFirst(try DashboardFixture.agents())
      var stray = try fixtureThread("t-atlas-survey")
      stray.id = "t-stray"
      stray.sourceId = "agent-gone"
      let groups = DashboardModel.groupRunning(
        try DashboardFixture.fleet().threads + [stray], agents: agents)
      #expect(groups.map(\.agent.sourceId) == ["agent-atlas", "agent-harbor"])
      #expect(
        groups[0].threads.map(\.id) == ["t-atlas-launch", "t-atlas-survey", "t-atlas-brochure"])
      #expect(DashboardModel.runningCount(groups) == 4)
    }

    @Test func runningMergeOverlaysCachedOnActiveListedRows() throws {
      var cached = try fixtureThread("t-atlas-survey")
      cached.title = "Cached copy"
      let idle = try fixtureThread("t-atlas-reading")
      let merged = DashboardModel.mergeRunning(
        cached: [cached], listed: [try fixtureThread("t-atlas-survey"), idle])
      #expect(merged.map(\.id) == ["t-atlas-survey"])
      #expect(merged.first?.title == "Cached copy")
    }

    @Test func authoritativeFleetUsesServerCountsAndFallbackCountsWhatIsDrawn() throws {
      let agents = DashboardModel.sortPinnedFirst(try DashboardFixture.agents())
      var fleet = try DashboardFixture.fleet()
      fleet.total = 9
      fleet.truncated = true
      let live = DashboardModel.running(
        fleet: fleet, authoritative: true, cached: [], listed: [], agents: agents)
      #expect(live.authoritative && live.total == 9 && live.truncated)
      #expect(live.counts["agent-atlas"] == 3)

      var cachedRunning = try fixtureThread("t-quill-blog")
      cachedRunning.runState = try decoded(#"{"status":"running"}"#)
      let fallback = DashboardModel.running(
        fleet: fleet, authoritative: false, cached: [cachedRunning],
        listed: try DashboardFixture.threads(source: DashboardFixture.atlas), agents: agents)
      #expect(!fallback.authoritative && !fallback.truncated)
      #expect(fallback.total == 5)
      #expect(fallback.counts == ["agent-atlas": 3, "agent-harbor": 1, "agent-quill": 1])
    }

    @Test func absentRunningCountIsUnknownNotZero() throws {
      var agent = try DashboardFixture.agents()[0]
      agent.runningCount = 2
      #expect(DashboardModel.runningCount(for: agent, counts: [:]) == 2)
      #expect(DashboardModel.runningCount(for: agent, counts: [agent.sourceId: 0]) == 0)
    }

    @Test func runningCardStatusReportsOnlyWhatTheTurnSaid() throws {
      #expect(
        DashboardModel.runningStatus(try fixtureThread("t-atlas-launch"))
          == "Working · 4 tool calls · $0.42")
      #expect(
        DashboardModel.runningStatus(try fixtureThread("t-atlas-brochure"))
          == "Asking you a question")
      #expect(
        DashboardModel.runningStatus(try fixtureThread("t-harbor-deploy"))
          == "Working · 1 tool call · cost unknown")
      #expect(DashboardModel.runningStatus(try fixtureThread("t-atlas-survey")) == "Working…")
      #expect(DashboardModel.runningPending(try fixtureThread("t-atlas-survey")))
      #expect(!DashboardModel.runningPending(try fixtureThread("t-atlas-launch")))
    }

    @Test func unreadCountsDeduplicateAndGroupBySource() throws {
      let threads =
        try DashboardFixture.threads(source: DashboardFixture.atlas)
        + DashboardFixture.threads(source: DashboardFixture.quill)
        + DashboardFixture.fleet().threads
      let counts = DashboardModel.unreadCounts(threads) {
        DashboardFixture.unreadThreadIDs.contains($0.id) || $0.id == "t-atlas-launch"
      }
      #expect(counts == ["agent-atlas": 2, "agent-quill": 1])
    }

    @Test func relativeTimeMatchesTheWebPrecision() {
      let now = DashboardFixture.now
      let utc = TimeZone(identifier: "UTC")!
      let locale = Locale(identifier: "en_US")
      func at(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-seconds))
      }
      #expect(DashboardModel.relativeTime(at(30), now: now) == "now")
      #expect(DashboardModel.relativeTime(at(-600), now: now) == "now")
      #expect(DashboardModel.relativeTime(at(5 * 60), now: now) == "5m")
      #expect(DashboardModel.relativeTime(at(3 * 3600), now: now) == "3h")
      #expect(DashboardModel.relativeTime(at(6 * 86400), now: now) == "6d")
      #expect(
        DashboardModel.relativeTime(at(12 * 86400), now: now, locale: locale, timeZone: utc)
          == "Dec 21")
      #expect(DashboardModel.relativeTime("not a date", now: now) == "")
      #expect(DashboardModel.spokenTime(at(60), now: now) == "1 minute ago")
      #expect(DashboardModel.spokenTime(at(2 * 86400), now: now) == "2 days ago")
      #expect(
        DashboardModel.spokenTime(at(12 * 86400), now: now, locale: locale, timeZone: utc)
          == "December 21")
      #expect(
        DashboardModel.relativeTime("2030-01-02T11:58:00.000Z", now: now) == "2m",
        "fractional seconds parse")
    }

    @Test func dataModeLabelShowsWhatAutoResolvesTo() {
      #expect(DashboardModel.dataModeLabel(.auto, effective: .full) == "Auto · Full")
      #expect(DashboardModel.dataModeLabel(.auto, effective: .lean) == "Auto · Lean")
      #expect(DashboardModel.dataModeLabel(.lean, effective: .lean) == "Lean")
      #expect(DashboardModel.dataModeLabel(.full, effective: .full) == "Full")
      #expect(DashboardModel.nextDataMode(.auto) == .lean)
      #expect(DashboardModel.nextDataMode(.lean) == .full)
      #expect(DashboardModel.nextDataMode(.full) == .auto)
    }
  }

  @Suite("Dashboard rows")
  struct DashboardRowsTests {
    let now = DashboardFixture.now

    @Test func recentRowCarriesUnreadRunningProjectAndTags() throws {
      let tags = try DashboardFixture.tags()
      let projects = try DashboardFixture.projects()
      let notes = DashboardRows.recent(
        try fixtureThread("t-atlas-notes"), unread: true, confirmed: true, projects: projects,
        tags: tags, now: now)
      #expect(notes.unread && notes.activity == nil)
      #expect(notes.project?.name == "Field notes")
      #expect(notes.tags.map(\.name) == ["Research", "Draft"])
      #expect(notes.accessibilityLabel.contains("unread"))
      #expect(notes.accessibilityLabel.contains("40 minutes ago"))

      let survey = DashboardRows.recent(
        try fixtureThread("t-atlas-survey"), unread: false, confirmed: false, projects: projects,
        tags: tags, now: now)
      #expect(survey.activity == .lastKnown)
      #expect(survey.previewPending)
      #expect(survey.accessibilityLabel.contains("not confirmed"))
      let confirmed = DashboardRows.recent(
        try fixtureThread("t-atlas-survey"), unread: false, confirmed: true, projects: projects,
        tags: tags, now: now)
      #expect(confirmed.activity == .running)

      let garden = DashboardRows.recent(
        try fixtureThread("t-atlas-garden"), unread: false, confirmed: true, projects: projects,
        tags: tags, now: now)
      #expect(garden.scheduled && garden.tags.count == 4)
      let alert = DashboardRows.recent(
        try fixtureThread("t-atlas-import"), unread: false, confirmed: true, projects: [],
        tags: [], now: now)
      #expect(alert.accessibilityLabel.contains("Needs attention, webhook conversation"))
    }

    @Test func runningRowNamesItsOwnAgent() throws {
      let agent = try #require(
        try DashboardFixture.agents().first { $0.sourceId == "agent-harbor" })
      let row = DashboardRows.running(
        try fixtureThread("t-harbor-deploy"), agent: agent, confirmed: true, projects: [],
        now: now)
      #expect(row.leading == .monogram("HO", label: "Harbor Ops"))
      #expect(row.accessibilityLabel.hasPrefix("Deploy the demo service, on Harbor Ops"))
      #expect(row.time == "1m")
    }

    @Test func searchRowHighlightsAndPrefersFresherHeldSummary() throws {
      let page: WebThreadSearchPage = try JSONDecoder().decode(
        WebThreadSearchPage.self,
        from: JSONEncoder().encode(
          try DashboardFixture.searchPage(query: "notes", source: DashboardFixture.atlas)))
      #expect(page.hits.count == 3)
      var held = try fixtureThread("t-atlas-notes")
      held.revision = 99
      held.title = "Weekly field notes (renamed)"
      let row = DashboardRows.search(
        page.hits[0], current: held, query: "notes", projects: [], now: now)
      #expect(
        row.preview.map { String($0.characters) } == "…the weekly field notes are ready for review…"
      )
      #expect(row.detail == "3 matches")
      let titleOnly = DashboardRows.search(
        page.hits[2], current: nil, query: "notes", projects: [], now: now)
      #expect(titleOnly.preview.map { String($0.characters) } == "Matched the title")
      #expect(titleOnly.detail == nil)
    }

    @Test func projectRowSaysChatsAndRunning() throws {
      let project = try #require(try DashboardFixture.projects().first)
      let row = DashboardRows.project(project, now: now)
      #expect(row.preview.map { String($0.characters) } == "4 chats · updated 6m")
      #expect(row.detail == "1 running")
    }
  }
#endif
