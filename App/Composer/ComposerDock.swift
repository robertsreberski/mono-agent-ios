// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// The conversation's background-job shelf in the composer dock, directly above the input
/// (web Chat.tsx `ProcessJobStack`). Collapsed it names the current jobs; expanded it scrolls
/// within a bounded height so the input stays reachable. Content, so it sits on an opaque card.
struct ComposerJobDock: View {
  let state: ConversationState
  let store: ConsoleStore
  let onAnswer: (PeerProcessJobQuestion) -> Void
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  @State private var contentHeight: CGFloat = 0

  var body: some View {
    if !JobShelf.items(messages: state.messages).isEmpty {
      // One scroll view sized to its content up to a cap, so expanding never swaps the
      // shelf's view identity (and its disclosure state).
      ScrollView {
        ConversationJobStack(state: state, store: store, onAnswerPeerQuestion: onAnswer)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            contentHeight = $0
          }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(max(contentHeight, 1), verticalSizeClass == .compact ? 150 : 320))
      .accessibilityIdentifier("composer-dock-scroll")
      .contentSurface(padding: DesignSpacing.sm)
      .padding(.horizontal, DesignSpacing.md)
      .frame(maxWidth: DesignMetrics.readableWidth + 2 * DesignSpacing.md)
      .frame(maxWidth: .infinity)
    }
  }
}

/// Context/cost beside the model and effort selector (web "Next turn settings" row). The
/// Design `ContextDisplay` label is the trigger; its full disclosure opens in a popover so the
/// glass bar never carries dense content.
struct ComposerContextControl: View {
  let state: ConversationState
  let store: ConsoleStore
  /// Single-line beside the selector; may wrap when it has its own line.
  var fixed = true
  @State private var open = false

  var body: some View {
    ContextDisplay(
      ConversationContextView.content(state),
      // Never expands inline in the bar; the disclosure opens the popover instead.
      expanded: Binding(get: { false }, set: { if $0 { open = true } })
    )
    .fixedSize(horizontal: fixed, vertical: true)
    .popover(isPresented: $open) {
      ScrollView {
        ConversationContextView(state: state, store: store, expanded: true)
          .padding(DesignSpacing.lg)
      }
      .frame(minWidth: 300, idealWidth: 360, minHeight: 200, idealHeight: 360)
      .presentationCompactAdaptation(.popover)
    }
  }
}

/// A peer question presented from the job shelf's Answer action.
struct PeerQuestionPresentation: Identifiable {
  let question: PeerProcessJobQuestion
  var id: String { question.questionId }
}
