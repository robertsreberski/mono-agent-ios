// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// A staged or uploading attachment in the composer: thumbnail or file symbol, name, size or
/// progress, an error cue and an optional remove button. Value-driven; owns no upload state.
public struct AttachmentChip: View {
  public enum Phase: Equatable, Sendable {
    case uploading(Double)
    case ready
    case failed
  }
  private let name: String
  private let detail: String
  private let isImage: Bool
  private let thumbnail: Image?
  private let phase: Phase
  private let onRemove: (() -> Void)?
  @Environment(\.consoleTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(
    name: String, detail: String, isImage: Bool, thumbnail: Image? = nil, phase: Phase = .ready,
    onRemove: (() -> Void)? = nil
  ) {
    self.name = name
    self.detail = detail
    self.isImage = isImage
    self.thumbnail = thumbnail
    self.phase = phase
    self.onRemove = onRemove
  }

  public static func accessibilityLabel(name: String, detail: String, phase: Phase) -> String {
    switch phase {
    case .uploading(let fraction):
      "\(name), uploading, \(Int((min(1, max(0, fraction)) * 100).rounded())) percent"
    case .ready: "\(name), \(detail), attached"
    case .failed: "\(name), upload failed"
    }
  }

  /// Web `.attachment-chip`: 34 pt high, ≤ 250 pt wide, radius 9, 1 px line on raised;
  /// a 20 pt icon tile, the name in 11 pt and the size or progress beside it.
  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
    HStack(spacing: 7) {
      preview
      VStack(alignment: .leading, spacing: 1) {
        Text(name).webFont(.attachment).foregroundStyle(WebColor.text.color)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
        status
      }
      if let onRemove {
        Button("Remove \(name)", systemImage: "xmark", action: onRemove)
          .labelStyle(.iconOnly)
          .font(.system(size: 10, weight: .semibold))
          .buttonStyle(.borderless)
          .foregroundStyle(WebColor.textMuted.color)
          .frame(minWidth: 24, minHeight: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, onRemove == nil ? 8 : 2)
    .frame(maxWidth: typeSize.isAccessibilitySize ? nil : 250, minHeight: 34, alignment: .leading)
    .background(WebColor.surfaceRaised.color, in: shape)
    .overlay {
      shape.strokeBorder(
        phase == .failed ? WebColor.danger.color : WebColor.line.color, lineWidth: 1)
    }
    .overlay(alignment: .bottomLeading) {
      if case .uploading(let fraction) = phase {
        GeometryReader { proxy in
          Rectangle().fill(theme.palette.accent.color)
            .frame(width: proxy.size.width * min(1, max(0, fraction)), height: 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(shape)
        .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.accessibilityLabel(name: name, detail: detail, phase: phase))
  }

  @ViewBuilder private var preview: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Group {
      if let thumbnail {
        thumbnail.resizable().scaledToFill()
      } else {
        Image(systemName: isImage ? "photo" : "doc")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(theme.palette.accent.color)
      }
    }
    .frame(width: 20, height: 20)
    .background(theme.palette.accentSoft.color)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var status: some View {
    switch phase {
    case .uploading(let fraction):
      Text("Uploading \(Int((min(1, max(0, fraction)) * 100).rounded()))%")
        .font(.system(size: 9)).foregroundStyle(WebColor.textMuted.color)
    case .ready:
      if !detail.isEmpty {
        Text(detail).font(.system(size: 9)).foregroundStyle(WebColor.textMuted.color)
      }
    case .failed:
      Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 9)).foregroundStyle(DesignColor.danger.color)
    }
  }
}

/// One row of an inline suggestion list (skills, commands) or a browse sheet.
public struct SuggestionRow: View {
  private let title: String
  private let subtitle: String?
  private let badge: String?
  private let systemImage: String
  private let highlighted: Bool
  private let enabled: Bool
  @Environment(\.consoleTheme) private var theme

  public init(
    _ title: String, subtitle: String? = nil, badge: String? = nil,
    systemImage: String = "book.closed", highlighted: Bool = false, enabled: Bool = true
  ) {
    self.title = title
    self.subtitle = subtitle
    self.badge = badge
    self.systemImage = systemImage
    self.highlighted = highlighted
    self.enabled = enabled
  }

  /// Web `.composer-trigger-item`: 49 pt, radius 9, a 30 pt accent-soft icon tile, the name
  /// in 11.5/680 and a one-line 9.5 pt description; the highlighted row is subtle-filled.
  public var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(theme.palette.accent.color)
        .frame(width: 30, height: 30)
        .background(theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).webFont(.triggerTitle)
          .foregroundStyle(highlighted ? WebColor.text.color : WebColor.textSoft.color)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle).webFont(.triggerDetail).foregroundStyle(WebColor.textMuted.color)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let badge {
        Text(badge)
          .font(.system(size: 8.5, weight: .semibold)).tracking(0.17)
          .foregroundStyle(WebColor.textMuted.color)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(WebColor.surfaceSubtle.color, in: Capsule())
          .overlay(Capsule().strokeBorder(WebColor.line.color, lineWidth: 1))
      }
    }
    .opacity(enabled ? 1 : 0.58)
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
    .background(
      highlighted ? WebColor.surfaceSubtle.color : .clear,
      in: RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(highlighted ? [.isSelected] : [])
  }
}

/// The quote attached to a message being written (web `ComposerQuotePreview`) or shown on a
/// sent message. Content, not glass: it sits inside the composer field slot as a plain block.
public struct QuotePreview: View {
  private let text: String
  private let onDismiss: (() -> Void)?
  @Environment(\.consoleTheme) private var theme

