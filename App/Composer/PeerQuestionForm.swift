// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Display summary of one untrusted PeerAgent form field (web `PeerQuestionFieldView`).
struct PeerQuestionField: Equatable, Identifiable {
  let key: String
  let label: String
  var description: String?
  let options: [String]
  let required: Bool
  let multiple: Bool
  let freeText: Bool
  var id: String { key }
}

/// Port of `peer-question-form.ts`. The peer bridge is the only validator; this is display and
/// the operator's reply draft. Nothing here answers the peer: the console has no answer route,
/// and the agent answers through PeerAgent.
enum PeerQuestionForm {
  static let textLimit = 200
  static let fieldLimit = 20
  static let optionLimit = 12
  /// The PeerAgent "Other" sentinel option; its free-text sibling carries the reply.
  static let customSentinel = "__mono_agent_custom__"

  static func text(_ value: JSONValue?) -> String? {
    guard case .string(let raw)? = value else { return nil }
    let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return collapsed.count > textLimit ? String(collapsed.prefix(textLimit - 1)) + "…" : collapsed
  }

  static func options(_ schema: [String: JSONValue]) -> [String] {
    for key in ["oneOf", "anyOf"] {
      if case .array(let choices)? = schema[key] {
        return choices.compactMap { choice in
          guard case .object(let record) = choice else { return nil }
          if let title = text(record["title"]) { return title }
          if case .string? = record["const"] { return text(record["const"]) }
          return nil
        }
      }
    }
    guard case .array(let values)? = schema["enum"] else { return [] }
    let names: [JSONValue] = if case .array(let list)? = schema["enumNames"] { list } else { [] }
    return values.enumerated().compactMap { index, value in
      let primitive: String? =
        switch value {
        case .string(let text): text
        case .number(let number):
          Int(exactly: number).map(String.init) ?? String(number)
        case .bool(let flag): String(flag)
        default: nil
        }
      return text(names.indices.contains(index) ? names[index] : nil)
        ?? text(primitive.map(JSONValue.string))
    }
  }

  static func describe(_ schema: [String: JSONValue]) -> [PeerQuestionField] {
    guard case .object(let properties)? = schema["properties"] else { return [] }
    let required: Set<String> =
      if case .array(let keys)? = schema["required"] {
        Set(
          keys.compactMap {
            if case .string(let key) = $0 { return key }
            return nil
          })
      } else {
        []
      }
    // JSON objects are unordered once decoded; sort keys so the form is stable.
    return properties.keys.sorted().prefix(fieldLimit).compactMap { key in
      guard case .object(let property)? = properties[key] else { return nil }
      let multiple = property["type"] == .string("array")
      let source: [String: JSONValue] =
        if multiple, case .object(let items)? = property["items"] { items } else { property }
      let all = options(source)
      let bounded =
        all.count > optionLimit
        ? Array(all.prefix(optionLimit)) + ["+\(all.count - optionLimit) more"]
        : all
      let type = source["type"]
      return PeerQuestionField(
        key: text(.string(key)) ?? "field",
        label: text(property["title"]) ?? text(.string(key)) ?? "field",
        description: text(property["description"]), options: bounded,
        required: required.contains(key), multiple: multiple,
        freeText: bounded.isEmpty && (type == .string("string") || type == nil))
    }
  }

  static func stateLabel(_ state: String) -> String {
    switch state {
    case "awaiting_answer": "Waiting for the agent's answer"
    case "answered": "Answered"
    case "expired": "Expired"
    default: "Interrupted"
    }
  }

  /// Required fields need a value (an option or text); others may stay blank.
  static func missingRequired(_ fields: [PeerQuestionField], values: [String: [String]])
    -> [PeerQuestionField]
  {
    fields.filter { field in
      field.required
        && (values[field.key] ?? []).allSatisfy {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  /// The reply the operator hands to their own agent, who answers the peer through PeerAgent.
  /// Plain text in the composer; the operator reviews and sends it explicitly.
  static func reply(
    _ question: PeerProcessJobQuestion, fields: [PeerQuestionField], values: [String: [String]],
    note: String
  ) -> String {
    var lines = [
      "Answer for the \(question.peer) peer question (\(question.thread), id \(question.questionId)):"
    ]
    for field in fields {
      let value = (values[field.key] ?? []).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard !value.isEmpty else { continue }
      lines.append("- \(field.label): \(value.joined(separator: ", "))")
    }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { lines.append(trimmed) }
    return lines.joined(separator: "\n")
  }
}
