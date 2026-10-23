// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// A full-width notice inside content: insecure HTTP, offline, storage, a refresh problem or
/// trust guidance.
/// Opaque by design; banners carry reading text, so they are never glass.
public struct ConnectionBanner: View {
  public enum Kind: CaseIterable, Sendable {
    case insecureHTTP
    case offline
    case storage
    /// A read or refresh failed; the content shown may be out of date.
    case problem
    case notice

    public var tone: StatusTone {
      switch self {
      case .insecureHTTP, .storage, .problem: .warning
      case .offline: .neutral
      case .notice: .accent
      }
    }

    public var systemImage: String {
      switch self {
      case .insecureHTTP: StatusKind.insecure.systemImage
      case .offline: StatusKind.offline.systemImage
      case .storage: "externaldrive.badge.exclamationmark"
      case .problem: "exclamationmark.arrow.circlepath"
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
  @Environment(\.horizontalSizeClass) private var sizeClass

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
    // At accessibility sizes the icon moves above the text so lines keep their full width.
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.sm))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    layout {
      Image(systemName: kind.systemImage)
        .foregroundStyle(tone)
        .webFont(.banner)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        Text(title).webFont(sizeClass == .regular ? .bannerRegular : .banner).fontWeight(.semibold)
          .foregroundStyle(WebColor.text.color)
          .fixedSize(horizontal: false, vertical: true)
        if let message {
          Text(message).webFont(sizeClass == .regular ? .bannerRegular : .banner).foregroundStyle(
            WebColor.textSoft.color
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        if let actionTitle, let action {
          Button(actionTitle, action: action)
            .buttonStyle(WebReplyButtonStyle())
            .controlSize(.small)
            .padding(.top, DesignSpacing.xs)
        }
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 16)
    .frame(minHeight: 34)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.palette.panel.color.overlay(tone.opacity(0.09)))
    .overlay(alignment: .bottom) {
      Rectangle().fill(tone.opacity(contrast == .increased ? 1 : 0.25)).frame(height: 1)
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
      ConnectionBanner(
        .problem, title: "Conversation list could not be refreshed.", actionTitle: "Retry",
        action: {})
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
  }
#endif
