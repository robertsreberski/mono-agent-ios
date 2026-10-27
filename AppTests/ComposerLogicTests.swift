// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

struct ComposerRulesTests {
  private func affordances(
    content: Bool = true, uploading: Bool = false, running: Bool = false, canSend: Bool = true,
    compacting: Bool = false, phase: ComposerPhase = .idle, offline: Bool = false,
    archived: Bool = false
  ) -> ComposerAffordances {
    ComposerRules.affordances(
      hasContent: content, uploading: uploading, running: running, canSend: canSend,
      compacting: compacting, phase: phase, agentLabel: "Atlas", agentOffline: offline,
      archived: archived)
  }

  @Test func idleSendsOnlyWithContent() {
    #expect(!affordances(content: false).primaryEnabled)
    let ready = affordances()
    #expect(ready.primary == .send && ready.primaryEnabled && !ready.showsStop)
    #expect(ready.placeholder == "Message Atlas…")
  }

  @Test func runningOffersStopAndQueuesLiveInput() {
    let empty = affordances(content: false, running: true)
    #expect(empty.showsStop && !empty.primaryEnabled)
    let typed = affordances(running: true)
    #expect(typed.primary == .queue && typed.primaryEnabled && typed.showsStop)
    #expect(typed.placeholder == "Message Atlas while it works…")
  }

  @Test func blockedStatesExplainThemselvesAndKeepStop() {
    #expect(affordances(offline: true).unavailableReason == "Atlas is offline")
    #expect(affordances(archived: true).unavailableReason == "Conversation archived")
    #expect(affordances(canSend: false).unavailableReason == "Not connected to the console")
    let compacting = affordances(running: true, compacting: true)
    #expect(!compacting.primaryEnabled && compacting.showsStop)
    #expect(!affordances(uploading: true).primaryEnabled)
    #expect(!affordances(phase: .sending(liveInput: false)).primaryEnabled)
    #expect(affordances(phase: .uncertain("x")).showsRetry)
    #expect(affordances(phase: .failed("x")).showsRetry)
    #expect(!affordances(phase: .confirmed(liveInput: false)).showsRetry)
  }

  @Test func outcomesAreClassifiedFromStoreStateNotGuessed() throws {
    #expect(
      ComposerRules.phase(after: URLError(.timedOut), possiblyDispatched: true)
        .allowsRetry)
    if case .uncertain = ComposerRules.phase(after: URLError(.timedOut), possiblyDispatched: true) {
    } else {
      Issue.record("A dispatched reference is uncertain")
    }
    if case .failed(let text) = ComposerRules.phase(
      after: SubmissionError.rejected("busy"), possiblyDispatched: false)
    {
      #expect(text.contains("rejected") && text.contains("kept"))
    } else {
      Issue.record("A definitive rejection fails")
    }
    if case .failed(let text) = ComposerRules.phase(
      after: SubmissionError.journalFull, possiblyDispatched: false)
    {
      #expect(text.contains("Recovery history is full"))
    } else {
      Issue.record("Journal full fails visibly")
    }
    let live: WebSubmissionReceipt = try ComposerFixture.decode(
      #"{"submissionId":"s","threadId":"t","outcome":"live-input"}"#)
    #expect(ComposerRules.phase(after: live) == .confirmed(liveInput: true))
    #expect(ComposerRules.label(.confirmed(liveInput: true))?.contains("live input") == true)
  }
}

struct SkillDiscoveryTests {
  private func skill(_ name: String, _ description: String = "", availability: String = "on-demand")
    throws -> WebSkillInfo
  {
    try ComposerFixture.decode(
      #"{"name":"\#(name)","description":"\#(description)","availability":"\#(availability)","reference":"$\#(name)"}"#
    )
  }

