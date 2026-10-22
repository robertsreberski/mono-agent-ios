// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Semantic colour family. Colour is never the only cue: every status has a symbol and text.
public enum StatusTone: CaseIterable, Sendable {
  case success
  case warning
  case danger
  case neutral
  case accent

  public func color(in theme: ConsoleTheme) -> AdaptiveColor {
    switch self {
    case .success: DesignColor.success
    case .warning: DesignColor.warning
    case .danger: DesignColor.danger
    case .neutral: DesignColor.neutral
    case .accent: theme.palette.accent
    }
  }
}

/// Connection and activity states shared by indicators, chips and banners.
public enum StatusKind: String, CaseIterable, Sendable {
  case online
  case connecting
  case disconnected
  case offline
  case stale
  case warning
  case insecure
  case failed

  public var tone: StatusTone {
    switch self {
    case .online: .success
    case .connecting: .accent
    case .disconnected, .offline, .stale: .neutral
    case .warning, .insecure: .warning
    case .failed: .danger
    }
  }

  /// Distinct SF Symbol per kind: the shape alone distinguishes states without colour.
  public var systemImage: String {
    switch self {
    case .online: "checkmark.circle.fill"
    case .connecting: "arrow.triangle.2.circlepath"
    case .disconnected: "circle.dashed"
    case .offline: "wifi.slash"
    case .stale: "clock.arrow.circlepath"
    case .warning: "exclamationmark.circle.fill"
    case .insecure: "lock.open.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  public var defaultLabel: String {
    switch self {
    case .online: "Online"
    case .connecting: "Connecting"
    case .disconnected: "Not connected"
    case .offline: "Offline"
    case .stale: "Out of date"
    case .warning: "Needs attention"
    case .insecure: "Insecure HTTP"
    case .failed: "Connection failed"
    }
  }
}

/// Inline symbol + text status for rows and content. Not glass.
public struct StatusIndicator: View {
  private let kind: StatusKind
  private let label: String
  @Environment(\.consoleTheme) private var theme

  public init(_ kind: StatusKind, label: String? = nil) {
    self.kind = kind
    self.label = label ?? kind.defaultLabel
  }

  public var body: some View {
    Label {
      Text(label).foregroundStyle(.primary)
    } icon: {
      Image(systemName: kind.systemImage)
        .foregroundStyle(kind.tone.color(in: theme).color)
        .accessibilityHidden(true)
    }
    .designFont(.callout)
    .accessibilityElement(children: .combine)
  }
}

/// A compact capsule status. `.inline` uses an opaque tone fill on content; `.floating`
/// is for chips that hover above content (for example over a scrolling transcript).
public struct StatusChip: View {
  public enum Placement: Sendable {
    case inline
    case floating
  }

  private let kind: StatusKind
  private let label: String
  private let placement: Placement
  @Environment(\.consoleTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  public init(_ kind: StatusKind, label: String? = nil, placement: Placement = .inline) {
    self.kind = kind
    self.label = label ?? kind.defaultLabel
    self.placement = placement
  }

  public var body: some View {
    let tone = kind.tone.color(in: theme).color
    HStack(spacing: DesignSpacing.xs) {
      Image(systemName: kind.systemImage).foregroundStyle(tone).accessibilityHidden(true)
      Text(label).foregroundStyle(.primary)
    }
    .designFont(.supporting)
    .fontWeight(.medium)
    .padding(.horizontal, DesignSpacing.md)
    .padding(.vertical, DesignSpacing.xs + DesignSpacing.xxs)
    .modifier(ChipBackground(placement: placement, tone: tone, contrast: contrast))
    .accessibilityElement(children: .combine)
  }
}

private struct ChipBackground: ViewModifier {
  let placement: StatusChip.Placement
  let tone: Color
  let contrast: ColorSchemeContrast

  func body(content: Content) -> some View {
    switch placement {
    case .inline:
      content
        .background(tone.opacity(DesignColor.toneFillOpacity), in: Capsule())
        .overlay {
          Capsule().strokeBorder(
            tone.opacity(contrast == .increased ? 1 : 0.35),
            lineWidth: contrast == .increased ? 1.5 : 0.5)
        }
    case .floating:
      content.floatingGlass(in: Capsule())
    }
  }
}

#if DEBUG
  #Preview("Status — themes") {
    DesignPreviewMatrix {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        ForEach(StatusKind.allCases, id: \.self) { kind in
          HStack {
            StatusIndicator(kind)
            Spacer()
            StatusChip(kind)
          }
        }
      }
    }
  }

  #Preview("Status — floating, accessibility size") {
    DesignPreviewMatrix {
      StatusChip(.online, label: "Connected", placement: .floating)
      StatusChip(.failed, placement: .floating)
    }
    .dynamicTypeSize(.accessibility3)
  }
#endif
