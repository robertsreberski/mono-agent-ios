// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI
import UIKit

/// One frozen submission attempt. Retry resends exactly this payload so the Store's digest,
/// and therefore the submission UUID, is unchanged.
struct ComposerAttempt: Equatable {
  var input: ApiStartSubmission
  var threadID: String?
  var draftContext: DraftKey?
  var liveInput: Bool
  /// The composer text this attempt was made from; `nil` for quick replies.
  var sourceText: String?
}

/// Per-destination composer state over `ConsoleStore` (web Composer.tsx + composer-draft.ts +
/// the runtime's `onNew`). All reads and writes go through the Store's composer seams.
@MainActor @Observable
final class ComposerController {
  let store: ConsoleStore
  let sourceID: String
  private(set) var threadID: String?
  var text = "" {
    didSet { if text != oldValue { textChanged() } }
  }
  var selection: TextSelection?
  var quote: WebQuote?
  private(set) var phase: ComposerPhase = .idle
  private(set) var lastAttempt: ComposerAttempt?
  private(set) var stopping = false
  var stopError: String?
  var uploadError: String?
  /// Local run settings for a conversation that does not exist yet (web browser-local prefs).
  private(set) var newConversationModel = ""
  private(set) var newConversationEffort = ""
  /// Thumbnails for picked images, memory only. Keyed by staged attachment id or file name.
  private(set) var previews: [String: UIImage] = [:]
  /// Bumped to ask the view to focus the text field.
  private(set) var focusRequest = 0
  /// A trigger the operator dismissed with Escape stays closed until the text changes.
  var dismissedTrigger: TriggerQuery?
  var highlightedSuggestion = 0
  @ObservationIgnored var onCreate: (String) -> Void = { _ in }
  @ObservationIgnored var onNewConversation: () -> Void = {}
  @ObservationIgnored private var restoring = false
  @ObservationIgnored private var pendingDraft: (thread: String?, text: String)?
  @ObservationIgnored private var draftWriter: Task<Void, Never>?
  @ObservationIgnored private var confirmationReset: Task<Void, Never>?

  init(store: ConsoleStore, sourceID: String, threadID: String?) {
    self.store = store
    self.sourceID = sourceID
    self.threadID = threadID
    restoreDraft()
  }

  // MARK: Context

