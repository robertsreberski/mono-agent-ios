// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// AskUser question form (web `AskUserTool`): 1–5 questions with options, multi-select and a
/// custom reply, submitted through the Store's `answerAsk` (`POST /threads/:id/ask`).
struct AskUserCard: View {
  let call: WebToolCall
  let message: WebMessage
  let store: ConsoleStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var interaction = AskInteractionState()
  private var snapshot: ChannelAskSnapshot? { interaction.snapshot }
  private var submitting: Bool { interaction.submitting }
  @State private var assignedID: String?
  @State private var unavailable = false
  @State private var draft = AskFormDraft()
  @State private var error: String?
  @Environment(\.consoleTheme) private var theme

  private var expectedID: String? {
    AskForm.interactionID(call.structuredResult) ?? AskForm.interactionID(call.result)
  }
  private var persisted: String? {
    AskForm.persistedStatus(call.structuredResult) ?? AskForm.persistedStatus(call.result)
  }
  private var running: Bool { call.status == "running" }
  private var interrupted: Bool {
    TranscriptPresentation.failed(call) && !running && call.result == nil
      && call.structuredResult == nil
  }
  private var contextMessage: String? {
    if let text = snapshot?.message { return text }
    if case .object(let args)? = call.args, case .string(let text)? = args["message"] {
      return text
    }
    return nil
  }
  private var terminal: String? {
    AskInteractionState.terminal(snapshot: snapshot, persisted: persisted)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(
        interrupted ? "Question interrupted" : "Input needed",
        systemImage: interrupted ? "exclamationmark.circle" : "questionmark.circle"
      )
      .webFont(.jobTitle)
      .foregroundStyle(interrupted ? WebColor.textMuted.color : WebColor.text.color)
      .accessibilityAddTraits(.isHeader)
      if let contextMessage {
        ScrollView {
          Text(contextMessage).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
        }
        .frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
        .background(WebColor.surfaceSubtle.color, in: RoundedRectangle(cornerRadius: 8))
      }
      content
    }
    .webFormCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Question from the agent")
    .accessibilityIdentifier("ask-card")
    .task(id: pollKey) { await poll() }
  }

  @ViewBuilder private var content: some View {
    if interrupted {
      EmptyView()
    } else if let snapshot, let terminal {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        Text(terminal == "answered" ? "Answers submitted." : "Question \(terminal).")
          .webFont(.askLegend)
        ForEach(AskForm.summary(snapshot), id: \.self) { line in
          Text(line).webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("ask-complete")
    } else if let snapshot {
      form(snapshot)
    } else if let terminal {
      Text(terminal == "answered" ? "Answers submitted." : "Question \(terminal).")
        .webFont(.askLegend).accessibilityIdentifier("ask-complete")
    } else if unavailable {
      Text("Question unavailable. It may have expired, been evicted, or the agent may be offline.")
        .webFont(.askContext).foregroundStyle(WebColor.textSoft.color)
    } else {
      Label("Preparing the questions…", systemImage: "hourglass").webFont(.askContext)
    }
  }

  private func form(_ snapshot: ChannelAskSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(snapshot.questions.enumerated()), id: \.element.id) { index, question in
        let prior =
          index < snapshot.activeQuestionIndex
          ? snapshot.answers.first { $0.questionId == question.id } : nil
        QuestionFields(
          question: question, draft: $draft, prior: prior, disabled: prior != nil || submitting
        )
        .padding(.bottom, index < snapshot.questions.count - 1 ? 16 : 0)
        .overlay(alignment: .bottom) {
          if index < snapshot.questions.count - 1 {
            Rectangle().fill(WebColor.line.color).frame(height: 1)
          }
        }
      }
      if let error {
        StatusIndicator(.failed, label: error).accessibilityIdentifier("ask-error")
      }
      if let missing = AskForm.firstIncomplete(snapshot, draft), !submitting {
        Text(
          missing.multiSelect
            ? "Choose at least one answer for “\(missing.header)”."
            : "Choose one answer or write a custom reply for “\(missing.header)”."
        )
        .webFont(.askDetail).foregroundStyle(WebColor.textSoft.color)
      }
      Button(
        submitting
          ? "Submitting…" : snapshot.questions.count == 1 ? "Submit answer" : "Submit answers"
      ) {
        Task { await submit(snapshot) }
      }
      .buttonStyle(WebSubmitButtonStyle())
      .disabled(!AskForm.isComplete(snapshot, draft) || submitting)
      .accessibilityIdentifier("ask-submit")
    }
  }

  private var pollKey: String {
    [
      message.threadId, call.toolCallId, call.status, expectedID ?? "",
      persisted ?? "", String(describing: scenePhase),
      store.connection == .live ? "live" : "not-live",
    ].joined(separator: "|")
  }

  /// Web AskReconciliation: exact by-id reads when the id is known, otherwise the pending ask
  /// while the call runs; 250 ms → 2 s backoff (doubled on a lean link); hidden scenes ask
  /// nothing and conclude nothing.
  private func poll() async {
    guard !interrupted, scenePhase == .active else { return }
    let lean = store.effectiveDataMode == .lean
    if lean, persisted != nil, !running { return }
    var delay = lean ? 0.5 : 0.25
    let maximum = lean ? 4.0 : 2.0
    while !Task.isCancelled {
      if snapshot.map({ $0.status != "pending" }) == true { return }
      // A persisted terminal result closes the form immediately. By-id agents can still
      // hydrate its answer summary after a lazy transcript row is recreated; legacy agents
      // have only a pending endpoint, so a retained pending snapshot must not keep polling.
      if persisted != nil,
        store.agents.first(where: {
          $0.sourceId == store.conversations[message.threadId]?.thread.sourceId
        })?.supportsAskById == false
      {
        return
      }
      // Not live: conclude nothing yet; the poll restarts when the connection does.
      guard store.connection == .live else { return }
      let id = expectedID ?? assignedID
      if id == nil && !running {
        unavailable = true
        return
      }
      let revision = interaction.revision
      do {
        if let value = try await store.askSnapshot(threadID: message.threadId, interactionID: id) {
          let now = await store.serverNow()
          guard !Task.isCancelled, scenePhase == .active else { return }
          interaction.applyPoll(AskForm.normalized(value, now: now), revision: revision)
          assignedID = value.interactionId
          unavailable = false
        } else if id != nil {
          unavailable = true
        }
      } catch is CancellationError {
        return
      } catch {
        unavailable = true
      }
      if snapshot.map({ $0.status != "pending" }) == true { return }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      delay = min(maximum, delay * 2)
    }
  }

  private func submit(_ snapshot: ChannelAskSnapshot) async {
    guard terminal == nil, AskForm.isComplete(snapshot, draft), interaction.beginSubmission()
    else { return }
    error = nil
    do {
      let next = try await store.answerAsk(
        threadID: message.threadId, interactionID: snapshot.interactionId,
        answers: AskForm.answers(snapshot, draft))
      if let next {
        interaction.finishSubmission(next)
      } else {
        var answered = snapshot
        answered.status = "answered"
        answered.answers = AskForm.answers(snapshot, draft)
        interaction.finishSubmission(answered)
      }
    } catch AskAnswerError.incomplete {
      error = "Please complete every question."
    } catch AskAnswerError.inactive {
      error = "This question is no longer active."
    } catch {
      self.error = "Could not submit the answer."
    }
    interaction.finishSubmission(nil)
  }
}

