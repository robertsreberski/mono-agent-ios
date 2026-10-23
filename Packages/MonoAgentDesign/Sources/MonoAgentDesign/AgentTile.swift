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
  @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = WebMetrics.agentSquare
  @ScaledMetric(relativeTo: .caption2) private var badgeSide: CGFloat = 16

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
    let shape = RoundedRectangle(cornerRadius: WebRadius.medium, style: .continuous)
    // Web `.agent-chip`: 44 pt square on app-bg with an inset 1 px line-strong ring; the active
    // agent gets an inset 2 px accent ring. Offline is dashed and dimmed, degraded is ringed in
    // the warning hue and carries a symbol, so presence never relies on colour alone.
    VStack(spacing: 5) {
      Text(initials)
        .webFont(.agentInitials)
        .foregroundStyle(
          presence == .offline && !selected ? WebColor.textMuted.color : WebColor.text.color
        )
        .frame(width: side, height: side)
        .background { shape.fill(palette.canvas.color) }
        .overlay {
          if selected {
            shape.inset(by: 1).stroke(palette.accent.color, lineWidth: 2)
          } else if presence == .offline {
            shape.inset(by: 0.5).stroke(
              WebColor.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          } else if presence == .degraded {
            shape.inset(by: 1).stroke(WebColor.warning.color, lineWidth: 2)
          } else {
            shape.inset(by: 0.5).stroke(
              contrast == .increased ? WebColor.textMuted.color : WebColor.lineStrong.color,
              lineWidth: 1)
          }
        }
        .opacity(presence == .offline && !selected ? 0.55 : 1)
        .overlay(alignment: .topLeading) {
          if pinned {
            Image(systemName: "star.fill")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(DesignColor.warning.color)
              .padding(2)
              .background(palette.panel.color, in: Circle())
              .offset(x: -5, y: -5)
          }
        }
        .overlay(alignment: .topTrailing) {
          corner.offset(x: 6, y: -6)
        }
        .overlay(alignment: .bottomTrailing) {
          if presence != .online {
            Image(systemName: presence.status.systemImage)
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(presence.status.tone.color(in: theme).color)
              .padding(2)
              .background(palette.panel.color, in: Circle())
              .offset(x: 5, y: 5)
          }
        }
      if let caption {
        Text(caption)
          .webFont(.agentLabel)
          .foregroundStyle(selected ? WebColor.text.color : WebColor.textSoft.color)
          .lineLimit(1)
          .frame(maxWidth: side + 4)
      }
    }
    .frame(minWidth: 48)
    .padding(.top, 6)
    .accessibilityElement(children: .ignore)
  }
  @ViewBuilder private var corner: some View {
    let palette = theme.palette
    switch badge {
    case .running(let count):
      // Web `.agent-chip-badge`: 16 pt accent disc with the on-accent count.
      Text(UnreadMarker.badgeText(for: count) ?? String(count))
        .webFont(.agentBadge)
        .foregroundStyle(palette.onAccent.color)
        .padding(.horizontal, 4)
        .frame(minWidth: badgeSide, minHeight: badgeSide)
        .background(palette.accent.color, in: Capsule())
        .overlay { Capsule().stroke(palette.panel.color, lineWidth: 2) }
    case .unread(let count):
      Text(count > 99 ? "99+" : String(count))
        .webFont(.agentBadge)
        .foregroundStyle(palette.accentStrong.color)
        .padding(.horizontal, 4)
        .frame(minWidth: badgeSide, minHeight: badgeSide)
        .background(palette.panel.color, in: Capsule())
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
