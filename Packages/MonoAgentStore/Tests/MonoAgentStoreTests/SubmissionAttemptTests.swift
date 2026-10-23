// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing

@testable import MonoAgentStore

@MainActor struct SubmissionAttemptTests {
  @Test func recoveryThenRetryDoesNotPostOrMintAnotherIdentity() async throws {
    let h = Harness()
    await h.store.hydrate()
    let input = h.store.prepareSubmission(.init(submissionId: "", text: "Sample A"))
    await h.transport.set(submissionPath, [.failure])
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input)
      Issue.record("Lost response must be uncertain")
    } catch {}
    let reference = try #require(h.store.pendingSubmissions.first)
    #expect(reference.submissionID == input.submissionId)
    await h.transport.set(
      submissionPath + "/" + input.submissionId, [.response(try admission(reference, status: 200))])
    await h.store.recoverSubmissions()
    #expect(h.store.pendingSubmissions.isEmpty)
    let receipt = try await h.store.submit(
      sourceID: "agent-example", threadID: "thread-example", input: input)
    #expect(receipt.submissionId == input.submissionId)
    #expect(await h.transport.count(submissionPath, method: "POST") == 1)
    await h.store.stop()
  }

  @Test(arguments: [false, true])
  func retryKeepsOriginalDraftBindingOrExplicitlyNoDraft(quickReply: Bool) async throws {
    let h = Harness()
    await h.store.hydrate()
    await h.store.setDraft(sourceID: "agent-example", threadID: "thread-example", text: "Sample A")
    let key = DraftKey(
      profileID: h.profile.id, sourceID: "agent-example", threadID: "thread-example")
    let version = h.store.draft(sourceID: "agent-example", threadID: "thread-example")?.version
    let binding: SubmissionDraftBinding = quickReply ? .none : .version(key, version)
    let input = h.store.prepareSubmission(
      .init(submissionId: "", text: quickReply ? "Quick reply" : "Sample A"))
    await h.transport.set(submissionPath, [.failure, .paused])
    do {
      _ = try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input, draftBinding: binding)
    } catch {}
    let reference = try #require(h.store.pendingSubmissions.first)
    #expect(reference.draftVersion == (quickReply ? nil : version))
    if !quickReply {
      await h.store.setDraft(
        sourceID: "agent-example", threadID: "thread-example", text: "Sample B")
    }
    let retry = Task {
      try await h.store.submit(
        sourceID: "agent-example", threadID: "thread-example", input: input, draftBinding: binding)
    }
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(h.store.pendingSubmissions.first?.draftVersion == reference.draftVersion)
    await h.transport.release(try admission(reference))
    _ = try await retry.value
    #expect(
      h.store.draft(sourceID: "agent-example", threadID: "thread-example")?.text
        == (quickReply ? "Sample A" : "Sample B"))
    await h.store.stop()
  }
}
