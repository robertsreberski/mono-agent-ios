// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI
import UIKit

/// What transcript surfaces may ask of the visible composer: quote a message, send a suggested
/// reply, or insert a drafted block (peer replies). Absent outside a conversation screen.
struct ComposerActions {
  var quote: (@MainActor (WebQuote) -> Void)?
  var sendReply: (@MainActor (String) async -> Bool)?
  var insert: (@MainActor (String) -> Void)?
  /// The thread the composer belongs to, so a reply for another conversation stays inert.
  var threadID: String?
}

extension EnvironmentValues {
  @Entry var composerActions = ComposerActions()
  /// Navigation for the `/new` command, provided by the dashboard shell.
  @Entry var openNewConversation = NewConversationAction()
}

/// Opens a new conversation for an agent. Navigation is owned by the dashboard shell.
struct NewConversationAction {
  var open: (@MainActor (String) -> Void)?
}

extension View {
  /// Mounts the composer on a conversation destination with `.safeAreaBar(edge: .bottom)` and
  /// exposes `ComposerActions` to the transcript beneath it.
  func conversationComposer(
    store: ConsoleStore, route: AppRoute, createdThreadID: Binding<String?>,
    sampleAttachments: Bool = false
  ) -> some View {
    modifier(
      ConversationComposerMount(
        store: store, route: route, createdThreadID: createdThreadID,
        sampleAttachments: sampleAttachments))
  }

  /// The minimal transcript hook: a "Quote" context menu, VoiceOver action and a native
  /// text-selection sheet for one message.
  func quotable(_ message: WebMessage) -> some View {
    modifier(QuotableMessage(message: message))
  }
}

private struct ConversationComposerMount: ViewModifier {
  let store: ConsoleStore
  let route: AppRoute
  @Binding var createdThreadID: String?
  let sampleAttachments: Bool
  @State private var controller: ComposerController?
  @Environment(\.openNewConversation) private var openNewConversation

  func body(content: Content) -> some View {
    content
      .environment(\.composerActions, actions)
      .safeAreaBar(edge: .bottom) {
        if let controller {
          ComposerBar(controller: controller)
            .environment(\.composerSampleAttachments, sampleAttachments)
        }
      }
      .task(id: route) {
        guard let source = route.sourceID else { return }
        let next = ComposerController(store: store, sourceID: source, threadID: route.threadID)
        next.onCreate = { createdThreadID = $0 }
        next.onNewConversation = { openNewConversation.open?(source) }
        controller = next
      }
      .onChange(of: store.hydrated) { _, hydrated in
        if hydrated, controller?.text.isEmpty == true { controller?.restoreDraft() }
      }
  }

  private var actions: ComposerActions {
    guard let controller else { return ComposerActions() }
    return ComposerActions(
      quote: { controller.setQuote($0) },
      sendReply: { await controller.sendReply($0) },
      insert: { controller.insertBlock($0) },
      threadID: controller.threadID)
  }
}

private struct QuotableMessage: ViewModifier {
  let message: WebMessage
  @Environment(\.composerActions) private var actions
  @State private var selecting = false

  func body(content: Content) -> some View {
    let quote = QuoteFormatting.quote(message: message)
    if let quote, let action = actions.quote, actions.threadID == message.threadId {
      content
        .contextMenu {
          Button("Quote", systemImage: "quote.opening") { action(quote) }
            .accessibilityIdentifier("quote-message")
          Button("Quote Selection…", systemImage: "text.cursor") { selecting = true }
          Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = QuoteFormatting.text(of: message)
          }
        }
        .accessibilityAction(named: "Quote") { action(quote) }
        .sheet(isPresented: $selecting) {
          QuoteSelectionSheet(text: QuoteFormatting.text(of: message)) { selected in
            if let value = QuoteFormatting.quote(selected, messageID: message.id) { action(value) }
          }
        }
    } else {
      content
    }
  }
}

/// Native text selection for quoting part of a message (web SelectionToolbar "Quote").
struct QuoteSelectionSheet: View {
  let text: String
  let onQuote: (String) -> Void
  @State private var selected = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      SelectableText(text: text, selected: $selected)
        .padding(.horizontal, DesignSpacing.md)
        .navigationTitle("Select text to quote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Quote") {
              onQuote(selected.isEmpty ? text : selected)
              dismiss()
            }
            .accessibilityHint(
              selected.isEmpty ? "Quotes the whole message" : "Quotes the selected text")
          }
        }
    }
    .presentationDetents([.medium, .large])
  }
}

/// A read-only, selectable text view that reports the operator's selection.
private struct SelectableText: UIViewRepresentable {
  let text: String
  @Binding var selected: String

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = true
    view.adjustsFontForContentSizeCategory = true
    view.font = .preferredFont(forTextStyle: .body)
    view.backgroundColor = .clear
    view.delegate = context.coordinator
    view.text = text
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    if view.text != text { view.text = text }
  }
  func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var selected: Binding<String>
    init(selected: Binding<String>) { self.selected = selected }
    func textViewDidChangeSelection(_ view: UITextView) {
      guard let range = view.selectedTextRange else { return }
      selected.wrappedValue = view.text(in: range) ?? ""
    }
  }
}
