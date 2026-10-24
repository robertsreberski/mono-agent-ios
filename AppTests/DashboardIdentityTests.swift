// SPDX-License-Identifier: GPL-3.0-only
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
}
