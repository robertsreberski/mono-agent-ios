// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// What an activity row's glyph column shows (web `.activity-row` variants).
public enum ActivityGlyph: Sendable, Equatable {
  /// A 7 pt status dot in a 3 pt tint ring (tool calls).
  case dot
  /// The thought bulb (web `variant="thinking"`), always muted.
  case reasoning
  /// The delegation (subagent) glyph in the cat-4 colour.
  case agent
  /// A background-job lifecycle fact: terminal or agent icon.
  case job(agent: Bool)

  /// Web phone grids put subagent and job rows on two lines (`styles.css` ≤560 px).
  var twoLineOnPhone: Bool {
    switch self {
    case .agent, .job: true
    case .dot, .reasoning: false
    }
  }
}

/// One web `.activity-row`: a tool call, a `Read ×4` cluster, a thought, a delegation or a job
/// fact share this shape; only the glyph and what expanding reveals differ. The caller owns
/// expansion and supplies already-indented content (`ActivityPayload`, `ActivitySteps`,
/// `ActivityThought`), as the web row's children carry their own indentation.
public struct ActivityDisclosure<Content: View>: View {
  private let title: String
  private let summary: String
  private let status: StatusKind
  private let detail: String?
  private let alert: String?
  private let badge: String?
  private let glyph: ActivityGlyph
  private let identifier: String
  @Binding private var expanded: Bool
  private let content: () -> Content
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.consoleTheme) private var theme
  public init(
    _ title: String, summary: String = "", status: StatusKind = .disconnected,
    detail: String? = nil, alert: String? = nil, badge: String? = nil,
    glyph: ActivityGlyph = .dot, identifier: String = "activity-disclosure",
    expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.summary = summary
    self.status = status
    self.detail = detail
    self.alert = alert
    self.badge = badge
    self.glyph = glyph
    self.identifier = identifier
    _expanded = expanded
    self.content = content
  }
  private var twoLine: Bool { glyph.twoLineOnPhone && sizeClass != .regular }
  /// Web `.activity-row > summary`: 18 pt glyph column, 11.5/650 label, 10.5 muted summary that
  /// ellipsizes (never wraps), an uppercase failed tag, mono 9 time and a chevron; 44 pt on touch.
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        Group {
          if twoLine { twoLineRow } else { oneLineRow }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(WebRowButtonStyle())
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        [
          title, summary, badge ?? "", alert ?? "", detail ?? "",
          status == .connecting ? "running" : "",
        ]
        .filter { !$0.isEmpty }.joined(separator: ", ")
      )
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") activity")
      .accessibilityIdentifier(identifier)
      if expanded { content() }
    }
  }
  private var oneLineRow: some View {
    HStack(alignment: .center, spacing: 8) {
      glyphView.frame(width: 18).accessibilityHidden(true)
      if !title.isEmpty { titleText }
      summaryText.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(-1)
      if let badge, !badge.isEmpty { badgeText(badge).lineLimit(1) }
      trailing
      chevron
    }
  }
  /// Web ≤560 px subagent/job grid: purpose on the first line (a delegation's task may take two),
  /// metadata wrapping underneath.
  private var twoLineRow: some View {
    HStack(alignment: .top, spacing: 7) {
      glyphView.frame(width: 18, height: 18).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if !title.isEmpty { titleText }
          summaryText.lineLimit(glyph == .agent ? 2 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        WebFlowLayout(spacing: 7, lineSpacing: 1) {
          if let badge, !badge.isEmpty { badgeText(badge) }
          trailing
        }
      }
      chevron.frame(height: 18)
    }
    .padding(.vertical, 6)
  }
  private var titleText: some View {
    Text(title).webFont(.activityRowLabel).foregroundStyle(WebColor.text.color)
      .lineLimit(1).fixedSize()
  }
  private var summaryText: some View {
    Text(summary).webFont(.activityMeta).foregroundStyle(WebColor.textMuted.color)
      .truncationMode(.tail)
  }
  private func badgeText(_ text: String) -> some View {
    Text(text).webFont(.stepTime).foregroundStyle(WebColor.textMuted.color)
  }
  private var chevron: some View {
    Image(systemName: "chevron.down")
      .font(.system(size: 10, weight: .semibold))
      .rotationEffect(.degrees(expanded ? 180 : 0))
      .foregroundStyle(WebColor.textMuted.color)
      .accessibilityHidden(true)
  }
  @ViewBuilder private var trailing: some View {
    if let alert, !alert.isEmpty { FailedTag(alert) }
    if let detail, !detail.isEmpty {
      Text(detail).webFont(.stepTime).foregroundStyle(WebColor.textMuted.color)
        .lineLimit(1).fixedSize()
    }
  }
  @ViewBuilder private var glyphView: some View {
    switch glyph {
    case .dot:
      // Web `.activity-dot`: accent at rest, warning pulsing while running, danger when failed.
      // Running keeps a half-filled shape as its non-colour cue; failure carries the tag.
      Group {
        if status == .connecting {
          Image(systemName: "circle.lefthalf.filled")
            .font(.system(size: 7, weight: .black))
            .symbolEffect(.pulse, isActive: true)
        } else {
          Circle().frame(width: 7, height: 7)
        }
      }
      .foregroundStyle(dotColor)
      .frame(width: 7, height: 7)
      .padding(3)
      .background(Circle().fill(dotColor.opacity(0.12)))
    case .reasoning:
      Image(systemName: "lightbulb")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(WebColor.textMuted.color)
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
  private var agentColor: Color {
    switch status.tone {
    case .danger: WebColor.danger.color
    case .warning: WebColor.warning.color
    default:
      if status == .connecting {
        WebColor.warning.color
      } else if case .job = glyph {
        theme.palette.accent.color
      } else {
        WebColor.delegation.color
      }
    }
  }
  private var dotColor: Color {
    switch status.tone {
    case .danger: WebColor.danger.color
    case .warning: WebColor.warning.color
    default: status == .connecting ? WebColor.warning.color : theme.palette.accent.color
    }
  }
}

/// Web `.failed-tag`: "failed" / "2 failed", 8.5/700 uppercase on danger 10%, radius 5.
public struct FailedTag: View {
  private let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    Text(text).webFont(.failedTag)
      .foregroundStyle(WebColor.danger.color)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(
        WebColor.danger.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5)
      )
      .lineLimit(1)
      .fixedSize()
  }
}

