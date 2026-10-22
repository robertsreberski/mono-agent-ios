// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

@Suite("Token invariants")
struct TokenTests {
  @Test func spacingIsPositiveAscendingAndOnTheGrid() {
    let scale = DesignSpacing.scale
    #expect(scale.allSatisfy { $0 > 0 })
    #expect(scale == scale.sorted() && Set(scale).count == scale.count)
    // Everything above the hairline step sits on a 4-point grid.
    #expect(scale.dropFirst().allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
  }

  @Test func radiiAscendAndMirrorTheWebSteps() {
    let scale = DesignRadius.scale
    #expect(scale == scale.sorted() && Set(scale).count == scale.count)
    #expect([DesignRadius.sm, DesignRadius.md, DesignRadius.lg] == [8, 12, 18])
  }

  @Test func metricsRespectPlatformMinimums() {
    #expect(DesignMetrics.minimumHitTarget >= 44)
    #expect(DesignMetrics.readableWidth >= 320)
    #expect(DesignMetrics.unreadDot >= 8)
  }

  @Test func typographyUsesDistinctDynamicTypeRoles() {
    #expect(DesignTextStyle.allCases.count == 8)
    #expect(DesignTextStyle.body.textStyle == .body)
    #expect(DesignTextStyle.caption.textStyle == .footnote)
  }

  @Test func statusKindsHaveNonColourCues() {
    let kinds = StatusKind.allCases
    #expect(Set(kinds.map(\.systemImage)).count == kinds.count, "symbols must be distinct")
    #expect(Set(kinds.map(\.defaultLabel)).count == kinds.count, "labels must be distinct")
    #expect(kinds.allSatisfy { !$0.defaultLabel.isEmpty && !$0.systemImage.isEmpty })
    #expect(StatusKind.failed.tone == .danger && StatusKind.online.tone == .success)
    let banners = ConnectionBanner.Kind.allCases
    #expect(Set(banners.map(\.systemImage)).count == banners.count)
  }

  @Test func unreadBadgeTextAndAccessibility() {
    #expect(UnreadMarker.badgeText(for: nil) == nil)
    #expect(UnreadMarker.badgeText(for: 1) == nil)
    #expect(UnreadMarker.badgeText(for: 2) == "2")
    #expect(UnreadMarker.badgeText(for: 99) == "99")
    #expect(UnreadMarker.badgeText(for: 100) == "99+")
    #expect(UnreadMarker.accessibilityText(for: nil) == "Unread")
    #expect(UnreadMarker.accessibilityText(for: 1) == "1 unread")
    #expect(UnreadMarker.accessibilityText(for: 250) == "250 unread")
  }

  @Test func markdownSlotIsLabelledAsAPlaceholder() {
    #expect(RichMarkdownPlaceholder.label.localizedStandardContains("placeholder"))
  }
}
