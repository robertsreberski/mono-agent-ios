// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class McpNativeConsent: McpConsentPresenting {
  struct Request: Identifiable {
    let id: UUID
    let prompt: McpConsentPrompt
  }
  private(set) var request: Request?
  @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var dismissing = false
  private var presentedID: UUID?
  var isPresented: Bool { presentedID != nil }
  @ObservationIgnored private var returnFocus: Any?
  func confirm(_ prompt: McpConsentPrompt, requestID: UUID) async -> Bool {
    guard request == nil, !dismissing else { return false }
    returnFocus = UIAccessibility.focusedElement(using: .notificationVoiceOver)
    request = Request(id: requestID, prompt: prompt)
    return await withCheckedContinuation { continuation = $0 }
  }
  func settle(_ id: UUID, allowed: Bool) {
    guard request?.id == id else { return }
    request = nil
    dismissing = presentedID == id
    if !dismissing { returnFocus = nil }
    let saved = continuation
    continuation = nil
    saved?.resume(returning: allowed)
  }
  func cancel(requestID: UUID) { settle(requestID, allowed: false) }
  func dismiss() { if let request { settle(request.id, allowed: false) } }
  func didPresent(requestID: UUID) {
    guard request?.id == requestID else { return }
    presentedID = requestID
  }
  func didDismiss() {
    guard dismissing, let presentedID else { return }
    didDismiss(requestID: presentedID)
  }
  func didDismiss(requestID: UUID) {
    guard presentedID == requestID else { return }
    cancel(requestID: requestID)
    presentedID = nil
    dismissing = false
    if let returnFocus { UIAccessibility.post(notification: .layoutChanged, argument: returnFocus) }
    returnFocus = nil
  }
  isolated deinit { continuation?.resume(returning: false) }
}

struct McpConsentView: View {
  let request: McpNativeConsent.Request
  let presenter: McpNativeConsent
  @Environment(\.consoleTheme) private var theme
  @AccessibilityFocusState private var titleFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(request.prompt.title).webFont(.sheetTitle)
        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
      Text(request.prompt.method).webFont(.optionID).foregroundStyle(theme.palette.accent.color)
      Text(request.prompt.detail).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
        .fixedSize(horizontal: false, vertical: true)
      if let preview = request.prompt.argumentPreview {
        ScrollView {
          Text(preview).webFont(.optionID).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150).padding(10)
        .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(WebColor.line.color))
        .accessibilityIdentifier("mcp-consent-preview")
      }
      HStack {
        Spacer()
        Button("Cancel") { presenter.settle(request.id, allowed: false) }
          .accessibilityIdentifier("mcp-consent-cancel")
        Button {
          presenter.settle(request.id, allowed: true)
        } label: {
          Text("Allow once").foregroundStyle(theme.palette.onAccent.color)
        }
        .accessibilityIdentifier("mcp-consent-allow")
        .buttonStyle(.borderedProminent).tint(theme.palette.accentStrong.color)
      }
      .buttonStyle(.bordered).controlSize(.large)
    }
    .foregroundStyle(WebColor.text.color).padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .presentationBackground(WebColor.surfaceRaised.color)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mcp-consent")
    .onAppear { presenter.didPresent(requestID: request.id) }
    .task { titleFocused = true }
  }
}