/// Web `.activity-steps`: the members of an expanded row on a 1 px rail inset 16 pt, so nested
/// work is never confused with the agent's own.
public struct ActivitySteps<Content: View>: View {
  private let content: Content
  public init(@ViewBuilder content: () -> Content) { self.content = content() }
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(.leading, 10)
      .overlay(alignment: .leading) {
        Rectangle().fill(WebColor.line.color).frame(width: 1)
      }
      .padding(.leading, 16)
      .padding(.trailing, 2)
      .padding(.bottom, 6)
  }
}

/// Web `ActivityStep`: a member of an expanded cluster or delegation. Deliberately flatter than
/// the row that owns it: no status dot and no state word, mono tool name, failure as a tag.
public struct ActivityStep<Content: View>: View {
  private let toolName: String
  private let summary: String
  private let failed: String?
  private let duration: String?
  private let identifier: String
  private let content: () -> Content
  @State private var expanded = false
  public init(
    _ toolName: String, summary: String = "", failed: String? = nil, duration: String? = nil,
    identifier: String = "activity-step", @ViewBuilder content: @escaping () -> Content
  ) {
    self.toolName = toolName
    self.summary = summary
    self.failed = failed
    self.duration = duration
    self.identifier = identifier
    self.content = content
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Text(toolName).webFont(.stepTool).foregroundStyle(WebColor.textSoft.color)
            .lineLimit(1).truncationMode(.tail)
          Text(summary).webFont(.stepSummary).foregroundStyle(WebColor.textMuted.color)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
          if let failed { FailedTag(failed) }
          if let duration {
            Text(duration).webFont(.stepTime).foregroundStyle(WebColor.textMuted.color)
              .lineLimit(1).fixedSize()
          }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
      }
      .buttonStyle(WebRowButtonStyle())
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        [toolName, summary, failed ?? "", duration ?? ""].filter { !$0.isEmpty }
          .joined(separator: ", ")
      )
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier(identifier)
      if expanded { content() }
    }
  }
}

/// Web `.activity-payload`: Input / Output / Error panels of an expandable row (gap 7, padding
/// 2/8/10; 34 pt indent under a single row so the payload sits under the label, not the glyph).
public struct ActivityPayload<Content: View>: View {
  private let indented: Bool
  private let content: Content
  public init(indented: Bool = false, @ViewBuilder content: () -> Content) {
    self.indented = indented
    self.content = content()
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 7) { content }
      .padding(.top, 2).padding(.trailing, 8).padding(.bottom, 10)
      .padding(.leading, indented ? 34 : 8)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One labelled payload: an uppercase eyebrow over a wrapped, selectable mono block on
/// `app-bg 60% + surface` that caps at 280 pt and then scrolls inside itself.
public struct ActivityPayloadBlock: View {
  private let label: String
  private let text: String
  @State private var height: CGFloat?
  @Environment(\.consoleTheme) private var theme
  @Environment(\.webMaterial) private var material
  public init(_ label: String, text: String) {
    self.label = label
    self.text = text
  }
  private var display: String { String(decoding: text.utf8.prefix(16_384), as: UTF8.self) }
  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    VStack(alignment: .leading, spacing: 7) {
      Text(label).webFont(.payloadLabel).foregroundStyle(material.textMuted.color)
        .accessibilityAddTraits(.isHeader)
      ScrollView(.vertical) {
        Text(verbatim: display)
          .webFont(.payloadText)
          .foregroundStyle(WebColor.textSoft.color)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8).padding(.horizontal, 9)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            height = $0
          }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(height ?? 280, 280))
      .webLayeredSurface(
        shape, fill: theme.palette.canvas.mixed(60, with: WebColor.surface).color,
        stroke: WebColor.line.color
      )
      .accessibilityLabel(label + " payload")
      .accessibilityIdentifier("payload-" + label.lowercased())
      if text.utf8.count > 16_384 {
        Text("Display limited to 16,384 UTF-8 bytes.").webFont(.messageAction)
          .foregroundStyle(material.textMuted.color)
      }
    }
  }
}

