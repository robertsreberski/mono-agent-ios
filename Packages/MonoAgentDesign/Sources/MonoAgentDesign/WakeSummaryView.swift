// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Value-only wake facts; the caller owns timezone and schedule decisions.
public struct WakeSummaryView: View {
  @Environment(\.webMaterial) private var material
  let state: String
  let sentence: String
  let next: String?
  let note: String?
  let outcome: String?
  public init(
    state: String, sentence: String, next: String? = nil, note: String? = nil,
    outcome: String? = nil
  ) {
    self.state = state
    self.sentence = sentence
    self.next = next
    self.note = note
    self.outcome = outcome
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(state, systemImage: state == "Active" ? "clock" : "clock.badge.questionmark")
        .webFont(.sheetTitle).foregroundStyle(WebColor.text.color)
      Text(sentence).webFont(.system).foregroundStyle(WebColor.text.color)
      if let next { Text(next).webFont(.sheetSubtitle).foregroundStyle(WebColor.textSoft.color) }
      if let note { Text(note).webFont(.sheetSubtitle).foregroundStyle(material.textMuted.color) }
      if let outcome {
        Label(outcome, systemImage: "info.circle").webFont(.sheetSubtitle).foregroundStyle(
          WebColor.textSoft.color)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
  }
}
public struct WakeScheduleStatus: View {
  @Environment(\.webMaterial) private var material
  let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    Label(text, systemImage: "clock").webFont(.sheetSubtitle)
      .foregroundStyle(material.textMuted.color).accessibilityLabel(
        "Wake-up schedule status: \(text)")
  }
}
#if DEBUG
  #Preview("Wake summary") {
    DesignPreviewMatrix {
      VStack(alignment: .leading, spacing: 20) {
        WakeSummaryView(
          state: "Active", sentence: "Every weekday at 09:00",
          next: "Next: Mon 12 May, 09:00 (UTC)", outcome: "Last wake-up ran.")
        WakeSummaryView(
          state: "Paused", sentence: "Every Saturday and Sunday at 10:00",
          note: "No wake-ups until you resume it.")
        WakeScheduleStatus("Weekly · paused · compact first")
      }.padding()
    }
  }
#endif
