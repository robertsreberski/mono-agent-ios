// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgent

struct DashboardIdentityTests {
  @Test func sameThreadInRunningAndRecentHasDistinctLazyIdentity() {
    let running = DashboardListID(scope: "running", value: "sample-thread")
    let recent = DashboardListID(scope: "recent", value: "sample-thread")
    #expect(running != recent)
    #expect(Set([running, recent]).count == 2)
    #expect(running == DashboardListID(scope: "running", value: "sample-thread"))
  }
}
