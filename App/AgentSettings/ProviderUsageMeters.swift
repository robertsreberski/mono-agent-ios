// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ProviderUsageMeters: View {
  let usage: ProviderUsage
  let compact: Bool
  @Environment(\.consoleTheme) private var theme
  #if DEBUG
    @Environment(\.fixtureReferenceDate) private var referenceDate
  #else
    private var referenceDate: Date? { nil }
  #endif

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      let now = referenceDate ?? timeline.date
      VStack(alignment: .leading, spacing: 10) {
        if usage.stale {
          Text("Last known · \(age(now)) ago").webFont(.settingsNote)
            .foregroundStyle(WebColor.warning.color)
            .accessibilityIdentifier("provider-usage-last-known-" + usage.providerId)
        }
        ForEach(usage.windows, id: \.kind) { window in meter(window, now: now) }
        if usage.error != nil {
          // Vendor response bodies are never presented. Usage errors have fixed public copy.
          Text("Usage unavailable — \(usageError(usage.error?.code))")
            .webFont(.settingsNote).foregroundStyle(WebColor.textMuted.color)
        }
      }
    }
  }
  private func meter(_ window: ProviderUsageWindow, now: Date) -> some View {
    let projection = ProviderUsageProjection.project(window, fetchedAt: usage.fetchedAt)
    let percent = window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    let detail = detail(window, projection: projection, now: now)
    return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
      if compact {
        HStack(spacing: 8) {
          Text(verbatim: ProviderPresentation.boundedText(window.label)).webFont(.settingsNote)
            .frame(minWidth: 48, alignment: .leading)
          bar(window, projection: projection)
          Text(percent).webFont(.settingsMono).monospacedDigit()
        }
      } else {
        HStack {
          Text(verbatim: ProviderPresentation.boundedText(window.label)).webFont(.settingsNote)
          Spacer()
          Text(percent).webFont(.settingsMono).monospacedDigit()
          if let projection, projection.confidence == .normal {
            SettingsChip(String(format: "%.1f×", projection.pace))
          }
        }
        bar(window, projection: projection)
      }
      if !detail.isEmpty {
        Text(verbatim: detail).webFont(.settingsNote).foregroundStyle(WebColor.textMuted.color)
      }
    }
    .foregroundStyle(WebColor.textSoft.color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility(window, projection: projection, detail: detail))
    .accessibilityIdentifier("provider-meter-" + usage.providerId + "-" + window.kind)
  }
  private func bar(_ window: ProviderUsageWindow, projection: ProviderUsageProjection?) -> some View
  {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(WebColor.text.color.opacity(0.1))
        Capsule().fill(theme.palette.accent.color)
          .frame(width: geometry.size.width * min(1, max(0, window.usedPercent / 100)))
        if let projection {
          Capsule().fill(theme.palette.accentStrong.color).frame(width: 3, height: 10)
            .offset(
              x: max(
                0, min(geometry.size.width - 3, geometry.size.width * projection.elapsedFraction)))
        }
      }
    }
    .frame(height: compact ? 5 : 6)
    .accessibilityHidden(true)
  }
  private func detail(
    _ window: ProviderUsageWindow, projection: ProviderUsageProjection?, now: Date
  ) -> String {
    var parts: [String] = []
    if let reset = window.resetsAt,
      let countdown = ProviderUsageProjection.countdown(reset, now: now, compact: compact)
    {
      parts.append(countdown)
    }
    if let projection {
      if compact && projection.confidence == .normal {
        parts.append(String(format: "%.1f×", projection.pace))
      }
      if let lead = projection.leadMs {
        parts.append("empty \(ProviderUsageProjection.formatLead(lead)) early")
      } else if let unused = projection.projectedUnusedPercent, unused >= 5 {
        parts.append("\(Int(floor(unused + 0.5)))% unused")
      }
    }
    return parts.joined(separator: " · ")
  }
  private func accessibility(
    _ window: ProviderUsageWindow, projection: ProviderUsageProjection?, detail: String
  ) -> String {
    var label = "\(usage.label) \(window.label) used, \(window.usedPercent) percent"
    if let projection {
      label +=
        ", \(Int((projection.elapsedFraction * 100).rounded())) percent of the window elapsed, pace \(String(format: "%.1f", projection.pace)) times, \(projection.confidence.rawValue) confidence"
      if projection.exhaustsAt != nil {
        label += ", projected to run out before reset, \(projection.severity.rawValue)"
      }
    }
    if usage.stale { label += ", last known usage" }
    label += ", fetched \(usage.fetchedAt). \(detail)"
    return ProviderPresentation.boundedText(label)
  }
  private func age(_ now: Date) -> String {
    guard let fetched = ProviderUsageProjection.parseDate(usage.fetchedAt) else {
      return "unknown age"
    }
    return ProviderUsageProjection.formatLead(now.timeIntervalSince(fetched) * 1000)
  }
  private func usageError(_ code: String?) -> String {
    switch code {
    case "auth_failed": "Credential rejected; re-login to this provider."
    case "not_entitled": "No Go subscription."
    case "rate_limited": "Rate limited; retrying after backoff."
    case "timeout": "Provider request timed out."
    case "network_failed": "Provider could not be reached."
    case "invalid_response": "Provider returned an invalid usage response."
    default: "Provider usage is unavailable."
    }
  }
}