  @Test func triggersOnlyAtTokenStartsWithCollapsedCaret() {
    #expect(SkillDiscovery.detect("$", in: "$rel", selectionStart: 4)?.query == "rel")
    #expect(SkillDiscovery.detect("$", in: "use $re", selectionStart: 7)?.offset == 4)
    #expect(SkillDiscovery.detect("$", in: "price$5", selectionStart: 7) == nil)
    #expect(SkillDiscovery.detect("$", in: "use $re", selectionStart: 5, selectionEnd: 7) == nil)
    #expect(SkillDiscovery.detect("$", in: "use $re x", selectionStart: 9) == nil)
    #expect(SkillDiscovery.detect("$", in: "$a.b", selectionStart: 4) == nil)
    #expect(SkillDiscovery.detect("/", in: "/set", selectionStart: 4)?.query == "set")
    #expect(SkillDiscovery.detect("$", in: "$", selectionStart: 1)?.query == "")
  }

  @Test func rankingFollowsTheWebTiers() throws {
    let skills = [
      try skill("weekly-digest", "Summarise notes"), try skill("release-notes", "Draft notes"),
      try skill("notes", "Plain"), try skill("legacy", "notes export", availability: "unavailable"),
    ]
    #expect(SkillDiscovery.rank(skills, query: "notes").map(\.name).first == "notes")
    #expect(
      SkillDiscovery.rank(skills, query: "rel").map(\.name) == ["release-notes"])
    #expect(!SkillDiscovery.rank(skills, query: "").contains { $0.name == "legacy" })
    #expect(
      SkillDiscovery.rank(skills, query: "", includeUnavailable: true).contains {
        $0.name == "legacy"
      })
    #expect(SkillDiscovery.rank(skills, query: "summ").map(\.name) == ["weekly-digest"])
  }

  @Test func insertionPadsNeighboursAndPlacesTheCaret() {
    let token = SkillDiscovery.insert("$release-notes", into: "use $rel", start: 4, end: 8)
    #expect(token == TextInsertion(text: "use $release-notes ", caret: 19))
    let middle = SkillDiscovery.insert("$a", into: "xy", start: 1, end: 1)
    #expect(middle == TextInsertion(text: "x $a y", caret: 5))
    let beforeSpace = SkillDiscovery.insert("$a", into: "x  y", start: 2, end: 2)
    #expect(beforeSpace == TextInsertion(text: "x $a y", caret: 5))
    #expect(SkillDiscovery.insert("not-a-ref", into: "x", start: 0, end: 0).text == "x")
    let command = SkillDiscovery.detect("/", in: "hi /set", selectionStart: 7)!
    #expect(SkillDiscovery.remove(command, from: "hi /set") == TextInsertion(text: "hi ", caret: 3))
  }

  @Test func usableSkillsNeedACanonicalReference() throws {
    var value = try skill("release-notes")
    #expect(SkillDiscovery.isUsable(value))
    value.reference = "$other"
    #expect(!SkillDiscovery.isUsable(value))
    #expect(SkillDiscovery.statusLabel(try skill("x", availability: "inlined")) == "In prompt")
  }

  @Test func commandsMirrorTheWebMenu() {
    #expect(
      ComposerCommand.available(
        running: false, hasRunSettings: true, hasAgent: true, attachmentCount: 0, query: "")
        == [.settings, .new])
    #expect(
      ComposerCommand.available(
        running: true, hasRunSettings: true, hasAgent: true, attachmentCount: 0, query: "")
        == [.stop])
    #expect(
      ComposerCommand.available(
        running: false, hasRunSettings: false, hasAgent: true, attachmentCount: 2, query: ""
      )
      .isEmpty)
    #expect(
      ComposerCommand.available(
        running: false, hasRunSettings: true, hasAgent: true, attachmentCount: 0, query: "new")
        == [.new])
  }
}

struct ModelOptionsTests {
  @Test func compactBadgesUseWireTokensAndKeepFullSpokenMeaning() throws {
    let agent = try agent()
    #expect(ModelOptions.compactEffortLabel(agent, model: "", effort: "xhigh") == "XHIGH")
    #expect(ModelOptions.compactEffortLabel(agent, model: "", effort: "none") == "OFF")
    #expect(ModelOptions.compactEffortLabel(agent, model: "", effort: "") == "HIGH")
    #expect(ModelOptions.compactEffortLabel(agent, model: "", effort: "future") == "FUTURE")
    #expect(ModelOptions.compactEffortLabel(nil, model: "", effort: "") == "")
    #expect(ModelOptions.summary(agent, model: "", effort: "xhigh").hasSuffix("Extra high"))
  }

