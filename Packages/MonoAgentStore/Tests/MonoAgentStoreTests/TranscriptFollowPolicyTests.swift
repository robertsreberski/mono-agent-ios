// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgentStore

struct TranscriptFollowPolicyTests {
  @Test func shortContentIsAtBottomEvenWhenInsetsAndOffsetDisagree() {
    var policy = TranscriptFollowPolicy()
    policy.update(
      .init(contentHeight: 2500, viewportHeight: 1000, contentOffset: 500), userDriven: true)
    #expect(policy.shouldShowJump)
    let short = TranscriptScrollMetrics(
      contentHeight: 600, viewportHeight: 1000, contentOffset: -100, topInset: 100, bottomInset: 40)
    #expect(short.contentFits && short.isAtBottom)
    policy.update(short, userDriven: false)
    #expect(policy.atBottom && policy.following)
    #expect(!policy.shouldShowJump)
  }
  @Test func shortContentNeverScrollsPastTheReadingEdgeDuringInitialLayout() {
    let policy = TranscriptFollowPolicy()
    // Native safe-area bars can report a transient negative offset while sizing the dock.
    let initial = TranscriptScrollMetrics(
      contentHeight: 600, viewportHeight: 1000, contentOffset: -500,
      topInset: 100, bottomInset: 40)
    #expect(initial.contentFits)
    #expect(initial.distanceFromBottom > 1)
    #expect(!policy.shouldScrollAfterWrite(initial))
    let overflow = TranscriptScrollMetrics(
      contentHeight: 950, viewportHeight: 1000, contentOffset: 0,
      topInset: 0, bottomInset: 150)
    #expect(!overflow.contentFits)
    #expect(policy.shouldScrollAfterWrite(overflow))
  }
  @Test func restoreFollowingContentOnlyWhenPastItsReadingEdgeAndNotPaging() {
    var policy = TranscriptFollowPolicy()
    let overpulled = TranscriptScrollMetrics(
      contentHeight: 600, viewportHeight: 1000, contentOffset: -500,
      topInset: 100, bottomInset: 40)
    #expect(policy.shouldRestoreReadingEdge(overpulled))
    var aligned = overpulled
    aligned.contentOffset = -100
    #expect(!policy.shouldRestoreReadingEdge(aligned))
    var overflowing = overpulled
    overflowing.contentHeight = 2000
    #expect(policy.shouldRestoreReadingEdge(overflowing))
    policy.beginPaging()
    #expect(!policy.shouldRestoreReadingEdge(overpulled))
  }
  @Test func expandingAndCollapsingAtBottomNeverPretendsToBeAUserScroll() {
    var policy = TranscriptFollowPolicy()
    policy.update(
      .init(contentHeight: 600, viewportHeight: 1000, contentOffset: 0), userDriven: false)
    // Expanded output grows beyond the viewport, before the native bottom-follow scroll settles.
    policy.update(
      .init(contentHeight: 1600, viewportHeight: 1000, contentOffset: 0), userDriven: false)
    #expect(policy.following && policy.shouldFollowWrite)
    #expect(!policy.shouldShowJump)
    policy.update(
      .init(contentHeight: 1600, viewportHeight: 1000, contentOffset: 600), userDriven: false)
    #expect(policy.atBottom)
    policy.update(
      .init(contentHeight: 600, viewportHeight: 1000, contentOffset: 0), userDriven: false)
    #expect(policy.following && policy.atBottom && !policy.shouldShowJump)
  }
  @Test func smallWritesFollowAllTheWayToBottomNotJustWithinTheProximityThreshold() {
    var policy = TranscriptFollowPolicy()
    let growth = TranscriptScrollMetrics(
      contentHeight: 2020, viewportHeight: 1000, contentOffset: 1000)
    policy.update(growth, userDriven: false)
    #expect(growth.isAtBottom && policy.shouldScrollAfterWrite(growth))
    #expect(!policy.shouldShowJump)
    let settled = TranscriptScrollMetrics(
      contentHeight: 2020, viewportHeight: 1000, contentOffset: 1020)
    #expect(!policy.shouldScrollAfterWrite(settled))
  }
  @Test func onlyUserScrollingAwayShowsJumpAndPagingNeverFollows() {
    var policy = TranscriptFollowPolicy()
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 1000), userDriven: true)
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 300), userDriven: true)
    #expect(policy.shouldShowJump && !policy.shouldFollowWrite)
    policy.update(
      .init(contentHeight: 2100, viewportHeight: 1000, contentOffset: 300), userDriven: false)
    #expect(policy.shouldShowJump)
    policy.beginPaging()
    #expect(!policy.shouldFollowWrite && !policy.shouldShowJump)
    policy.paging = false
    policy.jump()
    #expect(policy.shouldFollowWrite)
  }
}
