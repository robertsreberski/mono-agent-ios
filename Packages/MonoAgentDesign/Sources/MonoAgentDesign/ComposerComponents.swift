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

  public var body: some View {
    HStack(spacing: DesignSpacing.sm) {
      preview
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(name).designFont(.supporting).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
        status
      }
      if let onRemove {
        Button("Remove \(name)", systemImage: "xmark.circle.fill", action: onRemove)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .frame(
            minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget
          )
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, DesignSpacing.xs)
    .padding(.vertical, DesignSpacing.xxs)
    .background(DesignColor.contentSurface, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
    .overlay {
      if phase == .failed {
        RoundedRectangle(cornerRadius: DesignRadius.sm).stroke(
          DesignColor.danger.color, lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.accessibilityLabel(name: name, detail: detail, phase: phase))
  }

  @ViewBuilder private var preview: some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.sm - 2, style: .continuous)
    Group {
      if let thumbnail {
        thumbnail.resizable().scaledToFill()
      } else {
        Image(systemName: isImage ? "photo" : "doc")
          .foregroundStyle(theme.palette.accent.color)
      }
    }
    .frame(width: 36, height: 36)
    .background(theme.palette.accentSoft.color)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var status: some View {
    switch phase {
    case .uploading(let fraction):
      ProgressView(value: min(1, max(0, fraction)))
        .frame(maxWidth: 120)
        .tint(theme.palette.accent.color)
    case .ready:
      Text(detail).designFont(.caption).foregroundStyle(.secondary)
    case .failed:
      Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
        .designFont(.caption).foregroundStyle(DesignColor.danger.color)
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

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
      Image(systemName: systemImage).foregroundStyle(theme.palette.accent.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(title).designFont(.headline).foregroundStyle(enabled ? .primary : .secondary)
        if let subtitle {
          Text(subtitle).designFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: DesignSpacing.sm)
      if let badge {
        Text(badge).designFont(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, DesignSpacing.xs)
          .background(DesignColor.separator.opacity(0.4), in: Capsule())
      }
    }
    .padding(.vertical, DesignSpacing.xs)
    .padding(.horizontal, DesignSpacing.sm)
    .frame(maxWidth: .infinity, minHeight: DesignMetrics.minimumHitTarget, alignment: .leading)
    .background(
      highlighted ? theme.palette.accentSoft.color : .clear,
      in: RoundedRectangle(cornerRadius: DesignRadius.sm)
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
    HStack(alignment: .top, spacing: DesignSpacing.sm) {
      Rectangle().fill(theme.palette.accent.color).frame(width: 3)
        .accessibilityHidden(true)
      Label {
        Text(text).designFont(.supporting).foregroundStyle(.secondary).lineLimit(3)
      } icon: {
        Image(systemName: "quote.opening").foregroundStyle(theme.palette.accent.color)
      }
      Spacer(minLength: 0)
      if let onDismiss {
        Button("Remove quote", systemImage: "xmark", action: onDismiss)
          .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
          .frame(
            minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget)
      }
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