  var thread: WebThread? { threadID.flatMap { store.conversations[$0]?.thread } }
  var agent: WebAgentSummary? { store.agents.first { $0.sourceId == sourceID } }
  /// Whether the Store's selection is this composer's context (new conversation or thread).
  var isSelectedContext: Bool {
    store.selectedBucket?.sourceID == sourceID && store.selectedThreadID == threadID
  }
  var running: Bool {
    guard let threadID, let state = store.conversations[threadID] else { return false }
    return state.runningConfirmed && state.thread.runState.status == "running"
  }
  var compacting: Bool {
    thread?.compaction?.status == "running" && thread?.compaction?.trigger == "manual"
  }
  var uploading: Bool { !store.uploadProgress.isEmpty }
  var hasContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !store.stagedAttachments.isEmpty
  }
  var affordances: ComposerAffordances {
    ComposerRules.affordances(
      hasContent: hasContent, uploading: uploading, running: running,
      canSend: isSelectedContext && store.canSend, compacting: compacting, phase: phase,
      agentLabel: agent?.label, agentOffline: agent?.status == "offline",
      archived: thread?.archivedAt != nil)
  }

  /// Re-reads the Store draft for this context (navigation, relaunch, context switch).
  func restoreDraft() {
    restoring = true
    text = store.draft(sourceID: sourceID, threadID: threadID)?.text ?? ""
    restoring = false
    selection = TextSelection(insertionPoint: text.endIndex)
  }

  private func textChanged() {
    dismissedTrigger = nil
    highlightedSuggestion = 0
    guard !restoring else { return }
    scheduleDraft()
  }

  /// One serial writer, so a fast typist's drafts land in order (web writes per keystroke).
  private func scheduleDraft() {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    pendingDraft = (threadID, value)
    guard draftWriter == nil else { return }
    draftWriter = Task { [weak self] in
      while let self, let next = self.pendingDraft {
        self.pendingDraft = nil
        await self.store.setDraft(sourceID: self.sourceID, threadID: next.thread, text: next.text)
      }
      self?.draftWriter = nil
    }
  }
  func flushDraft() async {
    scheduleDraft()
    await draftWriter?.value
  }

  // MARK: Sending

  var runModel: String { threadID == nil ? newConversationModel : thread?.runModel ?? "" }
  var runEffort: String { threadID == nil ? newConversationEffort : thread?.runEffort ?? "" }

  /// Send (idle) or queue live input (running). Never resends a previous attempt.
  func send() async {
    guard affordances.primaryEnabled else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = store.stagedAttachments.map(\.id)
    let input = ApiStartSubmission(
      submissionId: "", text: trimmed.isEmpty ? nil : trimmed, quote: quote,
      attachmentIds: attachments.isEmpty ? nil : attachments,
      model: runModel.isEmpty ? nil : runModel, effort: runEffort.isEmpty ? nil : runEffort)
    await submit(
      ComposerAttempt(
        input: input, threadID: threadID, draftContext: nil, liveInput: running, sourceText: text))
  }

  /// A suggested reply sends its label as a plain user message (web `ReplyOptionsPart`).
  @discardableResult
  func sendReply(_ label: String) async -> Bool {
    guard isSelectedContext, store.canSend, !phase.isSending, let threadID else { return false }
    let input = ApiStartSubmission(
      submissionId: "", text: label, model: runModel.isEmpty ? nil : runModel,
      effort: runEffort.isEmpty ? nil : runEffort)
    await submit(
      ComposerAttempt(
        input: input, threadID: threadID, draftContext: nil, liveInput: running, sourceText: nil))
    if case .confirmed = phase { return true }
    return false
  }

  /// Explicit retry of the frozen attempt: identical payload, so the same submission UUID.
  func retry() async {
    guard var attempt = lastAttempt, phase.allowsRetry else { return }
    attempt.liveInput = running
    await submit(attempt)
  }

  private func submit(_ attempt: ComposerAttempt) async {
    var attempt = attempt
    phase = .sending(liveInput: attempt.liveInput)
    confirmationReset?.cancel()
    lastAttempt = attempt
    do {
      if attempt.threadID == nil {
        // A new conversation is created before submission recovery; its draft context is the
        // source's new-conversation key, which admission then clears.
        await flushDraft()
        let context = DraftKey(profileID: store.profile.id, sourceID: sourceID, threadID: nil)
        let created = try await store.createConversation(
          ApiCreateThread(
            sourceId: sourceID,
            model: newConversationModel.isEmpty ? .omitted : .value(newConversationModel),
            effort: newConversationEffort.isEmpty ? .omitted : .value(newConversationEffort)),
          retainingAttachments: attempt.input.attachmentIds ?? [])
        attempt.threadID = created
        attempt.draftContext = context
        lastAttempt = attempt
        threadID = created
        onCreate(created)
      } else {
        await flushDraft()
      }
      guard let target = attempt.threadID else { return }
      let receipt = try await store.submit(
        sourceID: sourceID, threadID: target, input: attempt.input,
        draftContext: attempt.draftContext)
      phase = ComposerRules.phase(after: receipt)
      admitted(attempt)
    } catch {
      let dispatched = store.pendingSubmissions.contains {
        $0.threadID == attempt.threadID && $0.dispatched
      }
      phase = ComposerRules.phase(after: error, possiblyDispatched: dispatched)
      // The composer states this submission's outcome itself; don't repeat the Store's
      // generic copy as a transcript-wide "update failed" banner.
      if let message = store.errorMessage,
        message.hasPrefix("Submission is uncertain") || message.hasPrefix("The console rejected")
      {
        store.clearErrorMessage()
      }
      if attempt.draftContext != nil, let created = attempt.threadID, attempt.sourceText != nil {
        // The conversation exists now; keep the unsent text with it (web transferComposerDraft).
        await store.setDraft(sourceID: sourceID, threadID: created, text: text)
        await store.setDraft(sourceID: sourceID, threadID: nil, text: "")
      }
    }
  }

  private func admitted(_ attempt: ComposerAttempt) {
    store.clearErrorMessage()
    if let source = attempt.sourceText, text == source {
      // Only the exact text that was sent is cleared; a newer edit survives (Store rule).
      restoring = true
      text = ""
      restoring = false
      selection = TextSelection(insertionPoint: text.endIndex)
      if attempt.draftContext == nil { scheduleDraft() }
      quote = nil
    }
    if attempt.sourceText != nil, quote == attempt.input.quote { quote = nil }
    lastAttempt = nil
    confirmationReset = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled, let self, case .confirmed = self.phase else { return }
      self.phase = .idle
    }
  }

  func dismissStatus() {
    guard !phase.isSending else { return }
    phase = .idle
    lastAttempt = nil
  }

  /// Stop through the Store's cancel route; never touches the submission journal.
  func stop() async {
    guard let threadID, running, !stopping else { return }
    stopping = true
    stopError = nil
    do {
      try await store.cancel(threadID: threadID)
    } catch {
      stopError = "Could not stop the response. Try again."
    }
    stopping = false
  }

  /// The `/new` command: navigation is owned by the dashboard shell.
  func requestNewConversation() { onNewConversation() }

  // MARK: Run settings

  func setModel(_ model: String) {
    guard let agent else { return }
    let effort = ModelOptions.effortAfterSwitching(agent, to: model, currentEffort: runEffort)
    if let threadID {
      store.setRunOverride(
        threadID: threadID, model: model, effort: effort == runEffort ? nil : effort)
    } else {
      newConversationModel = model
      newConversationEffort = effort
    }
  }
  func setEffort(_ effort: String) {
    if let threadID {
      store.setRunOverride(threadID: threadID, model: nil, effort: effort)
    } else {
      newConversationEffort = effort
    }
  }
  var hasRunOverride: Bool { !runModel.isEmpty || !runEffort.isEmpty }
  func resetRunSettings() {
    if let threadID {
      store.setRunOverride(threadID: threadID, model: "", effort: "")
    } else {
      newConversationModel = ""
      newConversationEffort = ""
    }
  }

  // MARK: Quote and insertion

  func setQuote(_ value: WebQuote) {
    quote = value
    focusRequest &+= 1
  }

  /// Inserts text at the caret (peer replies), on its own paragraph.
  func insertBlock(_ block: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = trimmed.isEmpty ? block : text + (text.hasSuffix("\n") ? "\n" : "\n\n") + block
    selection = TextSelection(insertionPoint: text.endIndex)
    focusRequest &+= 1
  }

  // MARK: Triggers

  var caret: (start: Int, end: Int) {
    guard case .selection(let range)? = selection?.indices,
      range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex
    else { return (text.count, text.count) }
    return (
      text.distance(from: text.startIndex, to: range.lowerBound),
      text.distance(from: text.startIndex, to: range.upperBound)
    )
  }
  var trigger: TriggerQuery? {
    let caret = caret
    let found =
      SkillDiscovery.detect("$", in: text, selectionStart: caret.start, selectionEnd: caret.end)
      ?? SkillDiscovery.detect("/", in: text, selectionStart: caret.start, selectionEnd: caret.end)
    return found == dismissedTrigger ? nil : found
  }
  var skillRegistry: SkillRegistryState? { store.skillRegistries[sourceID] }
  var skillSuggestions: [WebSkillInfo] {
    guard let trigger, trigger.character == "$", let registry = skillRegistry,
      registry.canInsert
    else { return [] }
    return SkillDiscovery.rank(registry.items, query: trigger.query)
  }
  var commandSuggestions: [ComposerCommand] {
    guard let trigger, trigger.character == "/" else { return [] }
    return ComposerCommand.available(
      running: running, hasRunSettings: agent?.models?.isEmpty == false || agent?.efforts != nil,
      hasAgent: agent != nil, attachmentCount: store.stagedAttachments.count, query: trigger.query)
  }

  /// Mirrors Composer.tsx `insertSkill`: autocomplete re-validates the live query and replaces
  /// it; browse inserts at the selection saved when the sheet opened.
  func insertSkill(_ name: String, browseRange: (start: Int, end: Int)? = nil) {
    guard let registry = skillRegistry, registry.canInsert,
      let skill = registry.items.first(where: { $0.name == name }),
      SkillDiscovery.isUsable(skill), let reference = skill.reference
    else { return }
    let range: (start: Int, end: Int)
    if let browseRange {
      range = browseRange
    } else {
      guard let query = trigger, query.character == "$",
        SkillDiscovery.rank(registry.items, query: query.query).contains(where: {
          $0.name == name
        })
      else { return }
      range = (query.offset, query.cursor)
    }
    let inserted = SkillDiscovery.insert(reference, into: text, start: range.start, end: range.end)
    apply(inserted)
  }

  func run(_ command: ComposerCommand) -> ComposerCommand {
    if let trigger, trigger.character == "/" { apply(SkillDiscovery.remove(trigger, from: text)) }
    return command
  }

  private func apply(_ insertion: TextInsertion) {
    text = insertion.text
    let index =
      text.index(
        text.startIndex, offsetBy: min(insertion.caret, text.count), limitedBy: text.endIndex)
      ?? text.endIndex
    selection = TextSelection(insertionPoint: index)
    focusRequest &+= 1
  }

  // MARK: Attachments

  func stage(_ files: [UploadFile], previews picked: [String: UIImage] = [:]) async {
    uploadError = nil
    defer { AttachmentAdapter.discard(files) }
    guard let limits = store.bootstrap?.limits, store.canUpload, isSelectedContext else {
      uploadError = "Attachments are unavailable here right now."
      return
    }
    if let problem = AttachmentAdapter.problem(
      files, limits: limits, existing: store.stagedAttachments,
      uploading: store.uploadProgress.count)
    {
      uploadError = problem
      return
    }
    for (name, image) in picked { previews["name:" + name] = image }
    let before = Set(store.stagedAttachments.map(\.id))
    do {
      try await store.stageUploads(files)
      let added = store.stagedAttachments.filter { !before.contains($0.id) }
      for attachment in added {
        if let image = previews.removeValue(forKey: "name:" + attachment.name) {
          previews[attachment.id] = image
        }
      }
    } catch {
      uploadError = AttachmentAdapter.message(for: error)
      for file in files { previews["name:" + file.name] = nil }
    }
  }

  func remove(_ attachment: WebAttachment) async {
    previews[attachment.id] = nil
    await store.discardStagedUpload(attachment.id)
  }
}
