// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Unread state: a dot when the count is unknown or one, a numeric badge otherwise.
/// Presence of the shape (not its colour) is the cue; VoiceOver hears the count.
public struct UnreadMarker: View {
  private let count: Int?
  @Environment(\.consoleTheme) private var theme
  @ScaledMetric(relativeTo: .footnote) private var dot = DesignMetrics.unreadDot

  /// `nil` marks "has unread" without a count.
  public init(count: Int? = nil) { self.count = count }

  /// Badge text, or `nil` for a plain dot. Counts above 99 read "99+".
  nonisolated public static func badgeText(for count: Int?) -> String? {
    guard let count, count > 1 else { return nil }
    return count > 99 ? "99+" : String(count)
  }

  nonisolated public static func accessibilityText(for count: Int?) -> String {
    guard let count, count > 0 else { return "Unread" }
    return count == 1 ? "1 unread" : "\(count) unread"
  }

  public var body: some View {
    let palette = theme.palette
    Group {
      if let text = Self.badgeText(for: count) {
        Text(text)
          .designFont(.caption).fontWeight(.semibold).monospacedDigit()
          .foregroundStyle(palette.onAccent.color)
          .padding(.horizontal, DesignSpacing.sm - DesignSpacing.xxs)
          .padding(.vertical, DesignSpacing.xxs)
          .frame(minWidth: dot * 2)
          .background(palette.accent.color, in: Capsule())
      } else {
        Circle().fill(palette.accent.color).frame(width: dot, height: dot)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityText(for: count))
  }
}

#if DEBUG
  #Preview("Unread — themes") {
    DesignPreviewMatrix {
      HStack(spacing: DesignSpacing.lg) {
        UnreadMarker()
        UnreadMarker(count: 3)
        UnreadMarker(count: 42)
        UnreadMarker(count: 250)
      }
    }
  }

  #Preview("Unread — dark") {
    DesignPreviewMatrix {
      HStack(spacing: DesignSpacing.lg) {
        UnreadMarker()
        UnreadMarker(count: 7)
      }
    }
    .preferredColorScheme(.dark)
  }
#endif