private struct QuestionFields: View {
  let question: ChannelAskQuestion
  @Binding var draft: AskFormDraft
  let prior: ChannelAskAnswer?
  let disabled: Bool
  @Environment(\.consoleTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(question.header).webFont(.contextEyebrow).foregroundStyle(theme.palette.accent.color)
        Text(question.question).webFont(.askLegend)
        if question.multiSelect {
          Text("Choose any").webFont(.askDetail).foregroundStyle(WebColor.textSoft.color)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      ForEach(question.options, id: \.id) { option in
        let selected =
          prior.map { $0.selectedOptionIds.contains(option.id) }
          ?? draft.isSelected(option.id, in: question)
        Button {
          draft.toggle(option.id, in: question)
        } label: {
          ChoiceRow(
            option.label, detail: option.description, selected: selected,
            multiple: question.multiSelect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier("ask-option-\(question.id)-\(option.id)")
      }
      TextField(
        "Custom reply",
        text: Binding(
          get: { prior?.customReply ?? draft.custom[question.id] ?? "" },
          set: { draft.setCustom($0, for: question) }), axis: .vertical
      )
      .webInput()
      .lineLimit(1...4)
      .disabled(disabled)
      .accessibilityLabel("Custom reply for \(question.header)")
      .accessibilityIdentifier("ask-custom-\(question.id)")
    }
  }
}

/// Suggested replies beneath a final answer (web `ReplyOptionsPart`). Tapping one sends its
/// label through the composer's submission path; they disable while running, after a later
/// user message, once one was sent, or when the conversation is not the composer's.
struct QuickRepliesView: View {
  let part: ReplyOptionsPart
  let message: WebMessage
  let store: ConsoleStore
  @Environment(\.composerActions) private var actions
  @State private var sent = false
  @State private var sending = false

  private var laterUser: Bool {
    guard let state = store.conversations[message.threadId],
      let index = state.orderedMessageIDs.firstIndex(of: message.id)
    else { return true }
    return state.orderedMessageIDs[(index + 1)...].contains {
      state.messageStates[$0]?.message.role == "user"
    }
  }
  private var disabled: Bool {
    let running =
      store.conversations[message.threadId].map {
        $0.runningConfirmed && $0.thread.runState.status == "running"
      } ?? false
    return message.status != "complete" || running || laterUser || sent || sending
      || actions.sendReply == nil || actions.threadID != message.threadId
  }

  var body: some View {
    let buttons = ForEach(part.options, id: \.self) { label in
      Button(label) {
        guard !disabled, let send = actions.sendReply else { return }
        sending = true
        Task {
          sent = await send(label)
          sending = false
        }
      }
      .buttonStyle(WebReplyButtonStyle())
      .disabled(disabled)
      .accessibilityIdentifier("quick-reply-" + label)
    }
    WebFlowLayout(spacing: 8, lineSpacing: 8) { buttons }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Suggested replies")
      .accessibilityIdentifier("quick-replies")
  }
}

/// The peer-answer form, driven by the question model and a submit seam. The console has no
/// peer answer route and the web shows peer text as untrusted reference: the default seam
/// drafts a reply into the composer for the operator to send to their own agent explicitly.
struct PeerQuestionAnswerSheet: View {
  let question: PeerProcessJobQuestion
  let submit: @MainActor (String) async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var values: [String: [String]] = [:]
  @State private var note = ""
  @State private var error: String?

  private var fields: [PeerQuestionField] { PeerQuestionForm.describe(question.requestedSchema) }
  private var open: Bool { question.state == "awaiting_answer" }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("State", value: PeerQuestionForm.stateLabel(question.state))
          LabeledContent("Peer", value: question.peer + " / " + question.thread)
          if let expires = TranscriptPresentation.date(question.expiresAt) {
            LabeledContent(
              "Expires", value: expires.formatted(date: .abbreviated, time: .shortened))
          }
          Text(question.message).textSelection(.enabled)
        } footer: {
          Text("Untrusted peer text; not owner approval. The agent answers through PeerAgent.")
        }
        ForEach(fields) { field in
          Section {
            if let description = field.description {
              Text(description).webFont(.askDetail).foregroundStyle(WebColor.textSoft.color)
            }
            ForEach(field.options, id: \.self) { option in
              Button {
                toggle(option, in: field)
              } label: {
                ChoiceRow(
                  option, selected: values[field.key]?.contains(option) == true,
                  multiple: field.multiple)
              }
              .buttonStyle(.plain)
              .disabled(!open)
              .accessibilityIdentifier("peer-option-\(field.key)-\(option)")
            }
            if field.options.isEmpty {
              TextField(
                field.freeText ? "Answer" : "Value",
                text: Binding(
                  get: { values[field.key]?.first ?? "" }, set: { values[field.key] = [$0] }),
                axis: .vertical
              )
              .disabled(!open)
              .accessibilityIdentifier("peer-text-\(field.key)")
            }
          } header: {
            Text(
              field.label + (field.required ? " · required" : "")
                + (field.multiple ? " · choose any" : ""))
          }
        }
        Section("Note to your agent") {
          TextField("Optional context", text: $note, axis: .vertical)
            .webInput()
            .disabled(!open)
            .accessibilityIdentifier("peer-note")
        }
        Section("Raw form") {
          Text("questionId " + question.questionId).webFont(.askDetail)
          CodeDocumentView(source: rawSchema, language: "JSON schema")
        }
        if let error {
          StatusIndicator(.failed, label: error)
        }
      }
      .scrollContentBackground(.hidden)
      .background(WebColor.surfaceSubtle.color)
      .webFont(.contextNote)
      .listRowBackground(WebColor.surfaceRaised.color)
      .navigationTitle("Peer question")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await send() }
          } label: {
            if typeSize.isAccessibilitySize {
              Image(systemName: "text.badge.plus")
            } else {
              Text("Add to Composer")
            }
          }
          .accessibilityLabel("Add to Composer")
          .disabled(!open || !PeerQuestionForm.missingRequired(fields, values: values).isEmpty)
          .accessibilityHint("Drafts the reply in the composer; you send it yourself")
          .accessibilityIdentifier("peer-submit")
        }
      }
    }
    .accessibilityIdentifier("peer-sheet")
  }

  private var rawSchema: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(question.requestedSchema)).map {
      String(decoding: $0, as: UTF8.self)
    } ?? "{}"
  }

  private func toggle(_ option: String, in field: PeerQuestionField) {
    var current = values[field.key] ?? []
    if field.multiple {
      if let index = current.firstIndex(of: option) {
        current.remove(at: index)
      } else {
        current.append(option)
      }
    } else {
      current = current == [option] ? [] : [option]
    }
    values[field.key] = current
  }

  private func send() async {
    do {
      try await submit(
        PeerQuestionForm.reply(question, fields: fields, values: values, note: note))
      dismiss()
    } catch {
      self.error = "The composer is not available for this conversation."
    }
  }
}
