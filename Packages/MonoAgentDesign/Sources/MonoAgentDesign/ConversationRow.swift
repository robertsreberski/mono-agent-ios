// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Whether a row's work in flight is confirmed by a fresh server summary.
public enum ActivityState: Equatable, Sendable {
  /// A fresh server summary says this conversation is running now.
  case running
  /// Only a cached or not-yet-confirmed summary says so; drawn hollow and spoken "last known".
  case lastKnown

  public var systemImage: String {
    switch self {
    case .running: "circle.circle.fill"
    case .lastKnown: "clock.arrow.circlepath"
    }
  }

  public var label: String {
    switch self {
    case .running: "Running"
    case .lastKnown: "Last known running, not confirmed"
    }
  }
}

/// The small running mark beside a preview. Symbol shape distinguishes confirmed from last known.
public struct ActivityIndicator: View {
  private let state: ActivityState
  @Environment(\.consoleTheme) private var theme

  public init(_ state: ActivityState) { self.state = state }

  public var body: some View {
    Image(systemName: state.systemImage)
      .imageScale(.small)
      .foregroundStyle(
        state == .running ? theme.palette.accent.color : DesignColor.neutral.color
      )
      .accessibilityLabel(state.label)
  }
}

/// The value-driven content of one conversation-like row (Recent, Running, search, projects).
public struct ConversationRowContent: Sendable {
  public enum Leading: Sendable, Equatable {
    /// What the row is (conversation, scheduled, webhook, needs attention).
    case symbol(String, label: String, tone: StatusTone)
    /// Which agent owns the row (Running crosses agents).
    case monogram(String, label: String)
    /// A project: a folder tile in the project's colour.
    case folder(LabelColor)
  }

  public struct Chip: Sendable, Equatable {
    public var name: String
    public var color: LabelColor
    public init(_ name: String, color: LabelColor = .standard) {
      self.name = name
      self.color = color
    }
  }

  public var leading: Leading
  public var title: AttributedString
  public var time: String?
  public var timeAccessibility: String?
  public var unread: Bool
  public var scheduled: Bool
  public var activity: ActivityState?
  public var preview: AttributedString?
  /// The preview is pending information ("Working…"), drawn quieter.
  public var previewPending: Bool
  public var project: Chip?
  public var tags: [Chip]
  /// Trailing note such as "3 matches" or "2 running".
  public var detail: String?
  /// Extra spoken context placed after the title (for example "on Atlas Research").
  public var accessibilityContext: String?

  public init(
    leading: Leading, title: AttributedString, time: String? = nil,
    timeAccessibility: String? = nil, unread: Bool = false, scheduled: Bool = false,
    activity: ActivityState? = nil, preview: AttributedString? = nil,
    previewPending: Bool = false, project: Chip? = nil, tags: [Chip] = [],
    detail: String? = nil, accessibilityContext: String? = nil
  ) {
    self.leading = leading
    self.title = title
    self.time = time
    self.timeAccessibility = timeAccessibility
    self.unread = unread
    self.scheduled = scheduled
    self.activity = activity
    self.preview = preview
    self.previewPending = previewPending
    self.project = project
    self.tags = tags
    self.detail = detail
    self.accessibilityContext = accessibilityContext
  }

  /// How many tag chips a row draws before folding the rest into "+N".
  public static let visibleTagLimit = 3

  /// One spoken sentence in reading order; status is spoken in words, never only as colour.
  public var accessibilityLabel: String {
    var parts = [String(title.characters)]
    if let accessibilityContext { parts.append(accessibilityContext) }
    if let project { parts.append("in project \(project.name)") }
    switch leading {
    case .symbol(_, let label, _) where label != "Conversation": parts.append(label)
    default: break
    }
    if unread { parts.append("unread") }
    if let activity { parts.append(activity.label) }
    if scheduled { parts.append("scheduled wake-up active") }
    if let preview, !preview.characters.isEmpty { parts.append(String(preview.characters)) }
    if !tags.isEmpty {
      parts.append("tags " + tags.map(\.name).joined(separator: ", "))
    }
    if let detail { parts.append(detail) }
    if let time = timeAccessibility ?? time { parts.append(time) }
    return parts.joined(separator: ", ")
  }
}

