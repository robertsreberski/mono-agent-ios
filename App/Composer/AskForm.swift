// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// The operator's in-progress answers to one AskUser interaction (web `AskUserTool` state).
struct AskFormDraft: Equatable {
  var selected: [String: [String]] = [:]
  var custom: [String: String] = [:]

  /// Single-select replaces the choice and clears the custom reply; multi-select toggles.
  mutating func toggle(_ optionID: String, in question: ChannelAskQuestion) {
    var current = selected[question.id] ?? []
    if question.multiSelect {
      if let index = current.firstIndex(of: optionID) {
        current.remove(at: index)
      } else {
        current.append(optionID)
      }
    } else {
      current = [optionID]
      custom[question.id] = ""
    }
    selected[question.id] = current
  }

  /// A non-blank custom reply on a single-select question replaces the selected option.
  mutating func setCustom(_ text: String, for question: ChannelAskQuestion) {
    custom[question.id] = text
    if !question.multiSelect && !text.trimmingCharacters(in: .whitespaces).isEmpty {
      selected[question.id] = []
    }
  }

  func isSelected(_ optionID: String, in question: ChannelAskQuestion) -> Bool {
    selected[question.id]?.contains(optionID) == true
  }

  /// Count of answers for a question: chosen options plus a non-blank custom reply.
  func answerCount(_ question: ChannelAskQuestion) -> Int {
    (selected[question.id]?.count ?? 0)
      + ((custom[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        ? 1 : 0)
  }
}

enum AskForm {
  /// Questions still open: the agent may already hold answers before `activeQuestionIndex`.
  static func remaining(_ snapshot: ChannelAskSnapshot) -> [ChannelAskQuestion] {
    Array(snapshot.questions.dropFirst(max(0, snapshot.activeQuestionIndex)))
  }

  /// Every remaining question is required: multi-select needs at least one answer, single
  /// select exactly one (an option or a custom reply).
  static func isComplete(_ snapshot: ChannelAskSnapshot, _ draft: AskFormDraft) -> Bool {
    let open = remaining(snapshot)
    return !open.isEmpty
      && open.allSatisfy { question in
        let count = draft.answerCount(question)
        return question.multiSelect ? count > 0 : count == 1
      }
  }

  /// The question still needing an answer, for the inline validation hint.
  static func firstIncomplete(_ snapshot: ChannelAskSnapshot, _ draft: AskFormDraft)
    -> ChannelAskQuestion?
  {
    remaining(snapshot).first { question in
      let count = draft.answerCount(question)
      return question.multiSelect ? count == 0 : count != 1
    }
  }

  static func answers(_ snapshot: ChannelAskSnapshot, _ draft: AskFormDraft) -> [ChannelAskAnswer] {
    remaining(snapshot).map { question in
      let custom = draft.custom[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return ChannelAskAnswer(
        questionId: question.id, selectedOptionIds: draft.selected[question.id] ?? [],
        customReply: custom?.isEmpty == false ? custom : nil)
    }
  }

  /// Mirrors `webAskAnsweredSummary`.
  static func summary(_ snapshot: ChannelAskSnapshot) -> [String] {
    func resolve(_ answer: ChannelAskAnswer) -> (header: String, labels: [String], custom: String?)?
    {
      guard let question = snapshot.questions.first(where: { $0.id == answer.questionId }) else {
        return nil
      }
      let labels = answer.selectedOptionIds.compactMap { id in
        question.options.first { $0.id == id }?.label
      }
      let custom = answer.customReply?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (question.header, labels, custom?.isEmpty == false ? custom : nil)
    }
    if snapshot.answers.count == 1, let resolved = resolve(snapshot.answers[0]) {
      if !resolved.labels.isEmpty { return [resolved.labels.joined(separator: ", ")] }
      return resolved.custom.map { ["Answer: " + $0] } ?? []
    }
    return snapshot.answers.compactMap { answer in
      guard let resolved = resolve(answer),
        !resolved.header.trimmingCharacters(in: .whitespaces).isEmpty
      else { return nil }
      if !resolved.labels.isEmpty {
        return resolved.header + ": " + resolved.labels.joined(separator: ", ")
      }
      return resolved.custom.map { resolved.header + ": " + $0 }
    }
  }

  /// A pending snapshot past its deadline reads as expired (web `expiredSnapshot`).
  static func normalized(_ snapshot: ChannelAskSnapshot, now: Date) -> ChannelAskSnapshot {
    guard snapshot.status == "pending", let expires = snapshot.expiresAt,
      let deadline = TranscriptPresentation.date(expires), deadline <= now
    else { return snapshot }
    var value = snapshot
    value.status = "expired"
    return value
  }

  /// The interaction id from AskUser's structured payload or result (web `askInteractionId`).
  static func interactionID(_ value: JSONValue?, depth: Int = 0) -> String? {
    guard depth <= 6, case .object(let record)? = value else { return nil }
    if case .string(let id)? = record["interactionId"],
      !id.trimmingCharacters(in: .whitespaces).isEmpty
    {
      return id
    }
    for key in ["structuredContent", "data", "result", "value"] {
      if let nested = interactionID(record[key], depth: depth + 1) { return nested }
    }
    return nil
  }

  /// The durable terminal outcome in AskUser's result (web `persistedAskStatus`).
  static func persistedStatus(_ value: JSONValue?, depth: Int = 0) -> String? {
    guard depth <= 6, case .object(let record)? = value else { return nil }
    if case .string(let id)? = record["interactionId"],
      !id.trimmingCharacters(in: .whitespaces).isEmpty
    {
      if record["answered"] == .bool(true) { return "answered" }
      if record["answered"] == .bool(false), record["reason"] == .string("timeout") {
        return "expired"
      }
      if record["answered"] == .bool(false), record["reason"] == .string("cancelled") {
        return "cancelled"
      }
    }
    for key in ["structuredContent", "data", "result", "value"] {
      if let nested = persistedStatus(record[key], depth: depth + 1) { return nested }
    }
    return nil
  }
}
