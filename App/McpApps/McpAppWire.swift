// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

extension JSONValue {
  var mcpObject: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
  var mcpString: String? { if case .string(let value) = self { value } else { nil } }
  var mcpNumber: Double? { if case .number(let value) = self { value } else { nil } }
  var mcpArray: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  subscript(mcp key: String) -> JSONValue? { mcpObject?[key] }
  func mcpBounded(depth: Int = 0) -> Bool {
    guard depth <= 32 else { return false }
    switch self {
    case .number(let n): return n.isFinite
    case .array(let a): return a.allSatisfy { $0.mcpBounded(depth: depth + 1) }
    case .object(let o): return o.values.allSatisfy { $0.mcpBounded(depth: depth + 1) }
    default: return true
    }
  }
}

struct McpRpcID: Hashable {
  let key: String
  let value: JSONValue
  init?(_ value: JSONValue?) {
    switch value {
    case .string(let s) where s.utf8.count <= 256:
      key = "s:" + s
      self.value = .string(s)
    case .number(let n) where n.isFinite && n.rounded() == n && abs(n) <= 9_007_199_254_740_991:
      key = "n:" + String(Int64(n))
      self.value = .number(n)
    default: return nil
    }
  }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
  func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct McpBridgeFailure: Error {
  let code: Int
  let message: String
  static let invalidParams = Self(code: -32602, message: "Invalid MCP App parameters.")
  static let declined = Self(code: -32603, message: "The user declined the MCP App request.")
}

/// Native validation, not a general JSON Schema interpreter. Unknown methods never forward.
enum McpAppWire {
  static let latestRevision = "2026-01-26"
  static let revisions = [latestRevision, "2025-11-21"]
  static let hostCapabilities: JSONValue = .object([
    "openLinks": .object([:]), "serverTools": .object([:]), "serverResources": .object([:]),
    "sandbox": .object(["csp": .object([:])]),
    "updateModelContext": .object([
      "text": .object([:]), "resource": .object([:]),
      "resourceLink": .object([:]), "structuredContent": .object([:]),
    ]),
  ])
  static func parameters(_ method: String, _ raw: JSONValue?) throws -> JSONValue {
    var p = raw?.mcpObject ?? [:]
    guard raw == nil || raw?.mcpObject != nil else { throw McpBridgeFailure.invalidParams }
    // Native confirmation is a distinct HTTP body field, never app-controlled.
    p["confirmed"] = nil
    switch method {
    case "ui/initialize":
      guard let info = p["appInfo"]?.mcpObject, info["name"]?.mcpString != nil,
        info["version"]?.mcpString != nil, p["appCapabilities"]?.mcpObject != nil,
        p["protocolVersion"]?.mcpString != nil
      else { throw McpBridgeFailure.invalidParams }
    case "ping": break
    case "ui/request-display-mode":
      guard let mode = p["mode"]?.mcpString, ["inline", "fullscreen", "pip"].contains(mode) else {
        throw McpBridgeFailure.invalidParams
      }
    case "tools/call":
      guard p["name"]?.mcpString != nil,
        p["arguments"] == nil || p["arguments"]?.mcpObject != nil
      else { throw McpBridgeFailure.invalidParams }
    case "resources/read":
      guard p["uri"]?.mcpString != nil else { throw McpBridgeFailure.invalidParams }
    case "ui/open-link":
      guard p["url"]?.mcpString != nil else { throw McpBridgeFailure.invalidParams }
    case "ui/update-model-context":
      guard p["structuredContent"] == nil || p["structuredContent"]?.mcpObject != nil,
        p["content"] == nil || validContent(p["content"])
      else { throw McpBridgeFailure.invalidParams }
    default: throw McpBridgeFailure(code: -32601, message: "MCP App method is not supported.")
    }
    return .object(p)
  }
  static func validContent(_ value: JSONValue?) -> Bool {
    guard let content = value?.mcpArray else { return false }
    return content.allSatisfy { item in
      guard let p = item.mcpObject, let type = p["type"]?.mcpString else { return false }
      switch type {
      case "text": return p["text"]?.mcpString != nil
      case "image", "audio": return p["data"]?.mcpString != nil && p["mimeType"]?.mcpString != nil
      case "resource_link": return p["uri"]?.mcpString != nil && p["name"]?.mcpString != nil
      case "resource":
        guard let r = p["resource"]?.mcpObject, r["uri"]?.mcpString != nil else { return false }
        return r["text"]?.mcpString != nil || r["blob"]?.mcpString != nil
      default: return false
      }
    }
  }
  static func boundedText(_ text: String?, limit: Int) -> String? {
    guard let text else { return nil }
    let cleaned = String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          scalar.value < 32 || scalar.value == 127 ? Unicode.Scalar(32)! : scalar
        })
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : String(decoding: cleaned.utf16.prefix(limit), as: UTF16.self)
  }
  static func argumentPreview(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    func preview(_ value: JSONValue, depth: Int) -> JSONValue {
      switch value {
      case .string(let s): return .string(String(decoding: s.utf16.prefix(240), as: UTF16.self))
      case .array(let a):
        guard depth < 4 else { return .string("[depth limit]") }
        var result = a.prefix(12).map { preview($0, depth: depth + 1) }
        if a.count > 12 { result.append(.string("[\(a.count - 12) more items]")) }
        return .array(result)
      case .object(let o):
        guard depth < 4 else { return .string("[depth limit]") }
        var result: [String: JSONValue] = [:]
        for key in o.keys.sorted().prefix(16) {
          let secret =
            key.range(
              of:
                "authorization|auth|token|api[_-]?key|password|passwd|secret|cookie|credential|session",
              options: [.regularExpression, .caseInsensitive]) != nil
          result[String(decoding: key.utf16.prefix(120), as: UTF16.self)] =
            secret ? .string("[redacted]") : preview(o[key]!, depth: depth + 1)
        }
        if o.count > 16 { result["…"] = .string("[more fields]") }
        return .object(result)
      default: return value
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(preview(value, depth: 0)) else { return "[unavailable]" }
    var text = String(decoding: data, as: UTF8.self)
    if text.utf8.count <= 2048 { return text }
    text = String(text.prefix(2048))
    while (text + "…").utf8.count > 2048 { text.removeLast() }
    return text + "…"
  }
  /// The shipped web only requires a content array for the initial tool-result notification.
  static func initialToolResult(_ result: JSONValue?) -> JSONValue {
    if result?[mcp: "content"]?.mcpArray != nil { return result! }
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string("The MCP tool returned an invalid app result."),
        ])
      ]), "isError": .bool(true),
    ])
  }
}
