// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Web `.message-quote`: opaque surface wash, a two-point accent rule and compact prose.
public struct MessageQuote: View {
  private let text: String
  @Environment(\.consoleTheme) private var theme
  public init(_ text: String) { self.text = text }
  public var body: some View {
    Text(text).webFont(.quote).foregroundStyle(WebColor.textSoft.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8).padding(.horizontal, 10)
      .background(WebColor.surface.color.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7)
          .fill(theme.palette.accent.color).frame(width: 2)
      }
      .textSelection(.enabled)
      .accessibilityLabel("Quote: " + text)
  }
}

/// Web `.reply-options`: wrapping neutral pills, never a glass content surface.
public struct WebReplyButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label.webFont(.quickReply).foregroundStyle(WebColor.text.color)
      .multilineTextAlignment(.leading).padding(.vertical, 8).padding(.horizontal, 14)
      .frame(minHeight: 44)
      .background(
        configuration.isPressed ? WebColor.surfaceHover.color : WebColor.surface.color,
        in: Capsule()
      )
      .overlay(Capsule().strokeBorder(WebColor.lineStrong.color, lineWidth: 1))
      .opacity(enabled ? 1 : 0.55)
  }
}

public struct WebSubmitButtonStyle: ButtonStyle {
  @Environment(\.consoleTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label.webFont(.effortOption).fontWeight(.bold)
      .foregroundStyle(theme.palette.onAccent.color)
      .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
      .background(
        configuration.isPressed ? theme.palette.accentStrong.color : theme.palette.accent.color,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(enabled ? 1 : 0.55)
  }
}

extension View {
  /// Web textarea/input: readable surface, line border, 9/10 padding and radius 8.
  public func webInput() -> some View {
    self.textFieldStyle(.plain).webFont(.search).foregroundStyle(WebColor.text.color)
      .padding(.vertical, 9).padding(.horizontal, 10)
      .webLayeredSurface(
        RoundedRectangle(cornerRadius: 8), fill: WebColor.surface.color,
        stroke: WebColor.line.color)
  }
  public func webFormCard() -> some View {
    self.padding(16)
      .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.lineStrong.color, lineWidth: 1)
      )
      .compositingGroup()
      .webShadow(.small)
  }
}

#if DEBUG
  #Preview("Answer surfaces") {
    DesignPreviewMatrix {
      VStack(alignment: .leading, spacing: 14) {
        MessageQuote("A fictional passage from the sample plan.")
        ChoiceRow("Reserve now", detail: "Keep a sample packet", selected: true, multiple: false)
        TextField("Custom reply", text: .constant("")).webInput()
        Button("Submit answer") {}.buttonStyle(WebSubmitButtonStyle())
        Button("Tell me more") {}.buttonStyle(WebReplyButtonStyle())
      }.webFormCard()
    }
  }
#endif
