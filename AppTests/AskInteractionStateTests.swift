// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgent
@testable import MonoAgentStore

#if DEBUG
  @MainActor struct AskInteractionStateTests {
    @Test(arguments: ["answered", "cancelled", "expired"])
    func terminalTranscriptOutranksRetainedPendingSnapshot(status: String) throws {
      let pending = try ComposerFixture.askSnapshot()
      #expect(AskInteractionState.terminal(snapshot: pending, persisted: status) == status)
    }

    @Test func doubleTapAndLatePendingPollCannotOverwriteAnAnswer() throws {
      let state = AskInteractionState()
      let pending = try ComposerFixture.askSnapshot()
      let revision = state.revision
      state.applyPoll(pending, revision: revision)
      #expect(state.beginSubmission())
      #expect(!state.beginSubmission(), "second tap must not start a request")
      state.applyPoll(pending, revision: revision)
      var answered = pending
      answered.status = "answered"
      state.finishSubmission(answered)
      state.applyPoll(pending, revision: revision)
      state.applyPoll(pending, revision: state.revision)
      #expect(state.snapshot?.status == "answered")
      #expect(!state.beginSubmission())
    }

    @Test(arguments: [-3600.0, 3600.0])
    func expiryUsesServerAdjustedTime(offset: Double) async throws {
      let model = AppModel(scenario: .consoleOnline, storeScenario: .conversationAskForm)
      await model.start()
      let store = try #require(model.store)
      // Stop live effects first: a fixture stream event would otherwise re-derive the offset
      // from its own timestamp between setting it and reading the server time.
      await store.stop()
      store.serverClockOffset = offset
      // One server-time snapshot drives both the expiry and the normalization.
      let serverNow = await store.serverNow()
      #expect(store.serverClockOffset == offset, "the applied offset is the one under test")
      var pending = try ComposerFixture.askSnapshot()
      let deviceNow = serverNow.addingTimeInterval(-offset)
      pending.expiresAt = ISO8601DateFormatter().string(
        from: deviceNow.addingTimeInterval(offset / 2))
      let normalized = AskForm.normalized(pending, now: serverNow)
      #expect(normalized.status == (offset > 0 ? "expired" : "pending"))
    }

    @Test func untrustedIntegralEnumOutsideIntRangeNeverTraps() {
      let options = PeerQuestionForm.options([
        "enum": .array([.number(1e30), .number(-1e30), .number(4)])
      ])
      #expect(options == ["1e+30", "-1e+30", "4"])
    }
  }
#endif