  private func agent() throws -> WebAgentSummary {
    try ComposerFixture.agent(
      DashboardFixture.agents().first { $0.sourceId == DashboardFixture.atlas }!)
  }

  @Test func rowsListDefaultShortlistKeptOverrideAndExplainedCatalogs() throws {
    let rows = ModelOptions.rows(try agent(), selectedModel: "other:legacy")
    #expect(
      rows.map(\.id) == [
        "", "sample:large", "sample:small", "sample:fast", "other:legacy", "catalog:harbor",
      ])
    #expect(rows[0].name == "Default · Sample Large")
    #expect(rows[1].isAgentDefault)
    #expect(rows[4].note?.contains("kept") == true && rows[4].selectable)
    #expect(!rows[5].selectable && rows[5].note != nil)
  }

  @Test func effortLaddersFollowTheSharedRule() throws {
    let agent = try agent()
    #expect(
      ModelOptions.effortOptions(agent, model: "").map(\.id) == ["", "low", "medium", "high"])
    #expect(ModelOptions.effortOptions(agent, model: "").first?.name == "Default · High")
    #expect(ModelOptions.effortOptions(agent, model: "sample:fast").isEmpty)
    #expect(
      ModelOptions.effortOptions(agent, model: "sample:small").first?.name == "Default · Provider",
      "high is not admitted by sample:small, so the default is the provider's")
    #expect(
      ModelOptions.effortAfterSwitching(agent, to: "sample:small", currentEffort: "high") == "")
    #expect(
      ModelOptions.effortAfterSwitching(agent, to: "sample:small", currentEffort: "low") == "low")
    #expect(ModelOptions.summary(agent, model: "", effort: "") == "Sample Large · High")
    #expect(
      ModelOptions.summary(agent, model: "sample:small", effort: "low") == "Sample Small · Low")
  }

  @Test func advertisementsMapLikeTheWeb() throws {
    func option(_ json: String) throws -> WebModelOption { try ComposerFixture.decode(json) }
    #expect(ModelOptions.advertisedLevels(nil) == nil)
    #expect(ModelOptions.advertisedLevels(try option(#"{"reasoning":false}"#)) == [])
    #expect(
      ModelOptions.advertisedLevels(try option(#"{"reasoningMode":"toggle"}"#)) == ["high", "none"])
    #expect(
      ModelOptions.advertisedLevels(try option(#"{"reasoningMode":"effort"}"#))
        == ModelOptions.globalEffortLevels)
    #expect(ModelOptions.advertisedLevels(try option(#"{"reasoning":true}"#)) == [])
    #expect(ModelOptions.providerOf("anthropic:claude") == "anthropic")
    #expect(ModelOptions.providerOf("org/model:x") == "org")
    #expect(ModelOptions.effortName("xhigh") == "Extra high")
  }
}

struct QuoteFormattingTests {
  @Test func quotesReadableTextBoundedAndPreviewed() throws {
    let message = try TranscriptFixture.message(
      id: "m1", role: "assistant", text: "The sample is **ready** with `code`.\nSecond line.")
    let quote = try #require(QuoteFormatting.quote(message: message))
    #expect(quote.text == "The sample is ready with code.\nSecond line.")
    #expect(quote.messageId == "m1")
    #expect(QuoteFormatting.preview(quote) == "The sample is ready with code. Second line.")
    #expect(QuoteFormatting.quote("   \n", messageID: "m1") == nil)
    let long = QuoteFormatting.quote(String(repeating: "a", count: 5_000), messageID: "m")
    #expect(long?.text.count == QuoteFormatting.maximumCharacters)
    #expect(long?.text.hasSuffix("…") == true)
  }
}

struct AskFormTests {
  private func snapshot() throws -> ChannelAskSnapshot { try ComposerFixture.askSnapshot() }

  @Test func everyQuestionIsRequiredWithSingleAndMultiRules() throws {
    let ask = try snapshot()
    let window = ask.questions[0]
    let checks = ask.questions[1]
    var draft = AskFormDraft()
    #expect(!AskForm.isComplete(ask, draft))
    #expect(AskForm.firstIncomplete(ask, draft)?.id == "window")
    draft.toggle("today", in: window)
    #expect(AskForm.firstIncomplete(ask, draft)?.id == "checks")
    draft.toggle("links", in: checks)
    draft.toggle("copy", in: checks)
    #expect(AskForm.isComplete(ask, draft))
    draft.toggle("links", in: checks)
    draft.toggle("copy", in: checks)
    #expect(!AskForm.isComplete(ask, draft), "multi-select needs at least one answer")
  }

  @Test func customRepliesReplaceSingleChoicesAndAreTrimmed() throws {
    let ask = try snapshot()
    var draft = AskFormDraft()
    draft.toggle("today", in: ask.questions[0])
    draft.setCustom("  After lunch ", for: ask.questions[0])
    #expect(draft.selected["window"] == [])
    draft.setCustom("Also captions", for: ask.questions[1])
    #expect(AskForm.isComplete(ask, draft))
    let answers = AskForm.answers(ask, draft)
    #expect(
      answers[0]
        == ChannelAskAnswer(questionId: "window", selectedOptionIds: [], customReply: "After lunch")
    )
    #expect(answers[1].customReply == "Also captions")
    draft.toggle("monday", in: ask.questions[0])
    #expect(draft.custom["window"] == "", "choosing an option clears the single custom reply")
  }

  @Test func summariesAndResultParsingMatchTheWeb() throws {
    let answered = try ComposerFixture.askSnapshot(answered: [
      .init(questionId: "window", selectedOptionIds: ["today"]),
      .init(questionId: "checks", selectedOptionIds: ["links"], customReply: "Captions"),
    ])
    #expect(AskForm.summary(answered) == ["Release window: Today", "Checks: Links"])
    #expect(AskForm.remaining(answered).isEmpty)
    let result: JSONValue = .object([
      "structuredContent": .object([
        "interactionId": .string("ask-1"), "answered": .bool(false), "reason": .string("timeout"),
      ])
    ])
    #expect(AskForm.interactionID(result) == "ask-1")
    #expect(AskForm.persistedStatus(result) == "expired")
    var pending = try snapshot()
    pending.expiresAt = "2030-01-02T12:00:00Z"
    #expect(
      AskForm.normalized(pending, now: DashboardFixture.now.addingTimeInterval(1)).status
        == "expired")
  }
}