  public init(_ text: String, onDismiss: (() -> Void)? = nil) {
    self.text = text
    self.onDismiss = onDismiss
  }

  public var body: some View {
    // Web `.composer-quote`: 38 pt, radius 7, surface-hover, a 2 pt accent rule, 11 pt text.
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "quote.opening").font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.palette.accent.color)
        .accessibilityHidden(true)
      Text(text).font(.system(size: 11)).foregroundStyle(WebColor.textMuted.color).lineLimit(3)
      Spacer(minLength: 0)
      if let onDismiss {
        Button("Remove quote", systemImage: "xmark", action: onDismiss)
          .labelStyle(.iconOnly).font(.system(size: 10, weight: .semibold))
          .buttonStyle(.borderless).foregroundStyle(WebColor.textMuted.color)
          .frame(minWidth: 26, minHeight: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, 10).padding(.trailing, 8)
    .frame(minHeight: 38)
    .background(WebColor.surfaceHover.color, in: RoundedRectangle(cornerRadius: 7))
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7)
        .fill(theme.palette.accent.color).frame(width: 2)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Quote: " + text)
  }
}

/// An option in a question form: radio (single) or checkbox (multiple) with a label and a
/// description. The selected state is a symbol and a trait, never only a colour.
public struct ChoiceRow: View {
  private let label: String
  private let detail: String?
  private let selected: Bool
  private let multiple: Bool
  @Environment(\.consoleTheme) private var theme

  public init(_ label: String, detail: String? = nil, selected: Bool, multiple: Bool) {
    self.label = label
    self.detail = detail
    self.selected = selected
    self.multiple = multiple
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
      Image(
        systemName: multiple
          ? (selected ? "checkmark.square.fill" : "square")
          : (selected ? "largecircle.fill.circle" : "circle")
      )
      .foregroundStyle(selected ? theme.palette.accent.color : .secondary)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(label).designFont(.body).foregroundStyle(.primary)
        if let detail, !detail.isEmpty {
          Text(detail).designFont(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(DesignSpacing.sm)
    .frame(maxWidth: .infinity, minHeight: DesignMetrics.minimumHitTarget, alignment: .leading)
    .background(
      selected ? theme.palette.accentSoft.color : DesignColor.contentSurface,
      in: RoundedRectangle(cornerRadius: DesignRadius.sm)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DesignRadius.sm).stroke(
        selected ? theme.palette.accent.color : DesignColor.separator,
        lineWidth: selected ? 1.5 : 0.5)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
  }
}

#if DEBUG
  private struct ComposerComponentSamples: View {
    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        QuotePreview("The sample is ready. Two checks passed; one fictional file needs attention.")
        {}
        HStack {
          AttachmentChip(name: "field-notes.txt", detail: "1 KB", isImage: false) {}
          AttachmentChip(
            name: "sample-photo.png", detail: "", isImage: true, phase: .uploading(0.6))
        }
        AttachmentChip(name: "too-large.pdf", detail: "", isImage: false, phase: .failed) {}
        SuggestionRow(
          "$release-notes", subtitle: "Draft release notes from the sample changelog",
          badge: "On demand", highlighted: true)
        SuggestionRow("$weekly-digest", subtitle: "Summarise a fictional week", badge: "In prompt")
        ChoiceRow("Ship it", detail: "Publish the sample today", selected: true, multiple: false)
        ChoiceRow("Hold", detail: "Wait for review", selected: false, multiple: true)
      }
      .contentSurface()
    }
  }

  #Preview("Composer components — themes") { DesignPreviewMatrix { ComposerComponentSamples() } }

  #Preview("Composer components — dark, AX") {
    DesignPreviewMatrix { ComposerComponentSamples() }
      .preferredColorScheme(.dark)
      .dynamicTypeSize(.accessibility3)
  }
#endif
