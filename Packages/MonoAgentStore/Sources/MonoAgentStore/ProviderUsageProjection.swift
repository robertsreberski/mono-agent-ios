// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Constant-rate extrapolation at the measurement, never a wall-clock forecast.
public struct ProviderUsageProjection: Sendable, Equatable {
  public enum Severity: String, Sendable { case ok, ahead, unsustainable }
  public enum Confidence: String, Sendable { case normal, low }
  public var pace: Double
  public var elapsedFraction: Double
  public var severity: Severity
  public var confidence: Confidence
  public var exhaustsAt: Date?
  public var leadMs: Double?
  public var projectedUnusedPercent: Double?

  public static func project(_ window: ProviderUsageWindow, fetchedAt: String) -> Self? {
    guard let reset = window.resetsAt.flatMap(parseDate), let anchor = parseDate(fetchedAt),
      window.periodMs.isFinite, window.periodMs > 0
    else { return nil }
    let anchorMs = anchor.timeIntervalSince1970 * 1000
    let resetMs = reset.timeIntervalSince1970 * 1000
    let elapsedMs = anchorMs - (resetMs - window.periodMs)
    guard elapsedMs > 0 else { return nil }
    let fraction = elapsedMs / window.periodMs
    guard fraction <= 1 else { return nil }
    let confidence: Confidence = fraction < 0.1 ? .low : .normal
    let pace = window.usedPercent / (100 * fraction)
    var result = Self(pace: pace, elapsedFraction: fraction, severity: .ok, confidence: confidence)
    if confidence == .low { return result }
    if pace < 1 { result.projectedUnusedPercent = 100 - pace * 100 }
    guard pace > 1 else { return result }
    result.severity = pace >= 1.5 ? .unsustainable : .ahead
    // JavaScript Math.round rounds half toward positive infinity, not away from zero.
    let exhaustMs = floor(
      (window.usedPercent >= 100
        ? anchorMs : anchorMs + (100 - window.usedPercent) / (window.usedPercent / elapsedMs)) + 0.5
    )
    result.exhaustsAt = Date(timeIntervalSince1970: exhaustMs / 1000)
    result.leadMs = resetMs - exhaustMs
    return result
  }
  public static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  public static func formatLead(_ milliseconds: Double) -> String {
    guard milliseconds.isFinite else { return "0m" }
    let minutes = max(0, ceil(milliseconds / 60_000))
    if minutes >= 1440 {
      return "\(Int(minutes / 1440))d \(Int(minutes.truncatingRemainder(dividingBy: 1440) / 60))h"
    }
    if minutes >= 60 {
      return "\(Int(minutes / 60))h \(Int(minutes.truncatingRemainder(dividingBy: 60)))m"
    }
    return "\(Int(minutes))m"
  }
  public static func countdown(_ reset: String, now: Date, compact: Bool = false) -> String? {
    guard let date = parseDate(reset) else { return nil }
    let ms = date.timeIntervalSince(now) * 1000
    if ceil(ms / 60_000) <= 0 { return "Reset due" }
    return "Resets \(compact ? "" : "in ")\(formatLead(ms))"
  }
}
