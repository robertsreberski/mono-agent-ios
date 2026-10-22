// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bounded, single-consumer delivery. Control updates await space; a full event buffer
/// cancels only its attempt. Its discarded queue is explicitly invalidated by one gap,
/// and reconnection waits until the consumer has observed that gap.
actor StreamDelivery {
  private let capacity: Int
  private var queue: [StreamUpdate] = []
  private var reader: CheckedContinuation<StreamUpdate?, any Error>?
  private var writers: [CheckedContinuation<Void, any Error>] = []
  private var finished = false
  private var failure: (any Error)?
  private var producer: Task<Void, Never>?
  init(capacity: Int) { self.capacity = max(1, capacity) }
  func setProducer(_ task: Task<Void, Never>) {
    producer = task
    if finished { task.cancel() }
  }
  func send(_ update: StreamUpdate, generation: UInt64, overflowing: Bool = true) async throws {
    try Task.checkCancellation()
    while !finished && reader == nil && queue.count >= capacity {
      if overflowing { throw StreamDeliveryGap(generation: generation, reason: .overflow) }
      try await waitForSpace()
    }
    guard !finished else { throw CancellationError() }
    if let reader {
      self.reader = nil
      reader.resume(returning: update)
    } else {
      queue.append(update)
    }
  }
  func reportGap(generation: UInt64) async throws {
    queue.removeAll()
    try await send(
      .gap(generation: generation, reason: .overflow), generation: generation, overflowing: false)
    while !finished && !queue.isEmpty { try await waitForSpace() }
    try Task.checkCancellation()
  }
  private func waitForSpace() async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { writers.append($0) }
    } onCancel: {
      Task { await self.cancel() }
    }
  }
  func next() async throws -> StreamUpdate? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      if !queue.isEmpty {
        let value = queue.removeFirst()
        let pending = writers
        writers.removeAll()
        for writer in pending { writer.resume() }
        return value
      }
      if finished {
        if let failure { throw failure }
        return nil
      }
      return try await withCheckedThrowingContinuation { reader = $0 }
    } onCancel: {
      Task { await self.cancel() }
    }
  }
  func finish(throwing failure: (any Error)? = nil) {
    guard !finished else { return }
    finished = true
    self.failure = failure
    producer = nil
    if let reader {
      self.reader = nil
      if let failure { reader.resume(throwing: failure) } else { reader.resume(returning: nil) }
    }
    let pending = writers
    writers.removeAll()
    for writer in pending { writer.resume(throwing: CancellationError()) }
  }
  private func cancel() {
    producer?.cancel()
    queue.removeAll()
    finish()
  }
}
