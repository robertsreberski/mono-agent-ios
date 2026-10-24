// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Mirrors the web runtime's telemetry mapping. Telemetry remains in Store for usage/context.
public enum TranscriptTelemetry: Sendable, Equatable {
  case hidden
  case note(String)
  case compaction
  case cron(CronRun)

  public struct CronRun: Sendable, Equatable {
    public var runID: String
    public var title: String
    public var status: String
    public var orderedAt: String?
    public var details: [String]
  }

  public static func presentation(_ part: TelemetryPart) -> Self {
    if part.event == "runtime_warning", case .object(let warning) = part.data,
      warning["warningKind"] == .string("degraded_native_context"),
      case .string(let message) = warning["message"],
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return .note(message)
    }
    if part.event == "context_compaction"
      || contains(part.data, keys: ["kind", "type"], values: ["context_compaction"])
    {
      return .compaction
    }
    if contains(part.data, keys: ["kind"], values: ["assistant_message_boundary", "context_usage"])
    {
      return .hidden
    }
    guard part.event == "cron_run", case .object(let data) = part.data,
      let runID = text(data["runId"]),
      !(data["status"] == .string("succeeded") && data["silent"] == .bool(true)
        && data["hasVisibleContent"] != .bool(true))
    else { return .hidden }
    let status = text(data["status"]) ?? "unknown"
    let state =
      status == "succeeded" ? "completed" : status.replacingOccurrences(of: "_", with: " ")
    let trigger = data["trigger"] == .string("manual") ? "manual" : "scheduled"
    var title = "Run"
    if case .number(let sequence) = data["sequence"] {
      title += " \(sequence.formatted(.number.grouping(.never)))"
    }
    var details: [String] = []
    if let artifact = text(data["artifactRunId"]) { details.append("Artifact · " + artifact) }
    if let session = text(data["conversationId"]) {
      details.append("Originating session · " + session)
    }
    if case .number(let count) = data["eventCount"], count > 0, count.rounded() == count {
      details.append(
        "\(Int(min(count, Double(Int.max / 2)))) activity events · available in the web console")
    }
    if data["eventsTruncated"] == .bool(true) {
      details.append("Activity is truncated; retained and wire-bounded events are shown.")
    }
    if case .array(let fields) = data["fieldsTruncated"] {
      let names = fields.compactMap(text)
      if !names.isEmpty {
        details.append(
          "Run " + names.joined(separator: ", ") + (names.count == 1 ? " is" : " are")
            + " truncated in this view.")
      }
    }
    return .cron(
      .init(
        runID: runID, title: title, status: trigger + " · " + state,
        orderedAt: text(data["orderedAt"]), details: details))
  }

  private static func contains(_ data: JSONValue?, keys: [String], values: Set<String>) -> Bool {
    var current = data
    for _ in 0..<8 {
      guard case .object(let object) = current else { return false }
      if keys.contains(where: { key in text(object[key]).map(values.contains) == true }) {
        return true
      }
      current = object["data"]
    }
    return false
  }
  private static func text(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    return nil
  }
  public static func visible(_ part: WebMessagePart) -> Bool {
    guard case .telemetry(let value) = part else { return true }
    return presentation(value) != .hidden
  }
  /// Do not create empty transcript rows, action bars, attribution or lazy-stack spacing.
  public static func visible(_ message: WebMessage) -> Bool {
    message.parts.isEmpty || !message.attachments.isEmpty || message.quote != nil
      || message.parts.contains(where: visible)
  }
}
