// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

struct DashboardIdentityTests {
  @Test func actualLazyRowProjectionScopesSameThreadAcrossRunningAndRecent() throws {
    let threads = try DashboardFixture.allThreads()
    let running = DashboardListProjection.rows(threads, id: \.id, scope: "running")
    let recent = DashboardListProjection.rows(threads, id: \.id, scope: "recent")
    #expect(!running.isEmpty)
    #expect(running.map { $0.value.id } == threads.map(\.id))
    #expect(Set((running + recent).map(\.id)).count == threads.count * 2)
    let reordered = DashboardListProjection.rows(
      Array(threads.reversed()), id: \.id, scope: "recent")
    #expect(reordered.map(\.id) == recent.reversed().map(\.id))
  }
  @Test func wakeSummaryParticipatesInEquatableRowValue() throws {
    let thread = try #require(try DashboardFixture.allThreads().first)
    let content = DashboardRows.recent(
      thread, unread: false, confirmed: false, projects: [], tags: [], now: DashboardFixture.now)
    let active = DashboardRowValue(
      target: .conversation(
        profile: UUID(), sourceID: thread.sourceId, threadID: thread.id, archived: false),
      identifier: "recent-sample", content: content, selected: false, wakeStatus: "Weekly · active")
    var paused = active
    paused.wakeStatus = "Weekly · paused"
    #expect(active != paused)
  }

}
