// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Quotes travel as the structured `WebQuote` of the submission (web assistant-ui `QuoteInfo`),
/// never as text pasted into the prompt. The composer shows them as a dismissible block.
enum QuoteFormatting {
  /// Generous, but keeps one tap from attaching an entire long transcript to a prompt.
  static let maximumCharacters = 4_000

  /// The quotable text of a message: its answer text parts, joined like the web's adjacent
  /// text, as the reader sees it (inline Markdown markers removed, line breaks kept).
  static func text(of message: WebMessage) -> String {
    plain(
      message.parts.compactMap { part -> String? in
        switch part {
        case .text(let value): value.text
        case .steer(let value): value.text
        default: nil
        }
      }.joined())
  }

  /// Rendered characters of inline Markdown; falls back to the source when it cannot parse.
  static func plain(_ markdown: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible)
    guard let value = try? AttributedString(markdown: markdown, options: options) else {
      return markdown
    }
    return String(value.characters)
  }

  /// A quote for a whole message or a selection of it; `nil` when nothing readable remains.
  static func quote(_ text: String, messageID: String) -> WebQuote? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !messageID.isEmpty else { return nil }
    let bounded =
      trimmed.count > maximumCharacters
      ? String(trimmed.prefix(maximumCharacters - 1)) + "…" : trimmed
    return WebQuote(text: bounded, messageId: messageID)
  }

  static func quote(message: WebMessage) -> WebQuote? {
    quote(text(of: message), messageID: message.id)
  }

  /// The one-line preview shown in the composer and spoken by VoiceOver.
  static func preview(_ quote: WebQuote, limit: Int = 140) -> String {
    let line = quote.text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }.joined(separator: " ")
    return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
  }
}
