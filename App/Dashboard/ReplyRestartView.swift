// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ReplyRestartView: View {
  let part: RestartProposalPart
  let message: WebMessage
  let store: ConsoleStore
  @State private var state: RestartProposalState?
  private var reference: ReplyPartReference {
    .init(threadId: message.threadId, messageId: message.id, partId: part.id)
  }
  private var content: RestartCardContent {
    let source = store.conversations[message.threadId]?.thread.sourceId ?? ""
    var content = RestartCardContent(
      agentLabel: store.agents.first(where: { $0.sourceId == source })?.label ?? "agent",
      reason: part.reason)
    content.unavailable = store.restartUnavailableReason(reference)
    content.confirming = state?.confirming == true
    content.requesting = state?.requesting == true
    content.hasOperation = state?.operationID != nil
    content.stage = state?.stage ?? "requesting"
    content.outcome = state?.outcome
    content.outcomeReason = state?.outcomeReason
    content.warning = state?.requestUnknown ?? state?.pollWarning
    content.approximateRunningCount = store.activeFleet?.runningCounts[source] ?? 0
    return content
  }
  var body: some View {
    RestartProposalCard(content) {
      store.requestRestartConfirmation(reference)
    } confirm: {
      Task { await store.confirmRestart(reference) }
    } cancel: {
      store.cancelRestartConfirmation(reference)
    }
    .task(id: part) { state = store.restartProposalState(reference) }
    .task(id: state?.operationID) { await store.pollRestartProposal(reference) }
    .onDisappear { store.cancelRestartConfirmation(reference) }
  }
}
