// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Immutable, Sendable parse strategies shared by event clocks and presentation hot paths.
public enum ServerTimestamp {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

  public static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? fractional.parse(value)) ?? (try? whole.parse(value))
  }

  /// Ignore subsecond receipt jitter without suppressing meaningful server clock corrections.
  public static func correctedOffset(current: TimeInterval, proposed: TimeInterval) -> TimeInterval
  {
    proposed.isFinite && abs(proposed - current) > 1 ? proposed : current
  }
}
