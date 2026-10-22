// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// A full-width notice inside content: insecure HTTP, offline, storage or trust guidance.
/// Opaque by design; banners carry reading text, so they are never glass.
public struct ConnectionBanner: View {
  public enum Kind: CaseIterable, Sendable {
    case insecureHTTP
    case offline
    case storage
    case notice

    public var tone: StatusTone {
      switch self {
      case .insecureHTTP, .storage: .warning
      case .offline: .neutral
      case .notice: .accent
      }
    }

    public var systemImage: String {
      switch self {
      case .insecureHTTP: StatusKind.insecure.systemImage
      case .offline: StatusKind.offline.systemImage
      case .storage: "externaldrive.badge.exclamationmark"
      case .notice: "lock.shield"
      }
    }
  }

  private let kind: Kind
  private let title: String
  private let message: String?
  private let actionTitle: String?
  private let action: (@MainActor () -> Void)?
  @Environment(\.consoleTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(
    _ kind: Kind, title: String, message: String? = nil,
    actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil
  ) {
    self.kind = kind
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    let tone = kind.tone.color(in: theme).color
    let shape = RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
    // At accessibility sizes the icon moves above the text so lines keep their full width.
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.sm))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DesignSpacing.md))
    layout {
      Image(systemName: kind.systemImage)
        .foregroundStyle(tone)
        .designFont(.headline)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        Text(title).designFont(.sectionTitle).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let message {
          Text(message).designFont(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let actionTitle, let action {
          Button(actionTitle, action: action)
            .designButtonStyle(.secondary)
            .controlSize(.small)
            .padding(.top, DesignSpacing.xs)
        }
      }
    }
    .padding(DesignSpacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      shape.fill(DesignColor.contentSurface)
        .overlay(shape.fill(tone.opacity(DesignColor.toneFillOpacity)))
    }
    .overlay {
      shape.strokeBorder(
        tone.opacity(contrast == .increased ? 1 : 0.35),
        lineWidth: contrast == .increased ? 1.5 : 0.5)
    }
    .accessibilityElement(children: action == nil ? .combine : .contain)
  }
}

#if DEBUG
  #Preview("Banners — themes") {
    DesignPreviewMatrix {
      ConnectionBanner(
        .insecureHTTP, title: "Insecure HTTP",
        message: "Traffic can be read or changed on the network.")
      ConnectionBanner(
        .offline, title: "Offline", message: "Showing saved data.",
        actionTitle: "Retry", action: {})
    }
  }

  #Preview("Banners — dark, accessibility size") {
    DesignPreviewMatrix {
      ConnectionBanner(.storage, title: "Storage warning", message: "Changes are in memory only.")
      ConnectionBanner(.notice, title: "Trusted networks only")
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
  }
#endif
