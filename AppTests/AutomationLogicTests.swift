// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

struct AutomationLogicTests {
  @Test func jobRouteRetainsProfileSourceAndJobAcrossRestoration() throws {
    let profile = UUID()
    let route = AppRoute.automation(profile: profile, sourceID: "sample-agent", jobID: "sample-job")
    #expect(route.profile == profile && route.sourceID == "sample-agent" && route.threadID == nil)
    #expect(AppRoute(encoded: try #require(route.encoded)) == route)
    #expect(AgentSwitch.route(afterSelecting: "other-agent", current: route) == nil)
    #expect(AgentSwitch.route(afterSelecting: "sample-agent", current: route) == route)
  }
  #if DEBUG
    @Test func syntheticLaunchDestinationsParseWithoutBecomingRealProfileRoutes() throws {
      let config = try LaunchConfiguration(arguments: [
        "--scenario", "automations", "--open-automations", "UTC", "--open-cron-job", "sample-job",
      ])
      #expect(config.storeScenario == .automations)
      #expect(config.automationsQuery == "UTC" && config.cronJob == "sample-job")
      #expect(throws: (any Error).self) { try LaunchConfiguration(arguments: ["--open-cron-job"]) }
    }
  #endif
}