struct AttachmentLimitTests {
  private let limits = UploadLimits(
    maxFileBytes: 1_000, maxFilesPerTurn: 2, maxTurnBytes: 1_500, accept: ["text/plain", "image/*"])
  private func file(_ name: String, _ type: String, _ size: Int) -> UploadFile {
    UploadFile(
      url: URL(fileURLWithPath: "/dev/null"), name: name, contentType: type, sizeBytes: size)
  }

  @Test func limitsFromTheServerAreExplainedBeforeUploading() throws {
    #expect(
      AttachmentAdapter.problem([file("a.txt", "text/plain", 10)], limits: limits, existing: [])
        == nil)
    #expect(
      AttachmentAdapter.problem([file("a.png", "image/png", 10)], limits: limits, existing: [])
        == nil)
    #expect(
      AttachmentAdapter.problem(
        [file("a.pdf", "application/pdf", 10)], limits: limits, existing: [])?
        .contains("not an accepted file type") == true)
    #expect(
      AttachmentAdapter.problem(
        [file("big.txt", "text/plain", 2_000)], limits: limits, existing: [])?
        .contains("per file") == true)
    #expect(
      AttachmentAdapter.problem(
        [file("a.txt", "text/plain", 900), file("b.txt", "text/plain", 900)], limits: limits,
        existing: [])?.contains("per message") == true)
    let staged: WebAttachment = try ComposerFixture.decode(
      #"{"id":"u1","name":"x.txt","contentType":"text/plain","sizeBytes":5,"kind":"file","status":"ready","uploaded":true,"createdAt":"2030-01-02T12:00:00Z"}"#
    )
    #expect(
      AttachmentAdapter.problem(
        [file("a.txt", "text/plain", 1)], limits: limits, existing: [staged], uploading: 1)?
        .contains("Up to 2 files") == true)
  }

  @Test func clientHardCapsAndTypesApply() {
    let generous = UploadLimits(
      maxFileBytes: 100 * 1024 * 1024, maxFilesPerTurn: 50, maxTurnBytes: 500 * 1024 * 1024,
      accept: ["*/*"])
    let effective = AttachmentAdapter.effective(generous)
    #expect(effective.maxFileBytes == 20 * 1024 * 1024 && effective.maxFilesPerTurn == 10)
    #expect(AttachmentAdapter.contentType(forName: "notes.txt") == "text/plain")
    #expect(AttachmentAdapter.contentType(forName: "photo.jpg") == "image/jpeg")
    #expect(AttachmentAdapter.importTypes(["*/*"]) == [.item])
    #expect(AttachmentAdapter.importTypes(["image/*"]) == [.image])
    #expect(AttachmentAdapter.sanitized("../a/b") == "..-a-b")
  }

  @Test func stagedCopiesAreDeletedAfterUse() throws {
    let file = try AttachmentAdapter.stage(data: Data("note".utf8), name: "note.txt")
    #expect(file.sizeBytes == 4 && file.contentType == "text/plain")
    #expect(FileManager.default.fileExists(atPath: file.url.path))
    AttachmentAdapter.discard([file])
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
  }
}

