// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

#if DEBUG
  struct JobFixtureTests {
    @MainActor @Test func disclosurePreferencesAreThreadScopedAndSurviveRowMoves() {
      let state = JobDisclosureState()
      state.binding("thread-a:card:sample").wrappedValue = true
      state.binding("thread-a:output:sample").wrappedValue = true
      #expect(state.contains("thread-a:card:sample"))
      #expect(state.contains("thread-a:output:sample"))
      #expect(!state.contains("thread-b:card:sample"))
      state.binding("thread-a:card:sample").wrappedValue = false
      #expect(state.contains("thread-a:output:sample"))
    }
    @Test func allJobStatesAndDelegationStatesDecodeWithoutFallbacks() throws {
      let jobs = try JobFixture.jobs(.conversationJobs)
      #expect(
        Set(jobs.map(\.state))
          == JobPresentation.terminalStates.union(["queued", "starting", "running"]))
      for scenario in [
        StoreScenario.conversationJobs, .conversationJobStack, .conversationSubagents,
        .conversationContext,
      ] {
        let messages = try JobFixture.messages(scenario)
        let decoded = try JSONDecoder().decode(
          [WebMessage].self, from: JSONEncoder().encode(messages))
        #expect(decoded == messages)
        #expect(
          !decoded.flatMap(\.parts).contains {
            if case .unknown = $0 { return true }
            return false
          })
      }
      let delegates = try JobFixture.messages(.conversationSubagents).flatMap(\.parts).compactMap {
        if case .subagent(let call) = $0 { return call.status }
        return nil
      }
      #expect(Set(delegates) == ["running", "complete", "failed"])
    }
    @Test func dashboardRecentRunningAndHeaderShareTheQuestionState() throws {
      let thread = try #require(
        try DashboardFixture.allThreads().first { $0.title == "Translate the sample brochure" })
      let agent = try #require(
        try DashboardFixture.agents().first { $0.sourceId == thread.sourceId })
      let recent = DashboardRows.recent(
        thread, unread: false, confirmed: true, projects: [], tags: [], now: DashboardFixture.now)
      let running = DashboardRows.running(
        thread, agent: agent, confirmed: true, projects: [], now: DashboardFixture.now)
      #expect(recent.preview == running.preview)
      #expect(DashboardModel.runningStatus(thread).contains("Asking you a question"))
      #expect(
        ConversationHeaderModel.status(thread, confirmed: true).label == "Asking you a question")
    }
    @Test func activitySummariesStayConsistentAcrossSyntheticSurfaces() throws {
      for scenario in [
        StoreScenario.conversationJobs, .conversationJobStack, .conversationSubagents,
        .conversationContext,
      ] {
        let thread = try TranscriptFixture.thread(scenario)
        let bootstrap = try TranscriptFixture.bootstrap(scenario, theme: "plum")
        #expect(bootstrap.threads.first { $0.id == thread.id } == thread)
        #expect(try TranscriptFixture.cached(scenario).thread == thread)
        #expect(
          try TranscriptFixture.fleet(scenario).threads.contains { $0.id == thread.id }
            == DashboardModel.presentation(thread).active)
      }
    }
  }
#endif
