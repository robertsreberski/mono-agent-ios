// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

enum ThreadWriteOutcome: Sendable { case success, failed, timedOut, cancelled }
private actor WriteRace {
  var result: ThreadWriteOutcome?
  var waiter: CheckedContinuation<ThreadWriteOutcome, Never>?
  func finish(_ value: ThreadWriteOutcome) {
    guard result == nil else { return }
    result = value
    waiter?.resume(returning: value)
    waiter = nil
  }
  func value() async -> ThreadWriteOutcome {
    if let result { return result }
    return await withCheckedContinuation { waiter = $0 }
  }
}
extension ConsoleStore {
  /// The deadline is independent of transport cooperation. Late completion cannot mutate the chain.
  static func boundedWrite(
    clock: any StreamClock, operation: @escaping @Sendable () async throws -> Void
  ) async -> ThreadWriteOutcome {
    let race = WriteRace()
    let operationTask = Task {
      do {
        try Task.checkCancellation()
        try await operation()
        await race.finish(.success)
      } catch is CancellationError { await race.finish(.cancelled) } catch {
        await race.finish(.failed)
      }
    }
    let timeout = Task {
      do {
        try await clock.sleep(seconds: ConsoleBounds.threadWriteTimeout)
        operationTask.cancel()
        await race.finish(.timedOut)
      } catch {}
    }
    let result = await withTaskCancellationHandler {
      await race.value()
    } onCancel: {
      operationTask.cancel()
      Task { await race.finish(.cancelled) }
    }
    timeout.cancel()
    operationTask.cancel()
    return result
  }
  public func enqueueThreadWrite(
    threadID: String, operation: @escaping @Sendable () async throws -> Void
  ) {
    let previous = writeTasks[threadID]
    let token = UUID()
    let generation = epoch
    writeTokens[threadID] = token
    writeTasks[threadID] = Task { [weak self, clock] in
      await previous?.value
      guard let self, self.epoch == generation, !Task.isCancelled else { return }
      let outcome = await Self.boundedWrite(clock: clock, operation: operation)
      guard self.epoch == generation else { return }
      switch outcome {
      case .success: self.writeFailures[threadID] = nil
      case .failed: self.writeFailures[threadID] = .threadWriteFailed
      case .timedOut: self.writeFailures[threadID] = .threadWriteTimeout
      case .cancelled: break
      }
      if self.writeTokens[threadID] == token {
        self.writeTasks[threadID] = nil
        self.writeTokens[threadID] = nil
      }
    }
  }
  public func settleThreadWrites(_ threadID: String) async throws {
    let tail = writeTasks[threadID]
    await tail?.value
    try Task.checkCancellation()
    if let failure = writeFailures.removeValue(forKey: threadID) { throw failure }
  }
}
