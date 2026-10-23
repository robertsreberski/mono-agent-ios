// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

public struct RestartCardContent {
  public var agentLabel: String
  public var reason: String?
  public var unavailable: String?
  public var confirming = false
  public var requesting = false
  public var hasOperation = false
  public var stage = "requesting"
  public var outcome: String?
  public var outcomeReason: String?
  public var warning: String?
  public var approximateRunningCount = 0
  public init(agentLabel: String, reason: String? = nil) {
    self.agentLabel = agentLabel
    self.reason = reason
  }
}

public struct RestartProposalCard: View {
  let content: RestartCardContent
  let request: () -> Void
  let confirm: () -> Void
  let cancel: () -> Void
  public init(
    _ content: RestartCardContent, request: @escaping () -> Void,
    confirm: @escaping () -> Void, cancel: @escaping () -> Void
  ) {
    self.content = content
    self.request = request
    self.confirm = confirm
    self.cancel = cancel
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let outcome = content.outcome {
        Text(
          outcome == "success"
            ? "Restarted — agent is back online."
            : outcome == "failure"
              ? "Restart failed" + suffix
              : "Restart not confirmed — check the agent" + suffix
        )
        .accessibilityIdentifier("restart-outcome")
      } else if content.requesting || content.hasOperation {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { stages }
          VStack(alignment: .leading, spacing: 5) { stages }
        }.accessibilityIdentifier("restart-progress")
      } else {
        Text(String((content.reason ?? "Restart this agent when ready.").prefix(280)))
        if content.confirming {
          Text("Restarting may interrupt active conversations, jobs and monitors.")
          if content.approximateRunningCount > 0 {
            Text(
              "About \(content.approximateRunningCount) running conversation\(content.approximateRunningCount == 1 ? "" : "s") will be interrupted (approximate)."
            )
          }
          HStack(spacing: 8) {
            action("Confirm restart", id: "restart-confirm", action: confirm)
            action("Cancel", id: "restart-cancel", action: cancel)
          }
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              requestButton
              unavailable
            }
            VStack(alignment: .leading, spacing: 8) {
              requestButton
              unavailable
            }
          }
        }
      }
      if let warning = content.warning {
        Text(warning).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
          .accessibilityIdentifier("restart-warning")
      }
    }.webFont(.restartCopy).foregroundStyle(WebColor.text.color)
      .padding(.vertical, 10).padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 11))
      .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(border) }
      .webShadow(.small).accessibilityElement(children: .contain)
      .accessibilityLabel("Agent restart").accessibilityIdentifier("restart-card")
  }
  private var suffix: String { content.outcomeReason.map { ": " + String($0.prefix(280)) } ?? "." }
  private var border: Color {
    content.outcome == "success"
      ? WebColor.success.color
      : content.outcome == "failure" ? WebColor.danger.color : WebColor.lineStrong.color
  }
  @ViewBuilder private var stages: some View {
    ForEach(
      [("requesting", "Requesting"), ("restarting", "Restarting"), ("back_online", "Back online")],
      id: \.0
    ) { stage in
      Text(stage.1).fontWeight(content.stage == stage.0 ? .bold : .regular)
        .foregroundStyle(content.stage == stage.0 ? WebColor.text.color : WebColor.textSoft.color)
        .accessibilityLabel(stage.1 + (content.stage == stage.0 ? ", current step" : ""))
    }
  }
  private var requestButton: some View {
    action("Restart " + content.agentLabel, id: "restart-request", action: request)
      .disabled(content.unavailable != nil)
      .opacity(content.unavailable == nil ? 1 : 0.6)
  }
  @ViewBuilder private var unavailable: some View {
    if let text = content.unavailable {
      Text(text).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
    }
  }
  private func action(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).padding(.horizontal, 10).frame(minHeight: 36)
        .background(WebColor.surface.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WebColor.lineStrong.color) }
        .frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityIdentifier(id)
  }
}

#if DEBUG
  #Preview("Restart proposal") {
    DesignPreviewMatrix {
      VStack {
        RestartProposalCard(.init(agentLabel: "Atlas"), request: {}, confirm: {}, cancel: {})
        let confirming = {
          var value = RestartCardContent(agentLabel: "Atlas")
          value.confirming = true
          return value
        }()
        RestartProposalCard(confirming, request: {}, confirm: {}, cancel: {})
        let unavailable = {
          var value = RestartCardContent(agentLabel: "Atlas")
          value.unavailable = "Restart is unavailable."
          return value
        }()
        RestartProposalCard(unavailable, request: {}, confirm: {}, cancel: {})
      }.padding()
    }
  }
#endif
