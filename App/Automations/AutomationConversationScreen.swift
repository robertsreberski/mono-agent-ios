// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentStore
import SwiftUI

/// Durable route identity is profile/source/job; the Store alone resolves its conversation.
struct AutomationConversationScreen: View {
  let model: AppModel
  let store: ConsoleStore
  let sourceID: String
  let jobID: String
  let navigate: (AppRoute?) -> Void
  @State private var threadID: String?
  @State private var loading = true
  var body: some View {
    Group {
      if let threadID {
        ConversationScreen(
          model: model, store: store,
          route: .conversation(
            profile: store.profile.id, sourceID: sourceID, threadID: threadID, archived: false),
          navigate: navigate)
      } else if loading {
        LoadingStateView("Loading automation…")
      } else {
        EmptyStateView(
          "Automation unavailable", systemImage: "clock",
          message: "No saved job conversation is available.")
      }
    }.task(id: sourceID + jobID) {
      threadID = await store.selectAutomation(sourceID: sourceID, jobID: jobID)
      loading = false
    }
  }
}
