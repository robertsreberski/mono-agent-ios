// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public struct ContextProjection: Sendable, Equatable {
  public var used: Double?
  public var window: Double?
  public var model: String?
  public var status = "Not reported"
  public var note: String?
  public var estimated = false
  public var percent: Double? {
    guard let used, used.isFinite, used >= 0, let window, window.isFinite, window > 0 else {
      return nil
    }
    return min(100, used / window * 100)
  }
  public var badge: String {
    guard let percent else { return "—" }
    return (estimated ? "≈" : "")
      + (percent > 0 && percent < 0.5 ? "<1%" : String(format: "%.0f%%", percent))
  }
  public var figure: String {
    guard let used else { return "Context size not reported" }
    return (estimated ? "≈" : "") + UsagePresentation.tokens(used)
      + (window.map { " / " + UsagePresentation.tokens($0) } ?? "") + " tokens"
  }
}
public struct UsageRow: Sendable, Equatable {
  public var label: String
  public var value: String
  public init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }
}
public enum UsagePresentation {
  public static func tokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Not reported" }
    if value >= 1_000_000 { return compact(value / 1_000_000) + "M" }
    if value >= 1000 { return compact(value / 1000) + "k" }
    return String(format: "%.0f", value)
  }
  private static func compact(_ value: Double) -> String {
    let text = String(format: "%.1f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }
  public static func usd(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Unknown" }
    return String(format: value > 0 && value < 0.01 ? "$%.4f" : "$%.2f", value)
  }
  public static func cost(_ slice: WebUsageSlice?) -> String {
    guard let slice else { return "Not reported" }
    guard slice.costUnknown != true, let value = slice.costUsd, value.isFinite, value >= 0 else {
      return "Unknown" + (slice.knownCostUsd.map { " · Known cost " + usd($0) } ?? "")
    }
    return (slice.costPartial == true ? "≥" : "") + usd(value)
  }
  public static func rows(_ usage: WebThreadUsage?) -> [UsageRow] {
    guard let usage else {
      return [.init("Tokens processed", "Not reported"), .init("Estimated cost", "Not reported")]
    }
    var rows: [UsageRow] = []
    for (label, slice) in [
      ("Total", Optional(usage.total)), ("incl. subagents", usage.subagents),
      ("Compaction", usage.compaction),
    ] {
      guard let slice else { continue }
      let prefix = slice.tokensPartial == true ? "≥" : ""
      if let tokens = slice.tokens {
        rows += [
          .init(
            label + " · Input (incl. cache writes)",
            prefix + self.tokens(tokens.input + tokens.cacheWrite)),
          .init(label + " · Cached", prefix + self.tokens(tokens.cacheRead)),
          .init(label + " · Output", prefix + self.tokens(tokens.output)),
        ]
      } else {
        rows.append(.init(label + " · Tokens", "Not reported"))
      }
      rows.append(.init(label + " · Estimated cost", cost(slice)))
    }
    for slice in usage.byModel where usage.byModel.count > 1 {
      rows.append(.init(slice.model ?? "Unknown model", cost(slice)))
    }
    return rows
  }
  public static func layers(_ value: JSONValue?) -> [[String: JSONValue]] {
    var value = value
    var result: [[String: JSONValue]] = []
    for _ in 0..<8 {
      guard case .object(let record) = value else { break }
      result.append(record)
      value = record["data"]
    }
    return result
  }
  public static func text(_ records: [[String: JSONValue]], _ keys: [String]) -> String? {
    for record in records {
      for key in keys {
        if case .string(let text) = record[key], !text.isEmpty { return text }
      }
    }
    return nil
  }
  private static func number(_ records: [[String: JSONValue]], _ keys: [String]) -> Double? {
    for record in records {
      for key in keys {
        if case .number(let number) = record[key], number.isFinite, number >= 0 { return number }
      }
    }
    return nil
  }
  /// Only explicit context telemetry is occupancy. Billing totals never become a context size.
  public static func context(messages: [WebMessage], thread: WebThread) -> ContextProjection {
    struct Observation {
      var order: Int
      var timestamp: Double?
      var projection: ContextProjection
      func after(_ other: Self) -> Bool {
        if let timestamp, let before = other.timestamp, timestamp != before {
          return timestamp > before
        }
        return order > other.order
      }
    }
    var exact: Observation?
    var compaction: Observation?
    var order = 0
    for message in messages where message.role == "assistant" {
      for part in message.parts {
        guard case .telemetry(let telemetry) = part else { continue }
        order += 1
        let records = Array(layers(telemetry.data).reversed())
        let labels =
          [telemetry.event, telemetry.kind].compactMap { $0 }
          + records.flatMap { record in
            ["kind", "type", "event"].compactMap { text([record], [$0]) }
          }
        let time = number(records, ["timestamp"])
        if labels.contains(where: { $0.lowercased() == "context_usage" }),
          ["complete", "running"].contains(message.status)
        {
          let tokenRecords =
            records.compactMap {
              if case .object(let object) = $0["tokens"] { return object }
              return nil
            } + records
          let contexts = records.compactMap {
            if case .object(let object) = $0["context"] { return object }
            return nil
          }
          if let used = number(tokenRecords, ["total", "total_tokens", "totalTokens"])
            ?? number(contexts, ["used"])
          {
            let projection = ContextProjection(
              used: used,
              window: number(records, ["contextWindow", "context_window"])
                ?? number(contexts, ["window"]),
              model: text(records, ["model", "modelId", "model_id"]), status: "Current")
            let observation = Observation(order: order, timestamp: time, projection: projection)
            if exact == nil || observation.after(exact!) { exact = observation }
          }
        }
        if labels.contains(where: { $0.lowercased() == "context_compaction" }),
          let status = text(records, ["status"]), ["running", "succeeded"].contains(status)
        {
          let projection = ContextProjection(
            used: status == "running" ? nil : number(records, ["tokensAfter"]),
            status: status == "running" ? "Compacting…" : "Estimate",
            note: "Compaction changed the context. Measured again on the next turn.",
            estimated: status != "running")
          let observation = Observation(order: order, timestamp: time, projection: projection)
          if compaction == nil || observation.after(compaction!) { compaction = observation }
        }
      }
    }
    if let compaction, exact == nil || compaction.after(exact!) {
      var projection = compaction.projection
      projection.window = exact?.projection.window
      if projection.status == "Compacting…" { projection.used = exact?.projection.used }
      return projection
    }
    var projection = exact?.projection ?? ContextProjection()
    if thread.runState.status == "running" || messages.contains(where: { $0.status == "running" }) {
      projection.status = "Updating"
    } else if exact != nil
      && (["failed", "cancelled", "interrupted"].contains(thread.runState.status)
        || thread.runModel.map { $0 != projection.model } == true)
    {
      projection.status = "Last measured"
      projection.note = "Previous provider measurement; the next turn may use a different context."
    }
    return projection
  }
}
