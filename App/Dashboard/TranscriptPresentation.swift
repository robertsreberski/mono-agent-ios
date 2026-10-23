// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Pure transcript decisions, independent of SwiftUI and networking.
enum TranscriptPresentation {
  struct Entry: Identifiable, Equatable {
    let id: Int
    let parts: [WebMessagePart]
  }
  static func toolName(_ call: WebToolCall) -> String { call.toolName ?? call.name ?? "Tool" }
  static func failed(_ call: WebToolCall) -> Bool {
    ["failed", "error", "cancelled", "interrupted", "timeout", "timed_out"].contains(call.status)
  }
  static func clusters(_ parts: [WebMessagePart]) -> [Entry] {
    var rows: [Entry] = []
    for (index, part) in parts.enumerated() {
      if case .toolCall(let call) = part, toolName(call) != "AskUser",
        let last = rows.last, case .toolCall(let previous) = last.parts.last,
        toolName(call) == toolName(previous)
      {
        rows[rows.count - 1] = Entry(id: last.id, parts: last.parts + [part])
      } else {
        rows.append(Entry(id: index, parts: [part]))
      }
    }
    return rows
  }
  /// Consecutive activity shares one web panel; text, questions and markers end a band.
  static func activityBands(_ parts: [WebMessagePart]) -> [Entry] {
    var bands: [Entry] = []
    for (index, part) in parts.enumerated() {
      if isActivity(part), let last = bands.last, last.parts.allSatisfy(isActivity) {
        bands[bands.count - 1] = Entry(id: last.id, parts: last.parts + [part])
      } else {
        bands.append(Entry(id: index, parts: [part]))
      }
    }
    return bands
  }
  static func isActivity(_ part: WebMessagePart) -> Bool {
    switch part {
    case .reasoning, .subagent, .processJob, .processJobWake: true
    case .toolCall(let call): toolName(call) != "AskUser"
    default: false
    }
  }
  static func verb(_ name: String) -> String {
    let known = [
      "read_file": "Read", "edit_file": "Edit", "write_file": "Write",
      "memory_search": "Memory search",
    ]
    if let value = known[name] { return value }
    let value = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(
      of: "-", with: " ")
    return value.prefix(1).uppercased() + value.dropFirst()
  }
  static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text) = value else { return nil }
    return text
  }
  static func preview(_ call: WebToolCall) -> String {
    let name = toolName(call)
    var text = string(call.args) ?? ""
    if case .object(let fields) = call.args {
      if name == "Exec" {
        let args: [String] =
          if case .array(let values) = fields["args"] { values.compactMap { string($0) } } else {
            []
          }
        text = ([string(fields["executable"]) ?? ""] + args).map { value in
          value.contains(where: \.isWhitespace)
            ? "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" : value
        }.joined(separator: " ")
      } else {
        let keys =
          name == "Bash"
          ? ["command"]
          : [
            "file_path", "path", "filePath", "pattern", "command", "query", "url", "prompt",
            "description", "name",
          ]
        text =
          keys.compactMap { string(fields[$0]) }.first
          ?? fields.keys.sorted().compactMap { string(fields[$0]) }.first ?? ""
      }
    }
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if name == "Bash" || name == "Exec" {
      text = text.replacingOccurrences(
        of: #"^cd\s+(?:"[^"]+"|'[^']+'|[^\s;&]+)\s*(?:&&|;)\s*"#, with: "",
        options: .regularExpression)
    }
    if text.count <= 72 { return text }
    if name == "Bash" || name == "Exec" { return String(text.prefix(36)) + "…" + text.suffix(35) }
    if pathLike(text) { return "…" + text.suffix(71) }
    return String(text.prefix(71)) + "…"
  }
  static func pathLike(_ text: String) -> Bool {
    text.range(
      of: #"^(?:\.{0,2}/|~/|/)?[\p{L}\p{N}._@+-]+(?:/[\p{L}\p{N}._@+-]+)+$"#,
      options: .regularExpression) != nil
      && text.range(of: #"^[\d/]+$"#, options: .regularExpression) == nil
  }
  static func clusterSummary(_ calls: [WebToolCall]) -> String {
    var seen = Set<String>()
    let values = calls.map(preview).map {
      pathLike($0) ? String($0.split(separator: "/").last ?? "") : $0
    }
    .filter { !$0.isEmpty && seen.insert($0).inserted }
    return values.prefix(2).joined(separator: ", ")
      + (values.count > 2 ? " +\(values.count - 2)" : "")
  }
  static func json(_ value: JSONValue?) -> String {
    guard let value else { return "Not reported" }
    if case .string(let text) = value { return text }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
      ?? "Unreadable payload"
  }
  static func duration(_ milliseconds: Double?) -> String? {
    guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return nil }
    return milliseconds < 1000
      ? String(format: "%.0fms", milliseconds) : String(format: "%.1fs", milliseconds / 1000)
  }
  static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  static func elapsed(_ message: WebMessage, now: Date) -> String? {
    guard let start = date(message.createdAt) else { return nil }
    let end = date(message.finishedAt) ?? (message.status == "running" ? now : nil)
    guard let end else { return nil }
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    return seconds < 1 ? "<1s" : seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
  static func cost(_ value: CostAmount) -> String {
    switch value {
    case .known(let amount): return String(format: "$%.4f", amount)
    case .unknown(let known):
      if let known, known.isFinite, known >= 0 {
        return String(format: "Cost unknown · $%.4f known", known)
      }
      return "Cost unknown"
    }
  }
  static func route(_ model: String?, _ effort: String?) -> String {
    [model ?? "Model not reported", effort.map { $0 == "none" ? "off" : $0 }].compactMap { $0 }
      .joined(separator: " · ")
  }
  static func attribution(_ value: WebRunAttribution, status: String) -> String {
    func evidence(_ route: WebRunExecution?) -> WebRunExecution? {
      guard let route, route.model != nil || route.effort != nil || route.effectiveEffort != nil
      else { return nil }
      return route
    }
    let executed = evidence(value.executed)
    let attempted = evidence(value.attempted)
    if value.disposition == "fallback" {
      return
        "Fallback: \(value.requested.model ?? "requested route") → \(executed?.model ?? attempted?.model ?? value.transitions.last?.to ?? "fallback route") · \(value.transitions.last?.reason ?? "reason not reported")"
    }
    if let executed {
      return
        "\(status == "running" ? "Running with" : status == "complete" ? "Ran with" : "Tried") \(route(executed.model, executed.effort))"
    }
    if let attempted {
      return
        "\(status == "running" ? "Attempting" : "Attempted") \(route(attempted.model, attempted.effort))"
    }
    return "Requested \(route(value.requested.model, value.requested.effort)) — not a confirmed run"
  }
  static func marker(_ marker: WebConversationMarkerPart) -> String {
    func selection(_ value: MarkerValue?) -> String {
      switch value {
      case .route(let value): return route(value.model, value.effort)
      case .project(let value): return value.name
      default: return "None"
      }
    }
    switch marker.kind {
    case "model": return "Model · \(selection(marker.before)) → \(selection(marker.after))"
    case "project": return "Project · \(selection(marker.before)) → \(selection(marker.after))"
    case "resumed":
      return
        "Resumed · \(date(marker.at)?.formatted(date: .abbreviated, time: .shortened) ?? marker.at)"
    case "compaction":
      let label =
        [
          "succeeded": "Context compacted", "skipped": "Context compaction skipped",
          "running": "Compacting context…",
        ][marker.status ?? ""]
        ?? (marker.reason == "outcome_unknown"
          ? "Context compaction outcome unknown" : "Context compaction failed")
      let counts: String
      if marker.status == "succeeded", let before = marker.tokensBefore,
        let after = marker.tokensAfter, before.isFinite, after.isFinite
      {
        counts =
          " · \(String(format: "%.0f", before)) → \(marker.tokenCountsExact == true ? "" : "≈")\(String(format: "%.0f", after)) tokens"
      } else {
        counts = ""
      }
      return label + " · " + (marker.trigger ?? "automatic") + counts
        + (marker.reason.map { " · " + $0.replacingOccurrences(of: "_", with: " ") } ?? "")
    default: return "Conversation marker · " + marker.kind
    }
  }
  static func compactionPayload(_ value: TelemetryPart) -> [String: JSONValue]? {
    var payload = value.data
    var recognized =
      ["context_compaction", "context-compaction"].contains(value.event)
      || ["context_compaction", "context-compaction"].contains(value.kind ?? "")
    var best: [String: JSONValue]?
    for _ in 0..<8 {
      guard case .object(let object) = payload else { break }
      if string(object["kind"]) == "context_compaction"
        || string(object["type"]) == "context_compaction"
      {
        recognized = true
      }
      if object["status"] != nil { best = object }
      payload = object["data"]
    }
    return recognized ? best ?? [:] : nil
  }
  static func compaction(_ value: TelemetryPart, running: Bool) -> String? {
    guard let payload = compactionPayload(value) else { return nil }
    let reported = string(payload["status"]) ?? "failed"
    let status = reported == "running" && !running ? "interrupted" : reported
    var label =
      [
        "running": "Compacting context…", "succeeded": "Context compacted",
        "skipped": "Context compaction skipped", "interrupted": "Context compaction interrupted",
      ][status] ?? "Context compaction failed"
    if string(payload["reason"]) == "outcome_unknown" {
      label = "Context compaction outcome unknown"
    }
    label += " · " + (string(payload["trigger"]) ?? "automatic")
    if status == "succeeded", case .number(let before) = payload["tokensBefore"],
      case .number(let after) = payload["tokensAfter"], before.isFinite, after.isFinite,
      before >= 0, after >= 0
    {
      label +=
        " · " + String(format: "%.0f", before) + " → "
        + (payload["tokenCountsExact"] == .bool(true) ? "" : "≈") + String(format: "%.0f", after)
        + " tokens"
    }
    if let reason = string(payload["reason"]) {
      label += " · " + reason.replacingOccurrences(of: "_", with: " ")
    }
    return label
  }
  static func hasManualCompactionResult(_ message: WebMessage, since at: String) -> Bool {
    guard let started = date(at) else { return false }
    return message.parts.contains { part in
      if case .conversationMarker(let marker) = part {
        return marker.kind == "compaction" && marker.trigger == "manual"
          && date(marker.at).map { $0 >= started } == true
      }
      if case .telemetry(let value) = part, message.role == "assistant",
        let payload = compactionPayload(value),
        string(payload["trigger"]) == "manual", case .number(let timestamp) = payload["timestamp"],
        timestamp.isFinite
      {
        return Date(timeIntervalSince1970: timestamp / 1000) >= started
      }
      return false
    }
  }
  /// Preserve server order; timestamps describe chronology, never reorder it on the client.
  static func markerLabels(_ parts: [WebMessagePart]) -> [String] {
    parts.compactMap {
      if case .conversationMarker(let marker) = $0 { return self.marker(marker) }
      return nil
    }
  }
}
