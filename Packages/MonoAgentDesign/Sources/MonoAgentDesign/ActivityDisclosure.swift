// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// What an activity row's glyph column shows (web `.activity-row` variants).
public enum ActivityGlyph: Sendable {
  /// A 7 pt status dot in a 3 pt tint ring (tool calls).
  case dot
  /// The reasoning sparkle.
  case reasoning
  /// The delegation (subagent) glyph in the cat-4 colour.
  case agent
  /// A background-job lifecycle fact: terminal or agent icon.
  case job(agent: Bool)
}

/// Dense, opaque transcript activity; the caller owns expansion and work state.
public struct ActivityDisclosure<Content: View>: View {
  private let title: String
  private let summary: String
  private let status: StatusKind
  private let detail: String?
  private let alert: String?
  private let glyph: ActivityGlyph
  private let identifier: String
  @Binding private var expanded: Bool
  private let content: () -> Content
  public init(
    _ title: String, summary: String = "", status: StatusKind = .disconnected,
    detail: String? = nil, alert: String? = nil, glyph: ActivityGlyph = .dot,
    identifier: String = "activity-disclosure", expanded: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.status = status
    self.detail = detail
    self.alert = alert
    self.glyph = glyph
    self.identifier = identifier
    _expanded = expanded
    self.content = content
  }
  /// Web `.activity-row` summary: 18 pt glyph column (7 pt status dot in a 3 pt tint ring),
  /// 11.5/650 label, 10.5 muted preview, an optional uppercase alert pill, mono 9 time and a
  /// chevron that turns over when open; one line, 44 pt on touch, radius 9.
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .center, spacing: 8) {
          glyphView.frame(width: 18).accessibilityHidden(true)
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              titleText
              summaryText.frame(maxWidth: .infinity, alignment: .leading)
              trailing
            }
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleText
                summaryText.frame(maxWidth: .infinity, alignment: .leading)
              }
              trailing
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .foregroundStyle(WebColor.textMuted.color)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }.buttonStyle(WebRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          [title, summary, alert ?? "", detail ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") activity")
        .accessibilityIdentifier(identifier)
      if expanded {
        VStack(alignment: .leading, spacing: 7) { content() }
          .padding(.leading, 10)
          .overlay(alignment: .leading) {
            Rectangle().fill(WebColor.line.color).frame(width: 1)
          }
          .padding(.leading, 16)
          .padding(.trailing, 2)
          .padding(.bottom, 6)
      }
    }
  }
  private var titleText: some View {
    Text(title).webFont(.activityRowLabel).foregroundStyle(WebColor.text.color)
      .lineLimit(1).fixedSize()
  }
  private var summaryText: some View {
    Text(summary).webFont(.activityMeta).foregroundStyle(WebColor.textMuted.color)
      .lineLimit(1).truncationMode(.middle)
  }
  @ViewBuilder private var trailing: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      if let alert, !alert.isEmpty {
        Text(alert).font(.system(size: 9, weight: .bold)).tracking(0.6).textCase(.uppercase)
          .foregroundStyle(WebColor.danger.color)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(WebColor.danger.color.opacity(0.12), in: Capsule())
          .fixedSize()
      }
      if let detail, !detail.isEmpty {
        Text(detail).webFont(.stepTime).foregroundStyle(WebColor.textMuted.color)
          .lineLimit(1)
      }
    }
  }
  @ViewBuilder private var glyphView: some View {
    switch glyph {
    case .dot:
      // A dot at rest; running and failed rows change shape too, never colour alone.
      Group {
        if status.tone == .danger || status == .connecting {
          Image(systemName: status.tone == .danger ? "xmark" : "circle.lefthalf.filled")
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(dotColor)
            .frame(width: 7, height: 7)
        } else {
          Circle().fill(dotColor).frame(width: 7, height: 7)
        }
      }
      .padding(3)
      .background(Circle().fill(dotColor.opacity(0.18)))
    case .reasoning:
      Image(systemName: "sparkle")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(
          status == .connecting ? WebColor.jobProgress.color : WebColor.textMuted.color)
    case .agent:
      Image(systemName: "face.smiling")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(agentColor)
    case .job(let agent):
      Image(systemName: agent ? "face.smiling" : "apple.terminal")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(agentColor)
    }
  }
  @Environment(\.consoleTheme) private var theme
  private var agentColor: Color {
    switch status.tone {
    case .danger: WebColor.danger.color
    case .warning: WebColor.warning.color
    default:
      status == .connecting
        ? WebColor.warning.color
        : {
          if case .job = glyph {
            return theme.palette.accent.color
          } else {
            return WebColor.delegation.color
          }
        }()
    }
  }
  private var dotColor: Color {
    switch status.tone {
    case .danger: WebColor.danger.color
    case .warning: WebColor.warning.color
    case .success: theme.palette.accent.color
    default:
      status == .connecting ? WebColor.warning.color : theme.palette.accent.color
    }
  }
}

/// Web `.activity-root`: a band of consecutive activity (reasoning, tools, delegations) in one
/// opaque panel (panel 32% into surface, 1 px line, radius 12) with an "ACTIVITY" header
/// (minH 44, P2/16/0) carrying the step count and the turn's clock.
public struct ActivityBand<Content: View>: View {
  private let meta: String
  private let running: Bool
  private let identifier: String
  @Binding private var expanded: Bool
  private let content: () -> Content
  @Environment(\.consoleTheme) private var theme

  public init(
    meta: String, running: Bool, identifier: String = "activity-band", expanded: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.meta = meta
    self.running = running
    self.identifier = identifier
    _expanded = expanded
    self.content = content
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.medium, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "waveform.path.ecg")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.palette.accent.color)
            .symbolEffect(.pulse, isActive: running)
          Text("Activity").webFont(.activityLabel).foregroundStyle(theme.palette.accent.color)
            .fixedSize()
          Text(meta).font(.system(size: 10)).foregroundStyle(WebColor.textMuted.color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(WebColor.textMuted.color)
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.top, 2).padding(.horizontal, 16)
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Activity, " + meta)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier(identifier)
      if expanded {
        VStack(alignment: .leading, spacing: 0) { content() }
          .padding(.horizontal, 12).padding(.bottom, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.palette.panel.mixed(32, with: WebColor.surface).color, in: shape)
    .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
  }
}

#if DEBUG
  #Preview("Activity disclosure") {
    DesignPreviewMatrix {
      ActivityBand(meta: "2 steps · 1.2s", running: false, expanded: .constant(true)) {
        ActivityDisclosure(
          "Read ×3", summary: "outline.md, sample.md +1", detail: "1.2s", alert: "1 failed",
          expanded: .constant(true)
        ) {
          Text("Input and output").designFont(.code)
        }
        ActivityDisclosure("Reasoning", glyph: .reasoning, expanded: .constant(false)) {
          EmptyView()
        }
      }
    }
  }
#endif
