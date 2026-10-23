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
  /// The trailing route badge (`model · effort`), drawn under the time as on the web.
  public var route: String?
  /// A disclosure chevron (project rows).
  public var chevron: Bool = false

  public init(
    leading: Leading, title: AttributedString, time: String? = nil,
    timeAccessibility: String? = nil, unread: Bool = false, scheduled: Bool = false,
    activity: ActivityState? = nil, preview: AttributedString? = nil,
    previewPending: Bool = false, project: Chip? = nil, tags: [Chip] = [],
    detail: String? = nil, accessibilityContext: String? = nil, route: String? = nil,
    chevron: Bool = false
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
    self.route = route
    self.chevron = chevron
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

/// One dense web-console list row (`.thread-trigger`, `.project-trigger`, running card body):
/// 30 pt glyph column, 12/650 title with trailing time, a 10 pt subtitle line with project, tags
/// and the route badge. Opaque list content — never glass. Text wraps at accessibility sizes.
public struct ConversationRow: View {
  private let content: ConversationRowContent
  @Environment(\.consoleTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = WebMetrics.rowGlyph
  @ScaledMetric(relativeTo: .caption2) private var dot: CGFloat = 6
  public init(_ content: ConversationRowContent) { self.content = content }
  public var body: some View {
    // At accessibility sizes the leading tile moves above the text so lines keep full width.
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: WebSpace.rowCopyGap))
      : AnyLayout(HStackLayout(alignment: .center, spacing: WebSpace.rowGap))
    layout {
      leading.frame(width: glyph, height: glyph)
      VStack(alignment: .leading, spacing: WebSpace.rowCopyGap) {
        titleLine
        previewLine
        if typeSize.isAccessibilitySize { accessibilityExtras }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if content.chevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(WebColor.textMuted.color)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, WebSpace.rowPaddingVertical)
    .padding(.horizontal, WebSpace.rowPaddingHorizontal)
    .frame(minHeight: WebMetrics.rowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.accessibilityLabel)
  }
  @ViewBuilder private var leading: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    switch content.leading {
    case .symbol(let name, _, let tone):
      Image(systemName: name)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(
          tone == .neutral ? WebColor.textSoft.color : tone.color(in: theme).color
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .monogram(let initials, _):
      Text(initials)
        .webFont(.agentBadge)
        .foregroundStyle(WebColor.text.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.canvas.color, in: shape)
    case .folder(let color):
      Image(systemName: "folder")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(color.ink(in: theme).color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.tint(in: theme).color, in: shape)
    }
  }
  private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: WebSpace.sectionHeadBottom) {
      Text(content.title)
        .webFont(.rowTitle)
        .foregroundStyle(WebColor.text.color)
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
      if content.scheduled {
        Image(systemName: "alarm")
          .font(.system(size: 9))
          .foregroundStyle(WebColor.textMuted.color)
      }
      Spacer(minLength: WebSpace.rowCopyGap)
      if content.unread {
        Circle().fill(theme.palette.accent.color).frame(width: dot, height: dot)
          .accessibilityHidden(true)
      }
      if let time = content.time, !typeSize.isAccessibilitySize {
        Text(time).webFont(.rowTime).foregroundStyle(WebColor.textMuted.color)
          .lineLimit(1).fixedSize()
      }
    }
  }
  @ViewBuilder private var previewLine: some View {
    let preview = content.preview.flatMap { $0.characters.isEmpty ? nil : $0 }
    let tags = content.tags.prefix(ConversationRowContent.visibleTagLimit)
    let overflow = content.tags.count - tags.count
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let activity = content.activity {
        Circle()
          .fill(activity == .running ? theme.palette.accent.color : WebColor.textMuted.color)
          .frame(width: dot, height: dot)
          .overlay {
            if activity == .lastKnown {
              Circle().strokeBorder(WebColor.textMuted.color, lineWidth: 1)
                .background(Circle().fill(Color.clear))
            }
          }
          .accessibilityHidden(true)
      }
      if let project = content.project {
        ProjectBadge(project.name, color: project.color)
          .layoutPriority(1)
      }
      if let preview {
        Text(preview)
          .webFont(.rowSubtitle)
          .foregroundStyle(WebColor.textMuted.color)
          .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
      }
      if !typeSize.isAccessibilitySize {
        Spacer(minLength: 4)
        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
          TagBadge(tag.name, color: tag.color)
        }
        if overflow > 0 {
          Text("+\(overflow)").webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
        }
        if let detail = content.detail {
          Text(detail).webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
            .lineLimit(1).fixedSize()
        }
        if let route = content.route {
          Text(route).webFont(.rowSubtitle).foregroundStyle(WebColor.textSoft.color)
            .lineLimit(1).fixedSize()
        }
      }
    }
  }
  @ViewBuilder private var accessibilityExtras: some View {
    let tags = content.tags.prefix(ConversationRowContent.visibleTagLimit)
    if content.project != nil || !tags.isEmpty || content.detail != nil || content.route != nil
      || content.time != nil
    {
      WrappingRow(spacing: 6) {
        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
          TagBadge(tag.name, color: tag.color)
        }
        if let detail = content.detail {
          Text(detail).webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
        }
        if let route = content.route {
          Text(route).webFont(.rowSubtitle).foregroundStyle(WebColor.textSoft.color)
        }
        if let time = content.time {
          Text(time).webFont(.rowTime).foregroundStyle(WebColor.textMuted.color)
        }
      }
    }
  }
}

/// The web `.thread-project` badge: folder glyph and the project name in its ink, no fill.
public struct ProjectBadge: View {
  private let name: String
  private let color: LabelColor
  @Environment(\.consoleTheme) private var theme
  public init(_ name: String, color: LabelColor = .standard) {
    self.name = name
    self.color = color
  }
  public var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "folder").font(.system(size: 9, weight: .medium))
      Text(name).webFont(.chip).lineLimit(1)
    }
    .foregroundStyle(color.ink(in: theme).color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Project \(name)")
  }
}

/// The web row tag: a separator dot, a colour dot and the tag name.
public struct TagBadge: View {
  private let name: String
  private let color: LabelColor
  @Environment(\.consoleTheme) private var theme
  @ScaledMetric(relativeTo: .caption2) private var dot: CGFloat = 5
  public init(_ name: String, color: LabelColor = .standard) {
    self.name = name
    self.color = color
  }
  public var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color.ink(in: theme).color).frame(width: dot, height: dot)
      Text(name).webFont(.rowSubtitle).foregroundStyle(WebColor.textSoft.color).lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tag \(name)")
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
