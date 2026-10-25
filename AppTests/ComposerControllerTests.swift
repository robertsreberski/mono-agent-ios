// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

#if DEBUG
  /// The composer state machine against the real Store and the scripted synthetic console.
  @MainActor
  struct ComposerControllerTests {
    private let atlas = DashboardFixture.atlas
    private let open = DashboardFixture.openThreadID

    private func store(_ scenario: StoreScenario, select thread: String?) async throws -> (
      AppModel, ConsoleStore
    ) {
      let model = AppModel(scenario: .consoleOnline, storeScenario: scenario)
      await model.start()
      let store = try #require(model.store)
      await store.select(sourceID: atlas, threadID: thread)
      try await until { store.connection == .live && store.canSend }
      return (model, store)
    }

    private func until(_ condition: () -> Bool) async throws {
      for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
      #expect(condition())
    }

    @Test func idleSendConfirmsClearsTheDraftAndReturnsToIdle() async throws {
      let (_, store) = try await store(.composerQuote, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      #expect(composer.phase == .idle && composer.affordances.primary == .send)
      composer.text = "Ship the sample"
      composer.setQuote(WebQuote(text: "The sample is ready.", messageId: "sample-assistant"))
      await composer.flushDraft()
      #expect(store.draft(sourceID: atlas, threadID: open)?.text == "Ship the sample")
      await composer.send()
      #expect(composer.phase == .confirmed(liveInput: false))
      #expect(composer.text.isEmpty && composer.quote == nil)
      #expect(store.draft(sourceID: atlas, threadID: open) == nil)
      try await until { composer.phase == .idle }
      #expect(composer.phase == .idle)
      await store.stop()
    }

    @Test func uncertainSendRetriesWithTheSameSubmissionIdentity() async throws {
      let (model, store) = try await store(.composerSendFailed, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      composer.text = "Publish the sample"
      await composer.send()
      guard case .uncertain = composer.phase else {
        Issue.record("A lost POST with an unreadable receipt is uncertain, got \(composer.phase)")
        return
      }
      #expect(composer.text == "Publish the sample", "uncertain text is retained")
      #expect(composer.affordances.showsRetry)
      #expect(store.errorMessage == nil, "the composer owns the uncertain message")
      await composer.retry()
      #expect(composer.phase == .confirmed(liveInput: false))
      let ids = try #require(await model.composerScript?.submissionIDs)
      #expect(ids.count == 2 && ids[0] == ids[1])
      await store.stop()
    }

    @Test func uncertainRetryDoesNotClearANewerDraft() async throws {
      let (_, store) = try await store(.composerSendFailed, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      composer.text = "Sample A"
      await composer.send()
      #expect(composer.phase.allowsRetry)
      let identity = composer.lastAttempt?.input.submissionId
      composer.text = "Sample B"
      await composer.flushDraft()
      await composer.retry()
      #expect(composer.phase == .confirmed(liveInput: false))
      #expect(composer.text == "Sample B")
      #expect(store.draft(sourceID: atlas, threadID: open)?.text == "Sample B")
      #expect(identity?.isEmpty == false)
      await store.stop()
    }

    @Test func quickReplyDoesNotBindOrClearTheComposerDraft() async throws {
      let (_, store) = try await store(.conversationQuickReplies, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      composer.text = "Unsent sample draft"
      await composer.flushDraft()
      let version = store.draft(sourceID: atlas, threadID: open)?.version
      #expect(await composer.sendReply("Ship it"))
      #expect(composer.text == "Unsent sample draft")
      #expect(store.draft(sourceID: atlas, threadID: open)?.version == version)
      await store.stop()
    }

    @Test func freshNewConversationRequestsCreateDistinctThreads() async throws {
      let (_, store) = try await store(.composerEmpty, select: nil)
      let firstRoute = AppRoute.newConversation(profile: store.profile.id, sourceID: atlas)
      let first = ComposerController(store: store, sourceID: atlas, threadID: firstRoute.threadID)
      first.text = "First sample"
      await first.send()
      let firstID = try #require(first.threadID)
      let nextRoute = AppRoute.newConversation(profile: store.profile.id, sourceID: atlas)
      #expect(firstRoute != nextRoute)
      await store.select(sourceID: atlas)
      let second = ComposerController(store: store, sourceID: atlas, threadID: nextRoute.threadID)
      second.text = "Second sample"
      await second.send()
      #expect(second.phase == .confirmed(liveInput: false))
      #expect(second.threadID != firstID)
      await store.stop()
    }

    @Test func runningConversationQueuesLiveInputAndStops() async throws {
      let (_, store) = try await store(.composerRunning, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      try await until { composer.running }
      composer.text = "Also check the images"
      #expect(composer.affordances.primary == .queue && composer.affordances.showsStop)
      await composer.send()
      #expect(composer.phase == .confirmed(liveInput: true))
      await composer.stop()
      #expect(!composer.running && composer.stopError == nil)
      #expect(composer.affordances.primary == .send)
      await store.stop()
    }

    @Test func newConversationIsCreatedBeforeSubmissionWithItsDraftContext() async throws {
      let (model, store) = try await store(.composerEmpty, select: nil)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: nil)
      var created: String?
      composer.onCreate = { created = $0 }
      composer.setModel("sample:small")
      composer.text = "Plan the sample launch"
      await composer.flushDraft()
      #expect(store.draft(sourceID: atlas, threadID: nil)?.text == "Plan the sample launch")
      await composer.send()
      #expect(composer.phase == .confirmed(liveInput: false))
      let thread = try #require(created)
      #expect(composer.threadID == thread && store.selectedThreadID == thread)
      #expect(store.conversations[thread]?.thread.runModel == "sample:small")
      #expect(store.draft(sourceID: atlas, threadID: nil) == nil, "admission clears the context")
      #expect(await model.composerScript?.submissions.first?.model == "sample:small")
      await store.stop()
    }

    @Test func draftsFollowTheirContextAcrossSwitches() async throws {
      let (_, store) = try await store(.composerQuote, select: open)
      let first = ComposerController(store: store, sourceID: atlas, threadID: open)
      first.text = "Alpha draft"
      await first.flushDraft()
      await store.select(sourceID: atlas, threadID: "t-atlas-notes")
      let other = ComposerController(store: store, sourceID: atlas, threadID: "t-atlas-notes")
      #expect(other.text.isEmpty)
      other.text = "Beta draft"
      await other.flushDraft()
      await store.select(sourceID: atlas, threadID: nil)
      let fresh = ComposerController(store: store, sourceID: atlas, threadID: nil)
      #expect(fresh.text.isEmpty, "a new conversation has its own context")
      await store.select(sourceID: atlas, threadID: open)
      let back = ComposerController(store: store, sourceID: atlas, threadID: open)
      #expect(back.text == "Alpha draft")
      // Whitespace-only text is not a draft (web prunes it).
      back.text = "   "
      await back.flushDraft()
      #expect(store.draft(sourceID: atlas, threadID: open) == nil)
      await store.stop()
    }

    @Test func skillTriggersInsertAndModelOverridesPatchTheThread() async throws {
      let (_, store) = try await store(.composerSkillPicker, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      await store.loadSkills(sourceID: atlas)
      composer.text = "Please use $rel"
      composer.selection = .init(insertionPoint: composer.text.endIndex)
      #expect(composer.skillSuggestions.first?.name == "release-notes")
      composer.insertSkill("release-notes")
      #expect(composer.text == "Please use $release-notes ")
      #expect(composer.skillSuggestions.isEmpty)
      composer.setModel("sample:small")
      try await store.settleThreadWrites(open)
      #expect(store.conversations[open]?.thread.runModel == "sample:small")
      #expect(composer.runEffort == "", "an effort the new model cannot run is cleared")
      composer.resetRunSettings()
      try await store.settleThreadWrites(open)
      #expect(!composer.hasRunOverride)
      await store.stop()
    }

    @Test func draftTextQuoteAndPhotoSurviveRunRefreshAndBackgroundChanges() async throws {
      let (model, store) = try await store(.composerDraftAttachments, select: open)
      let script = try #require(model.composerScript)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      composer.text = "Unsent sample draft"
      let quote = WebQuote(text: "Sample quotation", messageId: "sample-assistant")
      composer.setQuote(quote)
      await composer.flushDraft()
      let photo = try AttachmentAdapter.stage(
        data: Data([0x89, 0x50, 0x4e, 0x47]), name: "sample-photo.png")
      await composer.stage([photo])
      let ids = store.stagedAttachments.map(\.id)
      #expect(ids.count == 1)
      for running in [true, false, true] {
        try await script.setRunning(running)
        try await until { composer.running == running }
        await store.reconcile()
        await store.select(sourceID: atlas, threadID: open)
        #expect(composer.affordances.primary == (running ? .queue : .send))
        #expect(store.stagedAttachments.map(\.id) == ids)
        #expect(composer.text == "Unsent sample draft" && composer.quote == quote)
      }
      await store.scenePhaseChanged(.background)
      #expect(store.stagedAttachments.map(\.id) == ids)
      #expect(composer.text == "Unsent sample draft" && composer.quote == quote)
      await store.scenePhaseChanged(.active)
      try await until { store.connection == .live }
      await store.reconcile()
      #expect(store.stagedAttachments.map(\.id) == ids)
      #expect(composer.text == "Unsent sample draft" && composer.quote == quote)
      #expect(store.draft(sourceID: atlas, threadID: open)?.text == "Unsent sample draft")
      await store.stop()
    }

    @Test func attachmentsStageThroughTheStoreAndRespectLimits() async throws {
      let (_, store) = try await store(.composerDraftAttachments, select: open)
      let composer = ComposerController(store: store, sourceID: atlas, threadID: open)
      #expect(composer.text == ComposerFixture.draftText, "the saved draft is restored")
      let note = try AttachmentAdapter.stage(data: Data("note".utf8), name: "note.txt")
      await composer.stage([note])
      #expect(store.stagedAttachments.map(\.name) == ["note.txt"])
      #expect(!FileManager.default.fileExists(atPath: note.url.path), "temporary copy removed")
      let blocked = try AttachmentAdapter.stage(data: Data("x".utf8), name: "tool.exe")
      await composer.stage([blocked])
      #expect(composer.uploadError?.contains("not an accepted file type") == true)
      #expect(store.stagedAttachments.count == 1)
      await composer.remove(try #require(store.stagedAttachments.first))
      #expect(store.stagedAttachments.isEmpty)
      await store.stop()
    }
  }
#endif
