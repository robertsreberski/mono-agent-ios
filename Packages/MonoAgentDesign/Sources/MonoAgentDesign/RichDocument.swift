// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Markdown

/// App-owned, bounded value tree. No parser nodes cross an actor boundary.
public struct RichDocument: Sendable, Equatable {
  public struct Run: Sendable, Hashable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strike = false
    public var image = false
    public var link: String?
  }
  public struct Block: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: Kind
    public var depth: Int
    public var prefix: String
    public var runs: [Run]
    public var rows: [[[Run]]] = []
    public enum Kind: Sendable, Equatable {
      case paragraph
      case heading(Int)
      case code(String)
      case quote, rule, table
    }
  }
  public var blocks: [Block]
  public var limited: Bool
  public static let maximumBytes = 65_536

  /// Limits precede cmark, not just view traversal: huge tables/nesting cannot expand the AST.
  public static func parse(_ source: String, cancelled: () -> Bool = { false }) -> RichDocument {
    let head = String(decoding: source.utf8.prefix(maximumBytes), as: UTF8.self)
    var limited = source.utf8.count > maximumBytes
    let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
    var nesting = 0
    var deep = false
    for byte in head.utf8 {
      if byte == 91 || byte == 40 {
        nesting += 1
        if nesting > 32 {
          deep = true
          break
        }
      }
      if byte == 93 || byte == 41 { nesting = max(0, nesting - 1) }
    }
    let hostile =
      deep
      || lines.contains { line in
        line.utf8.count > 4096 || line.filter { $0 == "|" }.count > 24
          || line.prefix(while: { $0 == ">" || $0 == " " }).filter { $0 == ">" }.count > 12
          || line.prefix(while: { $0 == " " }).count > 48
      } || head.filter { "[]*_`".contains($0) }.count > 4096 || lines.count > 2048
    if hostile {
      return RichDocument(
        blocks: [
          .init(
            id: 0, kind: .code("Plain text"), depth: 0,
            prefix: "", runs: [.init(text: head)])
        ], limited: true)
    }
    guard !cancelled() else { return RichDocument(blocks: [], limited: false) }
    let document = Document(parsing: head, options: [.parseSymbolLinks])
    var blocks: [Block] = []
    var remaining = 1800
    func inline(_ node: any Markup, depth: Int = 0, style: Run = .init(text: "")) -> [Run] {
      guard !cancelled(), depth < 16, remaining > 0 else {
        limited = true
        return []
      }
      remaining -= 1
      var style = style
      if let text = node as? Markdown.Text {
        style.text = text.string
        return [style]
      }
      if let code = node as? InlineCode {
        style.text = code.code
        style.code = true
        return [style]
      }
      if let html = node as? InlineHTML {
        style.text = html.rawHTML
        return [style]
      }
      if node is SoftBreak || node is LineBreak {
        style.text = "\n"
        return [style]
      }
      if node is Strong { style.bold = true }
      if node is Emphasis { style.italic = true }
      if node is Strikethrough { style.strike = true }
      if let link = node as? Markdown.Link, let destination = link.destination,
        let url = URL(string: destination),
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
      {
        style.link = destination
      }
      if let image = node as? Markdown.Image {
        let alt = image.plainText
        style.text = alt.isEmpty ? "Image" : alt.count > 200 ? String(alt.prefix(199)) + "…" : alt
        style.image = true
        // Preserve a validated enclosing link, never the image source URL.
        return [style]
      }
      return node.children.flatMap { inline($0, depth: depth + 1, style: style) }
    }
    func walk(_ node: any Markup, depth: Int = 0, prefix: String = "", quoted: Bool = false) {
      guard !cancelled(), depth < 13, remaining > 0, blocks.count < 300 else {
        limited = true
        return
      }
      remaining -= 1
      func append(_ kind: Block.Kind, _ runs: [Run], rows: [[[Run]]] = []) {
        blocks.append(
          .init(
            id: blocks.count, kind: kind, depth: depth, prefix: prefix,
            runs: runs, rows: rows))
      }
      if let code = node as? CodeBlock {
        append(.code(code.language ?? "Code"), [.init(text: code.code)])
        return
      }
      if let html = node as? HTMLBlock {
        append(.code("HTML · shown as text"), [.init(text: html.rawHTML)])
        return
      }
      if let table = node as? Markdown.Table {
        var rows = [table.head.children.prefix(12).map { inline($0) }]
        for row in table.body.children.prefix(80) {
          rows.append(row.children.prefix(12).map { inline($0) })
        }
        if table.body.childCount > 80 || table.maxColumnCount > 12 { limited = true }
        append(.table, [], rows: rows)
        return
      }
      if node is ThematicBreak {
        append(.rule, [])
        return
      }
      if let heading = node as? Heading {
        append(.heading(heading.level), inline(heading))
        return
      }
      if node is Paragraph {
        append(quoted ? .quote : .paragraph, inline(node))
        return
      }
      if node is UnorderedList || node is OrderedList {
        let start = (node as? OrderedList)?.startIndex ?? 1
        for (index, child) in node.children.enumerated() {
          let item = child as? ListItem
          let bullet =
            item?.checkbox.map { $0 == .checked ? "☑" : "☐" }
            ?? (node is OrderedList ? "\(start + UInt(index))." : "•")
          for (offset, content) in child.children.enumerated() {
            walk(content, depth: depth + 1, prefix: offset == 0 ? bullet : "", quoted: quoted)
          }
        }
        return
      }
      for child in node.children {
        walk(
          child, depth: depth + (node is BlockQuote ? 1 : 0),
          prefix: prefix, quoted: quoted || node is BlockQuote)
      }
    }
    walk(document)
    return RichDocument(blocks: blocks, limited: limited)
  }
}
