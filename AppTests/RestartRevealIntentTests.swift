// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

struct RestartRevealIntentTests {
  @Test func explicitIntentIsBoundedToTwelveSeconds() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    #expect(intent.isActive(source: "sample", generation: "one", now: now.addingTimeInterval(11.9)))
    #expect(!intent.isActive(source: "sample", generation: "one", now: now.addingTimeInterval(12)))
    #expect(intent.deadline == nil)
  }
  @Test func userInteractionAndSourceOrGenerationChangesEndSettling() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    intent.stop()
    #expect(!intent.isActive(source: "sample", generation: "one", now: now))
    intent.begin(source: "sample", generation: "one", now: now)
    #expect(!intent.isActive(source: "other", generation: "one", now: now))
    intent.begin(source: "sample", generation: "one", now: now)
    #expect(!intent.isActive(source: "sample", generation: "two", now: now))
    #expect(!intent.isActive(source: "sample", generation: "one", now: now))
  }
}
