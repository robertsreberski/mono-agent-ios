// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI
import Testing

@Suite("Dashboard components")
struct DashboardComponentTests {
  @Test func labelColoursMapExactWireValuesOnly() {
    #expect(LabelColor(serverValue: "teal") == .teal)
    #expect(LabelColor(serverValue: "default") == .standard)
    #expect(LabelColor(serverValue: "Teal") == .standard)
    #expect(LabelColor(serverValue: nil) == .standard)
    #expect(LabelColor.allCases.count == 8)
  }

  @Test(arguments: ConsoleTheme.allCases)
  func chipInkPassesAAOnItsTint(_ theme: ConsoleTheme) {
    for color in LabelColor.allCases {
      for scheme in [ColorScheme.light, .dark] {
        let ratio = color.ink(in: theme).resolved(scheme)
          .contrastRatio(with: color.tint(in: theme).resolved(scheme))
        #expect(ratio >= 4.5, "\(color) \(scheme) ink on tint is \(ratio)")
      }
    }
  }

  @Test func agentBadgePrefersRunningAndSpeaksBothCounts() {
    #expect(AgentTile.badge(running: 2, unread: 5) == .running(2))
    #expect(AgentTile.badge(running: 0, unread: 5) == .unread(5))
    #expect(AgentTile.badge(running: 0, unread: 0) == nil)
    #expect(
      AgentTile.accessibilityLabel(
        name: "Atlas Research", presence: .online, pinned: true, running: 2, unread: 5)
        == "Atlas Research, online, pinned, 2 running, 5 unread")
    #expect(
      AgentTile.accessibilityLabel(
        name: "Dormant", presence: .offline, pinned: false, running: 0, unread: 0)
        == "Dormant, offline")
  }

  @Test func unknownAgentStatusIsNotReportedOnline() {
    #expect(AgentTile.Presence(serverValue: "online") == .online)
    #expect(AgentTile.Presence(serverValue: "degraded") == .degraded)
    #expect(AgentTile.Presence(serverValue: "rebooting") == .degraded)
  }

  @Test func activityStatesHaveDistinctShapesAndWords() {
    #expect(ActivityState.running.systemImage != ActivityState.lastKnown.systemImage)
    #expect(ActivityState.lastKnown.label.contains("not confirmed"))
  }

  @Test func rowSpeaksStatusInWordsAndInReadingOrder() {
    let row = ConversationRowContent(
      leading: .symbol("exclamationmark.triangle.fill", label: "Needs attention", tone: .danger),
      title: "Nightly import", time: "5m", timeAccessibility: "5 minutes ago", unread: true,
      activity: .lastKnown, preview: "Failed", project: .init("Field notes"),
      tags: [.init("Research"), .init("Urgent")], detail: "2 matches")
    #expect(
      row.accessibilityLabel
        == "Nightly import, in project Field notes, Needs attention, unread, "
        + "Last known running, not confirmed, Failed, tags Research, Urgent, 2 matches, "
        + "5 minutes ago")
    let plain = ConversationRowContent(
      leading: .symbol("bubble.left", label: "Conversation", tone: .neutral), title: "Hello",
      time: "now")
    #expect(plain.accessibilityLabel == "Hello, now")
  }
}

@Suite("Composer components")
struct ComposerComponentTests {
  @Test func attachmentChipsSpeakTheirStateNotOnlyColour() {
    #expect(
      AttachmentChip.accessibilityLabel(name: "notes.txt", detail: "1 KB", phase: .ready)
        == "notes.txt, 1 KB, attached")
    #expect(
      AttachmentChip.accessibilityLabel(name: "photo.png", detail: "", phase: .uploading(0.426))
        == "photo.png, uploading, 43 percent")
    #expect(
      AttachmentChip.accessibilityLabel(name: "photo.png", detail: "", phase: .uploading(7))
        == "photo.png, uploading, 100 percent")
    #expect(
      AttachmentChip.accessibilityLabel(name: "big.pdf", detail: "", phase: .failed)
        == "big.pdf, upload failed")
  }
}