/// One dense list row. Opaque list content — never glass. Text wraps at accessibility sizes.
public struct ConversationRow: View {
  private let content: ConversationRowContent
  @Environment(\.consoleTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var leadingSide: CGFloat = 32

  public init(_ content: ConversationRowContent) { self.content = content }

  public var body: some View {
    // At accessibility sizes the leading tile moves above the text so lines keep full width.
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.sm))
      : AnyLayout(HStackLayout(alignment: .top, spacing: DesignSpacing.md))
    layout {
      leading.frame(width: leadingSide, height: leadingSide)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        titleLine
        previewLine
        chipsLine
        if let time = content.time, typeSize.isAccessibilitySize {
          Text(time).designFont(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, DesignSpacing.xxs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
  }

  @ViewBuilder private var leading: some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
    switch content.leading {
    case .symbol(let name, _, let tone):
      Image(systemName: name)
        .font(.system(.callout, weight: .semibold))
        .foregroundStyle(tone.color(in: theme).color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .tertiarySystemFill), in: shape)
    case .monogram(let initials, _):
      Text(initials)
        .font(.system(.caption, design: .rounded, weight: .bold))
        .foregroundStyle(theme.palette.accentStrong.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.accentSoft.color, in: shape)
    case .folder(let color):
      Image(systemName: "folder.fill")
        .font(.system(.callout, weight: .semibold))
        .foregroundStyle(color.ink(in: theme).color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.tint(in: theme).color, in: shape)
    }
  }

  private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.xs) {
      Text(content.title)
        .designFont(.body)
        .fontWeight(content.unread ? .semibold : .medium)
        .foregroundStyle(.primary)
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
      if content.unread { UnreadMarker() }
      if content.scheduled {
        Image(systemName: "alarm")
          .imageScale(.small)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: DesignSpacing.xs)
      if let time = content.time, !typeSize.isAccessibilitySize {
        Text(time).designFont(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }

  @ViewBuilder private var previewLine: some View {
    let preview = content.preview.flatMap { $0.characters.isEmpty ? nil : $0 }
    if content.activity != nil || preview != nil {
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.xs) {
        if let activity = content.activity { ActivityIndicator(activity) }
        if let preview {
          Text(preview)
            .designFont(.supporting)
            .foregroundStyle(content.previewPending ? .tertiary : .secondary)
            .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
        }
      }
    }
  }

  @ViewBuilder private var chipsLine: some View {
    let tags = content.tags.prefix(ConversationRowContent.visibleTagLimit)
    let overflow = content.tags.count - tags.count
    if content.project != nil || !tags.isEmpty || content.detail != nil {
      WrappingRow(spacing: DesignSpacing.xs) { chips(Array(tags), overflow: overflow) }
        .padding(.top, DesignSpacing.xxs)
    }
  }

  @ViewBuilder
  private func chips(_ tags: [ConversationRowContent.Chip], overflow: Int) -> some View {
    if let project = content.project { ProjectChip(project.name, color: project.color) }
    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
      TagChip(tag.name, color: tag.color)
    }
    if overflow > 0 {
      Text("+\(overflow)").designFont(.caption).foregroundStyle(.secondary)
    }
    if let detail = content.detail {
      Text(detail).designFont(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Lays chips out left to right and wraps to the next line instead of truncating them.
struct WrappingRow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(proposal.width ?? .infinity, subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, frame) in arrange(bounds.width, subviews).frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      var size = subview.sizeThatFits(.init(width: width, height: nil))
      size.width = min(size.width, width)
      if x > 0, x + size.width > width {
        x = 0
        y += line + spacing
        line = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return (frames, CGSize(width: widest, height: y + line))
  }
}

#if DEBUG
  private let previewRows: [ConversationRowContent] = [
    .init(
      leading: .symbol("bubble.left", label: "Conversation", tone: .neutral),
      title: "Quarterly field notes", time: "5m", unread: true,
      preview: "Summarised the fictional survey answers.",
      project: .init("Field notes", color: .blue),
      tags: [.init("Research", color: .teal), .init("Draft")]),
    .init(
      leading: .monogram("AR", label: "Atlas Research"), title: "Draft the launch checklist",
      time: "now", activity: .running, preview: "Working · 4 tool calls", previewPending: true),
    .init(
      leading: .symbol("exclamationmark.triangle.fill", label: "Needs attention", tone: .danger),
      title: "Nightly import", time: "2d", activity: .lastKnown, preview: "Failed"),
    .init(
      leading: .folder(.amber), title: "Website refresh", preview: "3 chats · updated 1h",
      detail: "1 running"),
  ]

  #Preview("Conversation rows — themes") {
    DesignPreviewMatrix {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
          ConversationRow(row)
        }
      }
      .contentSurface()
    }
  }

  #Preview("Conversation rows — dark, accessibility size") {
    List(Array(previewRows.enumerated()), id: \.offset) { _, row in ConversationRow(row) }
      .preferredColorScheme(.dark)
      .dynamicTypeSize(.accessibility3)
      .consoleTheme(.ocean)
  }
#endif
