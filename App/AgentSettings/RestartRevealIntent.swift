// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An explicit Restart intent may follow provider layout changes, never user navigation.
struct RestartRevealIntent {
  private(set) var deadline: Date?
  private var source: String?
  private var generation: String?
  mutating func begin(source: String, generation: String?, now: Date) {
    self.source = source
    self.generation = generation
    deadline = now.addingTimeInterval(12)
  }
  /// Called with a post-layout heading measurement, not the provider's earlier height callback.
  /// Returning true requests correction; completion never ends an offscreen intent.
  mutating func measure(
    source: String, generation: String?, now: Date, top: Double, viewport: Double,
    providersComplete: Bool
  ) -> Bool {
    guard isActive(source: source, generation: generation, now: now), viewport > 96 else {
      return false
    }
    let visible = top >= -1 && top <= viewport - 96
    if visible && providersComplete { stop() }
    return !visible
  }
  mutating func stop() { deadline = nil }
  mutating func isActive(source: String, generation: String?, now: Date) -> Bool {
    guard self.source == source, self.generation == generation,
      let deadline, now < deadline
    else {
      stop()
      return false
    }
    return true
  }
}
