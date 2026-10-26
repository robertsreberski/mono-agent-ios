// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore

/// Pure transcript decisions, independent of SwiftUI and networking.
enum TranscriptPresentation {
  private static let shellDirectory = try! NSRegularExpression(
    pattern: #"^cd\s+(?:"[^"]+"|'[^']+'|[^\s;&]+)\s*(?:&&|;)\s*"#)
  private static let path = try! NSRegularExpression(
    pattern: #"^(?:\.{0,2}/|~/|/)?[\p{L}\p{N}._@+-]+(?:/[\p{L}\p{N}._@+-]+)+$"#)
  private static let numericPath = try! NSRegularExpression(pattern: #"^[\d/]+$"#)

  struct Entry: Identifiable, Equatable {
    let id: Int
    let parts: [WebMessagePart]
  }
  static func toolName(_ call: WebToolCall) -> String { call.toolName ?? call.name ?? "Tool" }
  static func failed(_ call: WebToolCall) -> Bool {
    ["failed", "error", "cancelled", "interrupted", "timeout", "timed_out"].contains(call.status)
  }
  static func failed(_ event: ProcessJobActivityEvent) -> Bool {
    event.phase == .terminal && JobPresentation.terminalStates.contains(event.state)
      && event.state != "succeeded"
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
      } else if isReplyImage(part), let last = bands.last, last.parts.allSatisfy(isReplyImage) {
        bands[bands.count - 1] = Entry(id: last.id, parts: last.parts + [part])
      } else {
        bands.append(Entry(id: index, parts: [part]))
      }
    }
    return bands
  }
  struct ItemEntry: Identifiable {
    let id: String
    var parts: [TranscriptItem]
  }
  static func isActivity(_ item: TranscriptItem) -> Bool {
    switch item {
    case .jobEvent: true
    case .part(let part): isActivity(part)
    }
  }
  static func activityBands(_ entries: [TranscriptEntry]) -> [ItemEntry] {
    var bands: [ItemEntry] = []
    for entry in entries {
      let item = entry.item
      let image = item.part.map(isReplyImage) ?? false
      if let last = bands.last,
        (isActivity(item) && last.parts.allSatisfy(isActivity))
          || (image && last.parts.allSatisfy { $0.part.map(isReplyImage) ?? false })
      {
        bands[bands.count - 1].parts.append(item)
      } else {
        bands.append(.init(id: entry.sourcePartID, parts: [item]))
      }
    }
    return bands
  }
  static func clusters(_ parts: [TranscriptItem]) -> [ItemEntry] {
    var rows: [ItemEntry] = []
    for (index, item) in parts.enumerated() {
      let id: String
      switch item {
      case .jobEvent(let event): id = event.id
      case .part(.toolCall(let call)): id = "tool:" + call.toolCallId
      default: id = "part-\(index)"
      }
      if case .part(.toolCall(let call)) = item, toolName(call) != "AskUser",
        let last = rows.last, case .part(.toolCall(let previous)) = last.parts.last,
        toolName(call) == toolName(previous)
      {
        rows[rows.count - 1].parts.append(item)
      } else {
        rows.append(.init(id: id, parts: [item]))
      }
    }
    return rows
  }
  static func isReplyImage(_ part: WebMessagePart) -> Bool {
    if case .attachment(let value) = part { return value.isReplyImage }
    return false
  }
  static func isActivity(_ part: WebMessagePart) -> Bool {
    switch part {
    case .reasoning, .subagent, .processJob, .processJobWake: true
    case .toolCall(let call): toolName(call) != "AskUser"
    case .telemetry(let value):
      if case .note = TranscriptTelemetry.presentation(value) { true } else { false }
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
      text = shellDirectory.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    if text.count <= 72 { return text }
    if name == "Bash" || name == "Exec" { return String(text.prefix(36)) + "…" + text.suffix(35) }
    if pathLike(text) { return "…" + text.suffix(71) }
    return String(text.prefix(71)) + "…"
  }
  static func pathLike(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return path.firstMatch(in: text, range: range) != nil
      && numericPath.firstMatch(in: text, range: range) == nil
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
    ServerTimestamp.date(value)
  }
  static func needsElapsedTimeline(status: String) -> Bool { status == "running" }
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
  /// Web `canonicalEffort`: providers report the off level as "off" or "none".
  static func canonicalEffort(_ effort: String) -> String {
    let lower = effort.lowercased()
    return lower == "none" ? "off" : lower
  }
  /// Web `shouldShowMessageRunAttribution`: only a run that deviated from what was asked keeps
  /// the footer (fallback, a transition or retry, an effort the provider did not honour, or an
  /// unsettled run already attempting another model). An ordinary turn carries none.
  static func showsRunAttribution(_ value: WebRunAttribution?, status: String) -> Bool {
    ProcessJobEvents.showsAttribution(value, status: status)
  }
  /// Web `effortChanged`: the effective effort differs from the requested one (or none was asked).
  static func effortChange(_ value: WebRunAttribution) -> String? {
    func label(_ effort: String?) -> String? {
      guard let effort, !effort.isEmpty else { return nil }
      return effort.prefix(1).uppercased() + effort.dropFirst()
    }
    func evidence(_ route: WebRunExecution?) -> WebRunExecution? {
      guard let route, route.model != nil || route.effort != nil || route.effectiveEffort != nil
      else { return nil }
      return route
    }
    guard
      let effective = label(
        (evidence(value.executed) ?? evidence(value.attempted))?.effectiveEffort)
    else { return nil }
    guard let requested = label(value.requested.effort) else { return "Effective " + effective }
    return canonicalEffort(effective) == canonicalEffort(requested)
      ? nil : "Requested \(requested) → effective \(effective)"
  }
  /// Web `hasReadableThoughtContent`: a thought holding only punctuation or markdown decoration
  /// is not a step; letters, numbers and other symbols (emoji) count.
  static func hasReadableThought(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        || scalar.properties.generalCategory == .otherSymbol
    }
  }
  /// Web `thinkingPreview` capped at 52 characters: fenced code and emphasis/heading markers
  /// stripped so the row reads as prose.
  static func thinkingPreview(_ text: String) -> String {
    var value = text.replacingOccurrences(
      of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
    value = value.replacingOccurrences(of: "[*_`>#]+", with: "", options: .regularExpression)
    value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return value.count > 52 ? String(value.prefix(51)) + "\u{2026}" : value
  }
  /// Whether a part is shown at all: unreadable thoughts are dropped like the web does.
  static func isShown(_ part: WebMessagePart) -> Bool {
    if case .reasoning(let value) = part { return hasReadableThought(value.text) }
    return true
  }
  /// Web `activityStepCount`: every clustered call counts on its own; thoughts without readable
  /// content never reach the band.
  static func activityStepCount(_ parts: [WebMessagePart]) -> Int {
    parts.filter { isActivity($0) && isShown($0) }.count
  }
  /// Whether the last shown part is prose, which ends the web's `no-text` running indicator.
  static func endsWithProse(_ parts: [WebMessagePart]) -> Bool {
    guard case .text(let value)? = parts.last else { return false }
    return !value.text.isEmpty
  }
  /// Web `failedLabel`: one failure says "failed", a cluster counts them, zero says nothing.
  static func failedLabel(_ count: Int, clustered: Bool) -> String? {
    count == 0 ? nil : clustered ? "\(count) failed" : "failed"
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
      return compactionMarker(marker, running: marker.status == "running").text
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
    compactionContent(value, running: running)?.text
  }
  static func compactionContent(_ value: TelemetryPart, running: Bool) -> CompactionMarkerContent? {
    guard let payload = compactionPayload(value) else { return nil }
    func number(_ key: String) -> Double? {
      guard case .number(let value) = payload[key] else { return nil }
      return value
    }
    return compactionContent(
      status: string(payload["status"]), reason: string(payload["reason"]),
      trigger: string(payload["trigger"]), before: number("tokensBefore"),
      after: number("tokensAfter"),
      exact: payload["tokenCountsExact"] == .bool(true), running: running)
  }
  static func compactionMarker(_ marker: WebConversationMarkerPart, running: Bool)
    -> CompactionMarkerContent
  {
    compactionContent(
      status: marker.status, reason: marker.reason, trigger: marker.trigger,
      before: marker.tokensBefore, after: marker.tokensAfter,
      exact: marker.tokenCountsExact == true,
      running: running)
  }
  static func compactionContent(
    status reported: String?, reason: String?, trigger: String?, before: Double?, after: Double?,
    exact: Bool, running: Bool
  ) -> CompactionMarkerContent {
    let recognized =
      ["running", "succeeded", "skipped", "failed"].contains(reported ?? "") ? reported! : "failed"
    let status = recognized == "running" && !running ? "interrupted" : recognized
    let label =
      [
        "running": "Compacting context…", "succeeded": "Context compacted",
        "skipped": "Context compaction skipped", "interrupted": "Context compaction interrupted",
      ][status]
      ?? (reason == "outcome_unknown"
        ? "Context compaction outcome unknown" : "Context compaction failed")
    let approximation = exact ? "" : "≈"
    var counts: String?
    if status == "succeeded" {
      switch (compactionTokenCount(before), compactionTokenCount(after)) {
      case (.some(let before), .some(let after)):
        counts = before + " → " + approximation + after + " tokens"
      case (.some(let before), .none): counts = approximation + before + " tokens before"
      case (.none, .some(let after)): counts = approximation + after + " tokens after"
      default: break
      }
    }
    let detail =
      status == "succeeded"
      ? nil
      : [
        "model_changed": "Model changed.", "nothing_to_compact": "Nothing to compact yet.",
        "outcome_unknown": "Response lost; it may have completed.",
      ][reason ?? ""]
    return .init(
      label: label, counts: counts, detail: detail,
      trigger: trigger == "manual" ? "manual" : "automatic",
      running: status == "running", failed: status == "failed" || status == "interrupted")
  }
  static func compactionTokenCount(_ value: Double?) -> String? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    guard value < 999_950_000_000 else { return "≥1T" }
    var unit = 0
    let divisors: [Double] = [1, 1_000, 1_000_000, 1_000_000_000]
    let suffixes = ["", "k", "M", "B"]
    while unit < divisors.count - 1 {
      let rounded = unit == 0 ? value.rounded() : (value / divisors[unit] * 10).rounded() / 10
      guard rounded >= 1_000 else { break }
      unit += 1
    }
    let text =
      unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value / divisors[unit])
    return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffixes[unit]
  }
  static func liveInputLabel(_ status: String) -> String? {
    [
      "pending": "Steering current run…", "applied": "Consumed by current run",
      "queued": "Queued as next turn", "uncertain": "Delivery uncertain — not retried",
      "cancelled": "Cancelled",
    ][status]
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
