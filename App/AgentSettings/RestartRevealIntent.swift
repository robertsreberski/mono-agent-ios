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
