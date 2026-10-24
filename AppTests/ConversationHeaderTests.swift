// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgent

struct ConversationHeaderTests {
  @Test func latestKnownRouteDoesNotDisappearWhenSettingsAreAbsent() throws {
    var thread = try TranscriptFixture.thread(.conversationTranscript)
    thread.runModel = nil
    thread.runEffort = nil
    var route = ConversationHeaderModel.route(thread, agent: nil, latest: nil)
    #expect(route.model == "sample:large" && route.effort == "high")
    thread.runState.model = nil
    thread.runState.effort = nil
    let attribution: WebRunAttribution = try TranscriptFixture.decode(
      #"{"requested":{},"executed":{"model":"sample:executed","effort":"high","effectiveEffort":"medium"},"disposition":"requested","transitions":[],"retries":[]}"#
    )
    #expect(ConversationHeaderModel.hasReportedModel(attribution))
    let requestedOnly: WebRunAttribution = try TranscriptFixture.decode(
      #"{"requested":{"model":"sample:requested"},"disposition":"requested","transitions":[],"retries":[]}"#
    )
    #expect(!ConversationHeaderModel.hasReportedModel(requestedOnly))
    route = ConversationHeaderModel.route(thread, agent: nil, latest: attribution)
    #expect(route.model == "sample:executed" && route.effort == "medium")
    thread.runState.attribution = attribution
    #expect(
      ConversationHeaderModel.route(thread, agent: nil, latest: nil).model == "sample:executed")
    thread.runState.attribution = nil
    #expect(
      ConversationHeaderModel.route(thread, agent: nil, latest: nil).label == "Model not reported")
  }
  @Test func headerAndDashboardUseTheSameRunAndConfirmationEvidence() throws {
    var thread = try TranscriptFixture.thread(.conversationStreaming)
    #expect(DashboardModel.presentation(thread).active)
    #expect(ConversationHeaderModel.status(thread, confirmed: true).label == "Running")
    #expect(ConversationHeaderModel.status(thread, confirmed: false).label == "Last known running")
    thread.runState.status = "complete"
    #expect(!DashboardModel.presentation(thread).active)
    #expect(ConversationHeaderModel.status(thread, confirmed: true).label == "Idle")
  }
  // Organize scenarios use ScreenFixture + their stateful transport, not TranscriptFixture.
  // StoreCompositionTests exercises their real construction, including wake and label reads.
  @Test(
    arguments: StoreScenario.allCases.filter { $0.isTranscript && !$0.isComposer && !$0.isOrganize }
  )
  func syntheticCacheBootstrapAndFleetAgree(_ scenario: StoreScenario) throws {
    let cache = try TranscriptFixture.cached(scenario)
    let bootstrap = try TranscriptFixture.bootstrap(scenario, theme: "evergreen")
    let summary = try #require(bootstrap.threads.first { $0.id == cache.thread.id })
    #expect(summary == cache.thread)
    let fleet = try #require(bootstrap.activeThreads)
    let active = fleet.threads.contains { $0.id == cache.thread.id }
    #expect(active == DashboardModel.presentation(cache.thread).active)
    #expect(
      ConversationHeaderModel.route(
        cache.thread, agent: nil, latest: cache.messages.last?.attribution
      ).model == "sample:large")
    #expect(fleet.runningCounts[DashboardFixture.atlas] == (active ? 3 : 2))
  }
  @Test func settledFleetRowsCannotRemainInTheRunningSection() throws {
    var fleet = try DashboardFixture.fleet()
    let settled = try TranscriptFixture.thread(.conversationTranscript)
    let original = try #require(fleet.threads.first { $0.id == settled.id })
    fleet.threads = fleet.threads.map { $0.id == settled.id ? settled : $0 }
    let agents = try DashboardFixture.agents()
    let projection = DashboardModel.running(
      fleet: fleet, authoritative: true, cached: [settled], listed: [], agents: agents)
    #expect(!projection.groups.flatMap(\.threads).contains { $0.id == settled.id })
    #expect(projection.counts[settled.sourceId] == 2)
    let fallback = DashboardModel.running(
      fleet: nil, authoritative: false, cached: [settled], listed: [original], agents: agents)
    #expect(fallback.groups.isEmpty)
  }
}
