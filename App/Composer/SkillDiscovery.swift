// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// A trigger token under the caret. Offsets count `Character`s in the composer text.
struct TriggerQuery: Equatable {
  let character: Character
  /// Offset of the trigger character itself.
  let offset: Int
  let query: String
  let cursor: Int
}

struct TextInsertion: Equatable {
  let text: String
  let caret: Int
}

/// Port of the web console's `skill-discovery.ts` (detection, ranking and insertion), plus the
/// same boundary rule for the `/` command trigger.
enum SkillDiscovery {
  static let autocompleteLimit = 8

  private static func isQueryCharacter(_ value: Character) -> Bool {
    value.isASCII && (value.isLetter || value.isNumber || value == "_" || value == "-")
  }
  private static func isTokenCharacter(_ value: Character) -> Bool {
    value.isLetter || value.isNumber || value == "_" || value == "$" || value == "-"
  }

  /// Mirrors `detectSkillQuery`: the trigger must start the text or follow whitespace, and only
  /// `[A-Za-z0-9_-]` may follow it up to a collapsed caret.
  static func detect(
    _ trigger: Character, in text: String, selectionStart: Int, selectionEnd: Int? = nil
  ) -> TriggerQuery? {
    let end = selectionEnd ?? selectionStart
    guard selectionStart == end else { return nil }
    let characters = Array(text)
    let cursor = max(0, min(selectionStart, characters.count))
    var index = cursor - 1
    while index >= 0 {
      let character = characters[index]
      if character.isWhitespace { return nil }
      if character == trigger, index == 0 || characters[index - 1].isWhitespace {
        let query = String(characters[(index + 1)..<cursor])
        return query.allSatisfy(isQueryCharacter)
          ? TriggerQuery(character: trigger, offset: index, query: query, cursor: cursor) : nil
      }
      index -= 1
    }
    return nil
  }

  static func isUsable(_ skill: WebSkillInfo) -> Bool {
    guard skill.availability != "unavailable", let reference = skill.reference,
      reference == "$" + skill.name
    else { return false }
    return isReference(reference)
  }
  static func isReference(_ value: String) -> Bool {
    let body = value.dropFirst()
    guard value.first == "$", let first = body.first, first.isASCII,
      first.isLetter || first.isNumber
    else { return false }
    return body.allSatisfy(isQueryCharacter)
  }

  /// Mirrors `rankSkills`: tiers (exact, prefix, token, substring, subsequence, description
  /// phrase, description tokens, empty query), then quality, availability, length and name.
  static func rank(
    _ skills: [WebSkillInfo], query: String, includeUnavailable: Bool = false,
    limit: Int = autocompleteLimit
  ) -> [WebSkillInfo] {
    let normalized = normalize(query.trimmingCharacters(in: .whitespaces))
    struct Match {
      let skill: WebSkillInfo
      let index: Int
      let tier: Int
      let quality: Int
    }
    let matches = skills.enumerated().compactMap { index, skill -> Match? in
      if skill.availability == "unavailable" && !includeUnavailable { return nil }
      if skill.availability != "unavailable" && !isUsable(skill) { return nil }
      guard let score = score(skill, normalized) else { return nil }
      return Match(skill: skill, index: index, tier: score.tier, quality: score.quality)
    }
    return matches.sorted { left, right in
      if left.tier != right.tier { return left.tier < right.tier }
      if left.quality != right.quality { return left.quality < right.quality }
      let availability = availabilityRank(left.skill) - availabilityRank(right.skill)
      if availability != 0 { return availability < 0 }
      if left.tier != 7 && left.skill.name.count != right.skill.name.count {
        return left.skill.name.count < right.skill.name.count
      }
      let leftName = left.skill.name.lowercased()
      let rightName = right.skill.name.lowercased()
      if leftName != rightName { return leftName < rightName }
      return left.index < right.index
    }.prefix(limit).map(\.skill)
  }

