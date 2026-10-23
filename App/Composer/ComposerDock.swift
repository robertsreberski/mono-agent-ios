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
  @Environment(\.consoleTheme) private var theme

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
      .frame(height: min(max(contentHeight, 1), verticalSizeClass == .compact ? 150 : 300))
      .accessibilityIdentifier("composer-dock-scroll")
      // Web `.process-job-stack`: stack-bg (panel 55% + surface), 1 px line-strong, radius 13
      // on phones (14 tablet), shadow-sm. It floats above the transcript: tinted glass.
      .padding(.horizontal, 10)
      .floatingGlass(
        in: RoundedRectangle(cornerRadius: WebRadius.shelf, style: .continuous),
        tint: theme.palette.jobStackBackground.color.opacity(0.6),
        opaqueFill: theme.palette.jobStackBackground.color
      )
      .overlay(
        RoundedRectangle(cornerRadius: WebRadius.shelf, style: .continuous)
          .strokeBorder(WebColor.lineStrong.color, lineWidth: 1)
      )
      .webShadow(.small)
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
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    let content = ConversationContextView.content(state)
    // Web `.context-display-trigger`: mono 9 pt ring + percent, transparent, 32 pt high. The
    // full disclosure opens in a popover so the bar never carries dense content.
    Button {
      open = true
    } label: {
      HStack(spacing: 5) {
        ContextRing(percent: content.percent)
        Text(content.percent == nil ? "–" : content.badge)
          .webFont(.contextTrigger).fontWeight(.bold)
          .foregroundStyle(WebColor.textMuted.color)
          .lineLimit(fixed ? 1 : 2)
      }
      .padding(.horizontal, 7)
      .frame(minHeight: WebMetrics.quietControl)
      .frame(minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize(horizontal: fixed, vertical: true)
    .accessibilityLabel("Context usage: " + content.figure + ". " + content.status)
    .accessibilityHint("Shows context and cost details")
    .accessibilityIdentifier("context-display")
    .popover(isPresented: Binding(get: { open && sizeClass == .regular }, set: { open = $0 })) {
      contextDetail.frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }
    .sheet(isPresented: Binding(get: { open && sizeClass != .regular }, set: { open = $0 })) {
      contextDetail
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(20)
    }
  }
  private var contextDetail: some View {
    VStack(spacing: 0) {
      WebSheetHeader("Context and cost") { open = false }
      ScrollView {
        ConversationContextView(state: state, store: store, expanded: true)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(WebColor.surfaceRaised.color)
    }

  }
}

/// The context trigger's 14 pt ring: dotted when usage is unknown, filled to the percent.
struct ContextRing: View {
  let percent: Double?
  @Environment(\.consoleTheme) private var theme
  var body: some View {
    ZStack {
      Circle().stroke(
        WebColor.lineStrong.color,
        style: StrokeStyle(lineWidth: 1.5, dash: percent == nil ? [1.5, 2] : []))
      if let percent, percent.isFinite {
        Circle().trim(from: 0, to: min(1, max(0, percent / 100)))
          .stroke(
            percent >= 85 ? WebColor.danger.color : theme.palette.accent.color,
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: 14, height: 14)
    .accessibilityHidden(true)
  }
}

/// A peer question presented from the job shelf's Answer action.
struct PeerQuestionPresentation: Identifiable {
  let question: PeerProcessJobQuestion
  var id: String { question.questionId }
}
