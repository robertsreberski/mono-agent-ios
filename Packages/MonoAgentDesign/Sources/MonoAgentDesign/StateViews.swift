// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Shared centred layout for empty, error and loading states. Content, not glass.
private struct StateLayout<Icon: View, Action: View>: View {
  let title: String
  let message: String?
  @ViewBuilder let icon: () -> Icon
  @ViewBuilder let action: () -> Action

  var body: some View {
    VStack(spacing: 9) {
      icon()
        .font(.system(size: 24))
        .frame(width: 60, height: 60)
        .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 20))
        .padding(.bottom, 14)
        .accessibilityHidden(true)
      Text(title)
        .webFont(.stateTitle)
        .foregroundStyle(WebColor.text.color)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      if let message {
        Text(message)
          .webFont(.stateBody)
          .foregroundStyle(WebColor.textMuted.color)
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
    StateLayout(title: title, message: message) {
      Image(systemName: systemImage).foregroundStyle(theme.palette.accent.color)
    } action: {
      if let actionTitle, let action {
        Button(actionTitle, action: action).designButtonStyle(.primary).padding(.top)
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
    StateLayout(title: title, message: message) {
      Image(systemName: StatusKind.failed.systemImage)
        .foregroundStyle(DesignColor.danger.color)
    } action: {
      if let retryTitle, let retry {
        Button(retryTitle, action: retry).designButtonStyle(.primary).padding(.top)
      }
    }
  }
}

public struct LoadingStateView: View {
  private let title: String

  public init(_ title: String) { self.title = title }

  public var body: some View {
    StateLayout(title: title, message: nil) {
      ProgressView().controlSize(.large)
    } action: {
      EmptyView()
    }
    .accessibilityElement(children: .combine)
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