  /// Mirrors `insertSkillReference`: pads with a space where the reference would touch a
  /// neighbouring token and leaves the caret after the inserted reference and its space.
  static func insert(_ reference: String, into text: String, start: Int, end: Int)
    -> TextInsertion
  {
    let characters = Array(text)
    guard isReference(reference) else {
      return TextInsertion(text: text, caret: min(end, characters.count))
    }
    let lower = max(0, min(start, characters.count))
    let upper = max(lower, min(end, characters.count))
    let before = String(characters[..<lower])
    let after = String(characters[upper...])
    let prefix = before.last.map(isTokenCharacter) == true ? " " : ""
    let suffix = after.isEmpty || after.first.map(isTokenCharacter) == true ? " " : ""
    let caret =
      before.count + prefix.count + reference.count
      + (suffix.isEmpty ? (after.first?.isWhitespace == true ? 1 : 0) : suffix.count)
    return TextInsertion(text: before + prefix + reference + suffix + after, caret: caret)
  }

  /// Removes a command token (web `removeOnExecute`) and returns the remaining text and caret.
  static func remove(_ trigger: TriggerQuery, from text: String) -> TextInsertion {
    var characters = Array(text)
    let upper = min(trigger.cursor, characters.count)
    characters.removeSubrange(trigger.offset..<upper)
    return TextInsertion(text: String(characters), caret: trigger.offset)
  }

  static func statusLabel(_ skill: WebSkillInfo) -> String {
    switch skill.availability {
    case "inlined": "In prompt"
    case "on-demand": "On demand"
    default:
      switch skill.unavailableReason {
      case "read-skill-disabled": "ReadSkill disabled"
      case "unsupported-name": "Unsupported name"
      default: "Not selected"
      }
    }
  }

  private static func availabilityRank(_ skill: WebSkillInfo) -> Int {
    skill.availability == "inlined" ? 0 : skill.availability == "on-demand" ? 1 : 2
  }
  static func normalize(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
  }
  private static func score(_ skill: WebSkillInfo, _ query: String) -> (tier: Int, quality: Int)? {
    if query.isEmpty { return (7, 0) }
    let name = normalize(skill.name)
    if name == query { return (0, 0) }
    if name.hasPrefix(query) { return (1, name.count - query.count) }
    let tokens = name.split(whereSeparator: { $0 == "-" || $0 == "_" })
    if let index = tokens.firstIndex(where: { $0.hasPrefix(query) }) { return (2, index) }
    if let range = name.range(of: query) {
      return (3, name.distance(from: name.startIndex, to: range.lowerBound))
    }
    if let quality = subsequence(Array(name), Array(query)) { return (4, quality) }
    let description = normalize(skill.description)
    if let range = description.range(of: query) {
      return (5, description.distance(from: description.startIndex, to: range.lowerBound))
    }
    let separator: (Character) -> Bool = { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
    let needles = query.split(whereSeparator: separator)
    let words = description.split(whereSeparator: separator)
    if !needles.isEmpty, needles.allSatisfy({ needle in words.contains { $0.hasPrefix(needle) } }) {
      return (6, needles.count)
    }
    return nil
  }
  private static func subsequence(_ value: [Character], _ query: [Character]) -> Int? {
    var cursor = 0
    var first = -1
    var last = -1
    for character in query {
      guard let index = value[cursor...].firstIndex(of: character) else { return nil }
      if first < 0 { first = index }
      last = index
      cursor = index + 1
    }
    return first < 0 ? nil : (last - first + 1) - query.count + first
  }
}

/// The `/` command menu (web `buildComposerCommands`).
enum ComposerCommand: String, CaseIterable, Identifiable {
  case settings, stop, new
  var id: String { rawValue }
  var label: String {
    switch self {
    case .settings: "Run settings"
    case .stop: "Stop response"
    case .new: "New conversation"
    }
  }
  var detail: String {
    switch self {
    case .settings: "Choose the model and reasoning effort"
    case .stop: "Cancel the current agent run"
    case .new: "Start a clean conversation with this agent"
    }
  }
  var systemImage: String {
    switch self {
    case .settings: "slider.horizontal.3"
    case .stop: "stop.fill"
    case .new: "square.and.pencil"
    }
  }
  static func available(
    running: Bool, hasRunSettings: Bool, hasAgent: Bool, attachmentCount: Int, query: String
  ) -> [ComposerCommand] {
    var commands: [ComposerCommand] = []
    if !running && hasRunSettings { commands.append(.settings) }
    if running { commands.append(.stop) }
    if !running && hasAgent && attachmentCount == 0 { commands.append(.new) }
    let needle = SkillDiscovery.normalize(query)
    guard !needle.isEmpty else { return commands }
    return commands.filter {
      SkillDiscovery.normalize($0.label).contains(needle) || $0.rawValue.hasPrefix(needle)
    }
  }
}