struct PeerQuestionFormTests {
  @Test func describesUntrustedFormsLikeTheWeb() throws {
    let job: ProcessJobPart = try ComposerFixture.decode(ComposerFixture.peerJob)
    let question = try #require(job.job.peerQuestion)
    let fields = PeerQuestionForm.describe(question.requestedSchema)
    #expect(fields.map(\.key) == ["question_1", "question_2"])
    #expect(fields[0].options == ["Reserve now", "Wait for the vote"] && fields[0].required)
    #expect(fields[1].freeText && !fields[1].required)
    #expect(PeerQuestionForm.missingRequired(fields, values: [:]).map(\.key) == ["question_1"])
    #expect(
      PeerQuestionForm.missingRequired(fields, values: ["question_1": ["Reserve now"]]).isEmpty)
    let reply = PeerQuestionForm.reply(
      question, fields: fields, values: ["question_1": ["Reserve now"], "question_2": [" "]],
      note: "Thanks")
    #expect(reply.hasPrefix("Answer for the seed-bank peer question (spring-orders"))
    #expect(reply.contains("- Sample tomatoes: Reserve now"))
    #expect(!reply.contains("Delivery note"))
    #expect(reply.hasSuffix("Thanks"))
    #expect(PeerQuestionForm.stateLabel("awaiting_answer") == "Waiting for the agent's answer")
  }

  @Test func boundsOptionsAndReadsEnumNames() throws {
    let schema: [String: JSONValue] = try ComposerFixture.decode(
      #"{"type":"object","properties":{"many":{"type":"array","items":{"enum":[1,2,3,4,5,6,7,8,9,10,11,12,13,14]}},"named":{"enum":["a","b"],"enumNames":["Alpha","Beta"]}}}"#
    )
    let fields = PeerQuestionForm.describe(schema)
    let many = try #require(fields.first { $0.key == "many" })
    #expect(many.multiple && many.options.count == 13 && many.options.last == "+2 more")
    #expect(fields.first { $0.key == "named" }?.options == ["Alpha", "Beta"])
  }
}
