// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Shared centred layout for empty, error and loading states. Content, not glass.
private struct StateLayout<Icon: View, Action: View>: View {
  let title: String
  let message: String?
  var isEmpty = false
  var isError = false
  @Environment(\.consoleTheme) private var theme
  @Environment(\.webMaterial) private var material
  @ViewBuilder let icon: () -> Icon
  @ViewBuilder let action: () -> Action

  var body: some View {
    VStack(spacing: 9) {
      icon()
        .font(.system(size: 24))
        .frame(width: 60, height: 60)
        .background(
          isError ? DesignColor.danger.color.opacity(0.1) : theme.palette.accentInk,
          in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
          if isEmpty {
            RoundedRectangle(cornerRadius: 20)
              .stroke(theme.palette.accent.color.opacity(0.18), lineWidth: 1)
              .rotationEffect(.degrees(-12))
              .accessibilityHidden(true)
          }
        }
        .padding(.bottom, 14)
        .accessibilityHidden(true)
      Text(title)
        .webFont(isEmpty ? .stateTitle : .stateStatusTitle)
        .foregroundStyle(WebColor.text.color)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      if let message {
        Text(message)
          .webFont(.stateBody)
          .foregroundStyle(material.textMuted.color)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      action()
    }
    .padding(.vertical, 32)
    .padding(.horizontal, 17)
    .frame(maxWidth: .infinity)
  }
}

public struct EmptyStateView: View {
  private let title: String
  private let systemImage: String
  private let message: String?
  private let actionTitle: String?
  private let action: (@MainActor () -> Void)?
  @Environment(\.consoleTheme) private var theme

  public init(
    _ title: String, systemImage: String, message: String? = nil,
    actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    StateLayout(title: title, message: message, isEmpty: true) {
      Image(systemName: systemImage).foregroundStyle(theme.palette.accent.color)
    } action: {
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(WebStateActionStyle()).padding(.top, 12)
      }
    }
  }
}

public struct ErrorStateView: View {
  private let title: String
  private let message: String?
  private let retryTitle: String?
  private let retry: (@MainActor () -> Void)?

  public init(
    _ title: String, message: String? = nil,
    retryTitle: String? = nil, retry: (@MainActor () -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.retryTitle = retryTitle
    self.retry = retry
  }

  public var body: some View {
    StateLayout(title: title, message: message, isError: true) {
      Image(systemName: StatusKind.failed.systemImage)
        .foregroundStyle(DesignColor.danger.color)
    } action: {
      if let retryTitle, let retry {
        Button(retryTitle, action: retry).buttonStyle(WebStateActionStyle()).padding(.top, 12)
      }
    }
  }
}

public struct LoadingStateView: View {
  private let title: String
  @Environment(\.consoleTheme) private var theme

  public init(_ title: String) { self.title = title }

  public var body: some View {
    StateLayout(title: title, message: nil) {
      ProgressView().tint(WebGlass.accentText(theme.palette).color)
    } action: {
      EmptyView()
    }
    .accessibilityElement(children: .combine)
  }
}

/// The web primary-button geometry for in-flow state actions. On a sheet, accent ink
/// sits on the existing material: no solid panel or second glass surface.
public struct WebStateActionStyle: ButtonStyle {
  @Environment(\.consoleTheme) private var theme
  @Environment(\.webMaterial) private var material
  @Environment(\.isEnabled) private var isEnabled

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .webFont(.quickReply)
      .fontWeight(.semibold)
      .foregroundStyle(
        material == .glass ? WebColor.text.color : theme.palette.onAccent.color
      )
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .background(
        material == .glass ? theme.palette.accentInk : theme.palette.accentStrong.color,
        in: RoundedRectangle(cornerRadius: WebRadius.tile)
      )
      .overlay {
        if material == .glass {
          RoundedRectangle(cornerRadius: WebRadius.tile)
            .stroke(theme.palette.accent.color.opacity(0.3), lineWidth: 1)
        }
      }
      .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.8 : 1)
  }
}

#if DEBUG
  #Preview("States — themes") {
    DesignPreviewMatrix {
      EmptyStateView(
        "No consoles yet", systemImage: "network", message: "Add a console to begin.",
        actionTitle: "Add console", action: {}
      )
      .contentSurface()
      ErrorStateView("Connection failed", message: "Could not reach the console.")
        .contentSurface()
      LoadingStateView("Checking console…").contentSurface()
    }
  }

  #Preview("States — dark, accessibility size") {
    DesignPreviewMatrix {
      ErrorStateView(
        "Connection failed", message: "Could not reach the console.",
        retryTitle: "Retry", retry: {}
      )
      .contentSurface()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
  }
#endif
