// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// One agent as a monogram square: selection, presence, pin and a single corner badge.
///
/// Every state has a non-colour cue: selection fills the square, presence has its own
/// symbol, pinning a star, running work a bolt and unread a plain count. The caller wraps the
/// tile in its control and reads `accessibilityLabel(…)` for the spoken name.
public struct AgentTile: View {
  public enum Presence: String, CaseIterable, Sendable {
    case online, degraded, offline

    /// Exact wire values; an unknown status is treated as degraded rather than online.
    public init(serverValue: String) {
      self = Presence(rawValue: serverValue) ?? .degraded
    }

    var status: StatusKind {
      switch self {
      case .online: .online
      case .degraded: .warning
      case .offline: .offline
      }
    }

    public var label: String {
      switch self {
      case .online: "online"
      case .degraded: "degraded"
      case .offline: "offline"
      }
    }
  }

  /// Work in flight wins the corner over unread, as in the web console's agent strip.
  public enum Badge: Equatable, Sendable {
    case running(Int)
    case unread(Int)
  }

  private let initials: String
  private let caption: String?
  private let presence: Presence
  private let selected: Bool
  private let pinned: Bool
  private let badge: Badge?
  @Environment(\.consoleTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 48

  public init(
    initials: String, caption: String? = nil, presence: Presence = .online,
    selected: Bool = false, pinned: Bool = false, badge: Badge? = nil
  ) {
    self.initials = initials
    self.caption = caption
    self.presence = presence
    self.selected = selected
    self.pinned = pinned
    self.badge = badge
  }

  /// "Atlas Research, online, pinned, 2 running" — the badge is spoken even though only one
  /// count is drawn.
  nonisolated public static func accessibilityLabel(
    name: String, presence: Presence, pinned: Bool, running: Int, unread: Int
  ) -> String {
    var parts = [name, presence.label]
    if pinned { parts.append("pinned") }
    if running > 0 { parts.append("\(running) running") }
    if unread > 0 { parts.append("\(unread) unread") }
    return parts.joined(separator: ", ")
  }

  /// Running hides unread in the corner; both remain in the accessibility label.
  nonisolated public static func badge(running: Int, unread: Int) -> Badge? {
    if running > 0 { return .running(running) }
    if unread > 0 { return .unread(unread) }
    return nil
  }

  public var body: some View {
    let palette = theme.palette
    let shape = RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
    VStack(spacing: DesignSpacing.xs) {
      Text(initials)
        .font(.system(.headline, design: .rounded, weight: .bold))
        .foregroundStyle(selected ? palette.onAccent.color : Color.primary)
        .frame(width: side, height: side)
        .background {
          shape.fill(selected ? palette.accent.color : Color(uiColor: .tertiarySystemFill))
        }
        .overlay {
          if presence == .offline && !selected {
            shape.strokeBorder(
              Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          } else if contrast == .increased {
            shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
          }
        }
        .opacity(presence == .offline && !selected ? 0.75 : 1)
        .overlay(alignment: .topLeading) {
          if pinned {
            Image(systemName: "star.fill")
              .font(.system(.caption2, weight: .bold))
              .foregroundStyle(DesignColor.warning.color)
              .padding(DesignSpacing.xxs)
              .background(DesignColor.opaqueControlSurface.color, in: Circle())
              .offset(x: -DesignSpacing.xs, y: -DesignSpacing.xs)
          }
        }
        .overlay(alignment: .topTrailing) {
          corner.offset(x: DesignSpacing.sm, y: -DesignSpacing.sm)
        }
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: presence.status.systemImage)
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(presence.status.tone.color(in: theme).color)
            .padding(DesignSpacing.xxs)
            .background(DesignColor.opaqueControlSurface.color, in: Circle())
            .offset(x: DesignSpacing.xs, y: DesignSpacing.xs)
        }
      if let caption {
        Text(caption)
          .designFont(.caption)
          .fontWeight(selected ? .semibold : .regular)
          .foregroundStyle(selected ? Color.primary : Color.secondary)
          .lineLimit(1)
          .frame(maxWidth: side + DesignSpacing.lg)
      }
    }
    .padding(.top, DesignSpacing.sm)
    .padding(.horizontal, DesignSpacing.xs)
    .accessibilityElement(children: .ignore)
  }

  @ViewBuilder private var corner: some View {
    let palette = theme.palette
    switch badge {
    case .running(let count):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "bolt.fill").imageScale(.small)
        Text(UnreadMarker.badgeText(for: count) ?? String(count)).monospacedDigit()
      }
      .font(.system(.caption2, weight: .bold))
      .foregroundStyle(palette.onAccent.color)
      .padding(.horizontal, DesignSpacing.xs + DesignSpacing.xxs)
      .padding(.vertical, DesignSpacing.xxs)
      .background(palette.accent.color, in: Capsule())
    case .unread(let count):
      Text(count > 99 ? "99+" : String(count))
        .font(.system(.caption2, weight: .bold)).monospacedDigit()
        .foregroundStyle(Color.primary)
        .padding(.horizontal, DesignSpacing.xs + DesignSpacing.xxs)
        .padding(.vertical, DesignSpacing.xxs)
        .background(DesignColor.opaqueControlSurface.color, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.accent.color, lineWidth: 1.5) }
    case nil:
      EmptyView()
    }
  }
}

#if DEBUG
  #Preview("Agent tiles — themes") {
    DesignPreviewMatrix {
      HStack(alignment: .top, spacing: DesignSpacing.md) {
        AgentTile(
          initials: "AR", caption: "Atlas", selected: true, pinned: true, badge: .running(2))
        AgentTile(initials: "HO", caption: "Harbor", presence: .degraded, badge: .unread(3))
        AgentTile(initials: "QW", caption: "Quill")
        AgentTile(initials: "DH", caption: "Dormant", presence: .offline)
      }
    }
  }

  #Preview("Agent tiles — dark, accessibility size") {
    DesignPreviewMatrix {
      HStack(alignment: .top) {
        AgentTile(initials: "AR", caption: "Atlas", selected: true, badge: .running(12))
        AgentTile(initials: "QW", caption: "Quill", pinned: true, badge: .unread(140))
      }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
  }
#endif
