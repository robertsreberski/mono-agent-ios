// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// The conversation's background-job shelf in the composer dock, directly above the input
/// (web Chat.tsx `ProcessJobStack`). Collapsed it names the current jobs; expanded it scrolls
/// within a bounded height so the input stays reachable. It floats above the transcript, so it
/// is one Liquid Glass surface with translucent rows inside (GLASS-RULES.md).
struct ComposerJobDock: View {
  let state: ConversationState
  let store: ConsoleStore
  let onAnswer: (PeerProcessJobQuestion) -> Void
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.consoleTheme) private var theme

  @State private var contentHeight: CGFloat = 0

  var body: some View {
    if !state.jobItems.isEmpty {
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
      // Web `.process-job-stack` geometry (radius 13 on phones). It floats above the
      // transcript: one veiled glass surface keeps shelf text legible over code. Reduce
      // Transparency keeps the web stack-bg fill with its 1 px line-strong edge.
      .padding(.horizontal, 10)
      .webGlassContent()
      .background(
        WebGlass.sheetVeil.color,
        in: RoundedRectangle(cornerRadius: WebRadius.shelf, style: .continuous)
      )
      .floatingGlass(
        in: RoundedRectangle(cornerRadius: WebRadius.shelf, style: .continuous),
        opaqueFill: theme.palette.jobStackBackground.color,
        opaqueStroke: WebColor.lineStrong.color
      )
      // Light mode keeps the web 1 px line-strong edge as a stroke only (no fill); dark glass
      // already reads against the dark transcript.
      .overlay(
        RoundedRectangle(cornerRadius: WebRadius.shelf, style: .continuous)
          .strokeBorder(WebColor.lineStrong.color(lightOpacity: 1, darkOpacity: 0), lineWidth: 1)
      )
    }
  }
}

/// Pure glass, straddling the dock rather than floating over transcript prose. No extra bar.
/// The dock never makes room for it: the circle overlaps the first dock surface's top edge,
/// and only the visible circle is interactive below that edge (GLASS-RULES.md rule 10).
struct TranscriptJumpButton: View {
  /// The visible circle's height above the dock's top edge.
  static let aboveDock: CGFloat = 16
  /// Extra hit height above the circle, completing the 44 pt minimum target.
  static let reach = DesignMetrics.minimumHitTarget - WebMetrics.tile
  /// The button's top relative to the dock's top edge.
  static let mountOffset = -(aboveDock + reach)

  var sharesDockMaterial = false
  let jump: () -> Void
  var body: some View {
    Button(action: jump) {
      Label("Jump to latest", systemImage: "arrow.down")
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(WebColor.textSoft.color)
        .frame(width: WebMetrics.tile, height: WebMetrics.tile)
        .background {
          Circle().fill(.clear)
            .floatingGlass(in: Circle(), opaqueFill: WebColor.surfaceRaised.color)
            .mask(alignment: .top) {
              // Only the circle's upper 16 pt are above the dock. The full-width dock
              // surface supplies the lower 20 pt's single material.
              Rectangle().frame(height: sharesDockMaterial ? Self.aboveDock : WebMetrics.tile)
            }
        }
        .overlay {
          Circle().strokeBorder(
            WebColor.lineStrong.color(lightOpacity: 1, darkOpacity: 0), lineWidth: 1)
        }
        // 44 × 44: the circle sits at the bottom; the 8 pt above it is transcript-side reach.
        .padding(.top, Self.reach)
        .frame(width: DesignMetrics.minimumHitTarget, alignment: .bottom)
        .contentShape(
          JumpHitShape(diameter: WebMetrics.tile, dockEdge: Self.reach + Self.aboveDock))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Jump to latest")
    // VoiceOver activates the visible circle's centre, never the reach above it.
    .accessibilityActivationPoint(
      UnitPoint(
        x: 0.5,
        y: (Self.reach + WebMetrics.tile / 2) / DesignMetrics.minimumHitTarget)
    )
    .accessibilityIdentifier("jump-to-latest")
  }
}

/// Places Jump to latest over the conversation, straddling the dock's top edge. It is not
/// part of the dock's layout, so the dock never changes size when it appears.
struct TranscriptJumpOverlay: View {
  let control: TranscriptJumpControl
  var body: some View {
    GeometryReader { proxy in
      if control.available, let dock = control.dockFrame {
        let origin = proxy.frame(in: .global).origin
        TranscriptJumpButton(sharesDockMaterial: control.sharesDockMaterial) {
          control.jump?()
        }
        .position(
          x: dock.midX - origin.x,
          y: dock.minY - origin.y + TranscriptJumpButton.mountOffset
            + DesignMetrics.minimumHitTarget / 2)
      }
    }
    .ignoresSafeArea()
  }
}

/// The jump's hit region: the visible circle (bottom-centred), plus the full width above the
/// dock's top edge so the target stays at least 44 × 44. Below the edge, only the circle is
/// interactive, so taps beside it reach the dock's own rows.
struct JumpHitShape: Shape {
  let diameter: CGFloat
  /// The dock's top edge, measured from this shape's top.
  let dockEdge: CGFloat

  func path(in rect: CGRect) -> Path {
    let circle = CGRect(
      x: rect.midX - diameter / 2, y: rect.maxY - diameter, width: diameter, height: diameter)
    let above = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: dockEdge)
    return Path(above).union(Path(ellipseIn: circle))
  }
}

/// Context/cost beside the model and effort selector (web "Next turn settings" row). The
/// Design `ContextDisplay` label is the trigger; its full disclosure opens in a popover (iPad) or
/// sheet (iPhone) drawn directly on the system presentation material: no solid body or band.
struct ComposerContextControl: View {
  let state: ConversationState
  let store: ConsoleStore
  /// Single-line beside the selector; may wrap when it has its own line.
  var fixed = true
  @State private var open = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.webMaterial) private var material

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
          .foregroundStyle(material.textMuted.color)
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
    }
  }
  private var contextDetail: some View {
    VStack(spacing: 0) {
      WebSheetHeader("Context and cost") { open = false }
      ScrollView {
        ConversationContextView(state: state, store: store, expanded: true)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .webSheetVeil()
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
