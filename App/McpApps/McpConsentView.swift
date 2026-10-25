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
  @ObservationIgnored var presentationAvailable: (@MainActor () -> Bool)?
  @ObservationIgnored private var presentationDeadline: Task<Void, Never>?
  private let presentationTimeout: Duration
  init(presentationTimeout: Duration = .seconds(1)) {
    self.presentationTimeout = presentationTimeout
  }
  @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var dismissing = false
  private var presentedID: UUID?
  var isPresented: Bool { presentedID != nil && presentedID == request?.id }
  @ObservationIgnored private var returnFocus: Any?
  func confirm(_ prompt: McpConsentPrompt, requestID: UUID) async -> Bool {
    guard request == nil, !dismissing, presentationAvailable?() != false else { return false }
    returnFocus = UIAccessibility.focusedElement(using: .notificationVoiceOver)
    request = Request(id: requestID, prompt: prompt)
    presentationDeadline = Task { [weak self, presentationTimeout] in
      try? await Task.sleep(for: presentationTimeout)
      guard !Task.isCancelled, let self, self.presentedID != requestID else { return }
      self.settle(requestID, allowed: false)
    }
    return await withCheckedContinuation { continuation = $0 }
  }
  func settle(_ id: UUID, allowed: Bool) {
    guard request?.id == id else { return }
    presentationDeadline?.cancel()
    presentationDeadline = nil
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
    guard request?.id == requestID, presentedID != requestID else { return }
    presentedID = requestID
    presentationDeadline?.cancel()
    presentationDeadline = nil
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
  isolated deinit {
    presentationDeadline?.cancel()
    continuation?.resume(returning: false)
  }
}

/// Only a visible native prompt makes the underlying transcript inert. A blocked sibling
/// presentation is bounded by the presenter's deadline and returns the ordinary decline.
struct McpConsentPresentation: ViewModifier {
  let presenter: McpNativeConsent
  func body(content: Content) -> some View {
    content
      .allowsHitTesting(!presenter.isPresented)
      .accessibilityHidden(presenter.isPresented)
      .background {
        McpConsentAnchor(presenter: presenter).frame(width: 1, height: 1).accessibilityHidden(true)
      }
      .sheet(
        item: Binding(get: { presenter.request }, set: { if $0 == nil { presenter.dismiss() } }),
        onDismiss: { presenter.didDismiss() },
        content: { request in McpConsentView(request: request, presenter: presenter) }
      )
  }
}

struct McpConsentView: View {
  let request: McpNativeConsent.Request
  let presenter: McpNativeConsent
  @Environment(\.consoleTheme) private var theme
  @AccessibilityFocusState private var titleFocused: Bool
  private var linkHost: String? {
    request.prompt.method == "ui/open-link" ? URL(string: request.prompt.detail)?.host : nil
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(request.prompt.title).webFont(.sheetTitle)
          .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
        Text(request.prompt.method).webFont(.optionID)
          .foregroundStyle(WebGlass.accentText(theme.palette).color)
        if let linkHost {
          Text(linkHost).webFont(.sheetTitle).foregroundStyle(WebColor.text.color)
            .accessibilityLabel("Destination host: " + linkHost)
            .accessibilityIdentifier("mcp-consent-host")
          Text(request.prompt.detail).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
            .lineLimit(3).truncationMode(.middle)
            .accessibilityLabel("Full URL: " + request.prompt.detail)
            .accessibilityIdentifier("mcp-consent-url")
        } else {
          Text(request.prompt.detail).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let preview = request.prompt.argumentPreview {
          Text(preview).webFont(.optionID).frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .webGlassGroup(cornerRadius: 7)
            .accessibilityIdentifier("mcp-consent-preview")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
    // One material: the system sheet background, actions in a bottom bar with the system
    // scroll-edge effect; secondary `.glass`, primary `.glassProminent` in the web accent.
    .safeAreaBar(edge: .bottom) {
      GlassEffectContainer(spacing: 8) {
        HStack {
          Spacer()
          Button("Cancel") { presenter.settle(request.id, allowed: false) }
            .designButtonStyle(.secondary, placement: .floating)
            .accessibilityIdentifier("mcp-consent-cancel")
          Button("Allow once") { presenter.settle(request.id, allowed: true) }
            .designButtonStyle(.primary, placement: .floating)
            .accessibilityIdentifier("mcp-consent-allow")
        }
      }
      .controlSize(.large).padding(18)
    }
    .foregroundStyle(WebColor.text.color)
    // Consent over arbitrary app content takes the stronger veil (GLASS-RULES.md; the web
    // confirmation is raised 96% over a blurred frame), so accent text keeps AA too.
    .webSheetVeil(.consent)
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mcp-consent")
    .background {
      McpConsentVisibilityProbe { presenter.didPresent(requestID: request.id) }
        .frame(width: 1, height: 1).accessibilityHidden(true)
    }
    .task { titleFocused = true }
  }
}

/// SwiftUI onAppear can run while UIKit refuses a sibling presentation. Only an
/// actually attached native view acknowledges presentation and cancels the deadline.
private struct McpConsentVisibilityProbe: UIViewRepresentable {
  let visible: @MainActor () -> Void
  func makeUIView(context: Context) -> McpConsentProbeView {
    let view = McpConsentProbeView()
    view.visible = visible
    return view
  }
  func updateUIView(_ view: McpConsentProbeView, context: Context) {
    view.visible = visible
    view.checkVisibility()
  }
}
private final class McpConsentProbeView: UIView {
  var visible: (@MainActor () -> Void)?
  override func didMoveToWindow() {
    super.didMoveToWindow()
    checkVisibility()
  }
  func checkVisibility() {
    guard window != nil else { return }
    Task { @MainActor [weak self] in
      guard let self, self.window != nil else { return }
      self.visible?()
    }
  }
}

/// Reject an already occupied presentation anchor before asking SwiftUI to present.
/// This also avoids dismissing an unrelated sibling sheet when a refused item clears.
private struct McpConsentAnchor: UIViewRepresentable {
  let presenter: McpNativeConsent
  func makeUIView(context: Context) -> UIView { UIView() }
  func updateUIView(_ view: UIView, context: Context) {
    presenter.presentationAvailable = { [weak view] in
      guard let root = view?.window?.rootViewController else { return false }
      func occupied(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: occupied)
      }
      return !occupied(root)
    }
  }
}
