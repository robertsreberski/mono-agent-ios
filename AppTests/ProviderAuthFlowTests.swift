// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import MonoAgentKit
  import MonoAgentStore
  import Testing

  @testable import MonoAgent

  @MainActor struct ProviderAuthFlowTests {
    @Test(arguments: ["succeeded", "failed", "cancelled"])
    func terminalSnapshotWithTheSamePromptInvalidatesUnsubmittedInput(state: String) throws {
      let pending = try ProviderFixture.session(
        providerID: "anthropic", authType: "api_key", strategy: "api_key_prompt",
        scenario: .providerAuthSecret)
      var terminal = pending
      terminal.state = state
      #expect(terminal.id == pending.id && terminal.prompt?.id == pending.prompt?.id)
      // The view clears its local field and focus on this identity change, even when the
      // server retains the exact same secret prompt in its terminal snapshot.
      #expect(ProviderAuthFlow.inputIdentity(pending) != ProviderAuthFlow.inputIdentity(terminal))
      var progress = pending
      progress.progress = "Still waiting"
      #expect(ProviderAuthFlow.inputIdentity(progress) == ProviderAuthFlow.inputIdentity(pending))
    }

    @Test func serverDisplayBoundsPreserveSubmissionIDs() throws {
      var session = try ProviderFixture.session(
        providerID: "anthropic", authType: "api_key", strategy: "api_key_prompt",
        scenario: .providerAuthSelect)
      let originalID = String(repeating: "option-id-", count: 600)
      let label = String(repeating: "🦉", count: 2000)
      session.prompt?.options?[0].id = originalID
      session.prompt?.options?[0].label = label
      let option = try #require(session.prompt?.options?.first)
      #expect(ProviderPresentation.boundedText(option.label).utf8.count == 4096)
      #expect(option.id == originalID)
      #expect(ProviderPresentation.boundedText("Authenticate " + label).utf8.count <= 4096)
    }
  }
#endif