/// Web `TruncationNotice`: "Preview only, 20,480 chars." with the one control that fetches the
/// rest as a quiet pill, and the failure said inline.
public struct ActivityTruncationNotice: View {
  public enum Phase: Sendable { case idle, loading, failed }
  private let characters: Int?
  private let loadTitle: String
  private let phase: Phase
  private let identifier: String
  private let action: (() -> Void)?
  public init(
    characters: Int?, loadTitle: String = "Load full output", phase: Phase,
    identifier: String = "tool-load-full", action: (() -> Void)?
  ) {
    self.characters = characters
    self.loadTitle = loadTitle
    self.phase = phase
    self.identifier = identifier
    self.action = action
  }
  public var body: some View {
    WebFlowLayout(spacing: 8, lineSpacing: 4) {
      Text(
        "Preview only"
          + (characters.map {
            ", " + $0.formatted(.number.locale(Locale(identifier: "en_US")))
              + " chars"
          } ?? "") + ".")
      if let action, phase != .loading {
        Button(loadTitle, action: action)
          .buttonStyle(.plain)
          .foregroundStyle(WebColor.textSoft.color)
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(WebColor.surfaceSubtle.color, in: Capsule())
          .overlay(Capsule().strokeBorder(WebColor.line.color, lineWidth: 1))
          .frame(minHeight: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
          .accessibilityIdentifier(identifier)
      }
      if phase == .loading { Text("Loading…") }
      if phase == .failed {
        Text("Could not load the full output.").foregroundStyle(WebColor.danger.color)
      }
    }
    .webFont(.activityMeta)
    .foregroundStyle(WebColor.textMuted.color)
  }
}

/// Web `.activity-error`: a prose failure (history not saved, aborted fetch) tinted danger.
public struct ActivityErrorNote: View {
  private let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.small, style: .continuous)
    Text(text).webFont(.activityMeta)
      .foregroundStyle(WebColor.danger.color)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 7).padding(.horizontal, 9)
      .background(WebColor.danger.color.opacity(0.08), in: shape)
      .overlay(shape.strokeBorder(WebColor.danger.color.opacity(0.25), lineWidth: 1))
  }
}

/// Web `.activity-thought`: the expanded thought, paragraphs at 12/1.6 muted, indented 34 pt.
public struct ActivityThought: View {
  private let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    let paragraphs = text.components(separatedBy: "\n\n").filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
        Text(verbatim: paragraph).webFont(.activityThought)
          .foregroundStyle(WebColor.textMuted.color)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 2).padding(.trailing, 12).padding(.bottom, 12).padding(.leading, 34)
  }
}

/// Web `.activity-note`: prose the turn wrote between its calls, the log's own soft voice.
public struct ActivityNote: View {
  private let text: String
  public init(_ text: String) { self.text = text }
  public var body: some View {
    Text(text).webFont(.activityNote).foregroundStyle(WebColor.textSoft.color)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Web `.activity-root`: a band of consecutive activity (reasoning, tools, delegations) in one
/// opaque panel (panel 32% into surface, 1 px line, radius 12) with an "ACTIVITY" header
/// (minH 44, P2/16/0) carrying the step count and, on the turn's open band, its clock. The label
/// is muted at rest and accent while the turn streams.
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
          Text("Activity").webFont(.activityLabel)
            .foregroundStyle(running ? theme.palette.accent.color : WebColor.textMuted.color)
            .fixedSize()
          Text(meta).font(.system(size: 10)).monospacedDigit()
            .foregroundStyle(WebColor.textMuted.color)
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
      .accessibilityLabel("Activity" + (running ? " in progress" : "") + ", " + meta)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier(identifier)
      if expanded {
        VStack(alignment: .leading, spacing: 2) { content() }
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
          ActivitySteps {
            ActivityStep("read_file", summary: "outline.md", duration: "0.4s") {
              ActivityPayload { ActivityPayloadBlock("Input", text: "{ \"path\": \"a.md\" }") }
            }
          }
        }
        ActivityDisclosure(
          "", summary: "Comparing the two sample outlines", glyph: .reasoning,
          expanded: .constant(false)
        ) { ActivityThought("Comparing.") }
      }
    }
  }
#endif
