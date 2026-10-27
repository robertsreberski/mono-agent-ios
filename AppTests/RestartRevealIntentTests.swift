// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgent

struct RestartRevealIntentTests {
  @Test func explicitIntentIsBoundedToTwelveSeconds() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    let active1 = intent.isActive(
      source: "sample", generation: "one", now: now.addingTimeInterval(11.9))
    #expect(active1)
    let active2 = !intent.isActive(
      source: "sample", generation: "one", now: now.addingTimeInterval(12))
    #expect(active2)
    #expect(intent.deadline == nil)
  }
  @Test func userInteractionAndSourceOrGenerationChangesEndSettling() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    intent.stop()
    let active3 = !intent.isActive(source: "sample", generation: "one", now: now)
    #expect(active3)
    intent.begin(source: "sample", generation: "one", now: now)
    let active4 = !intent.isActive(source: "other", generation: "one", now: now)
    #expect(active4)
    intent.begin(source: "sample", generation: "one", now: now)
    let active5 = !intent.isActive(source: "sample", generation: "two", now: now)
    #expect(active5)
    let active6 = !intent.isActive(source: "sample", generation: "one", now: now)
    #expect(active6)
  }
  @Test func delayedProviderCompletionCorrectsFinalHeadingAfterInitialScroll() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    // Initial explicit scroll succeeded, but provider reads are still pending.
    let initial = intent.measure(
      source: "sample", generation: "one", now: now, top: 0, viewport: 700,
      providersComplete: false)
    #expect(!initial && intent.deadline != nil)
    // The final provider response expands content after that scroll. This measurement,
    // not the previous visible heading, must drive correction and retain the intent.
    let expanded = intent.measure(
      source: "sample", generation: "one", now: now.addingTimeInterval(2), top: 900, viewport: 700,
      providersComplete: true)
    #expect(expanded && intent.deadline != nil)
    let settled = intent.measure(
      source: "sample", generation: "one", now: now.addingTimeInterval(2.1), top: 80, viewport: 700,
      providersComplete: true)
    #expect(!settled && intent.deadline == nil)
  }
  @Test func completionWithoutHeightChangeStillEndsMeasuredIntent() {
    let now = Date(timeIntervalSince1970: 100)
    var intent = RestartRevealIntent()
    intent.begin(source: "sample", generation: "one", now: now)
    _ = intent.measure(
      source: "sample", generation: "one", now: now, top: 0, viewport: 700,
      providersComplete: false)
    _ = intent.measure(
      source: "sample", generation: "one", now: now.addingTimeInterval(1), top: 0, viewport: 700,
      providersComplete: true)
    #expect(intent.deadline == nil)
  }
}
