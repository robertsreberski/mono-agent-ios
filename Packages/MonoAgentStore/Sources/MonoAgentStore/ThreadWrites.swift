// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

enum ThreadWriteOutcome: Sendable { case success, failed, timedOut, cancelled }
private actor WriteRace {
  var result: ThreadWriteOutcome?
  var waiters: [CheckedContinuation<ThreadWriteOutcome, Never>] = []
  func finish(_ value: ThreadWriteOutcome) {
    guard result == nil else { return }
    result = value
    for waiter in waiters { waiter.resume(returning: value) }
    waiters.removeAll()
  }
  func value() async -> ThreadWriteOutcome {
    if let result { return result }
    return await withCheckedContinuation { waiters.append($0) }
  }
}
@MainActor final class ThreadWriteState {
  var result: Task<ThreadWriteOutcome, Never>?
  var completion: Task<Void, Never>?
  var completionResult: Task<ThreadWriteOutcome, Never>?
  var cancel: (() -> Void)?
  var reported = false
}
extension ConsoleStore {
  /// Caller deadlines do not release the queue: cancellation cannot un-send a mutation.
  private static func boundedWrite(
    clock: any StreamClock, race: WriteRace,
    operation: @escaping @Sendable () async throws -> Void
  ) async -> ThreadWriteOutcome {
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
        await race.finish(.timedOut)
        operationTask.cancel()
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
    // The request may ignore cancellation. Keep this thread's physical queue occupied.
    await operationTask.value
    return result
  }
  public func enqueueThreadWrite(
    threadID: String, operation: @escaping @Sendable () async throws -> Void
  ) {
    let previous = writeTasks[threadID]
    let token = UUID()
    let generation = epoch
    let race = WriteRace()
    let completionRace = WriteRace()
    let state = ThreadWriteState()
    state.result = Task { await race.value() }
    state.completionResult = Task { await completionRace.value() }
    writeLifetimes[token] = state
    writeStates[threadID] = state
    writeTokens[threadID] = token
    let completion = Task { [weak self, clock] in
      await previous?.value
      let outcome: ThreadWriteOutcome
      if let self, self.epoch == generation, !Task.isCancelled {
        outcome = await Self.boundedWrite(clock: clock, race: race, operation: operation)
      } else {
        await race.finish(.cancelled)
        outcome = .cancelled
      }
      if let self {
        self.writeLifetimes[token] = nil
        if self.writeTokens[threadID] == token {
          self.writeTasks[threadID] = nil
          self.writeTokens[threadID] = nil
          if self.epoch != generation || state.reported || outcome == .success
            || outcome == .cancelled
          {
            self.writeStates[threadID] = nil
          }
        }
      }
      state.cancel = nil
      await completionRace.finish(.success)
    }
    state.completion = completion
    state.cancel = {
      completion.cancel()
      Task {
        await race.finish(.cancelled)
        await completionRace.finish(.cancelled)
      }
    }
    writeTasks[threadID] = completion
  }
  public func settleThreadWrites(_ threadID: String) async throws {
    guard let state = writeStates[threadID] else {
      await writeTasks[threadID]?.value
      try Task.checkCancellation()
      return
    }
    let outcome = await state.result?.value
    try Task.checkCancellation()
    if outcome == .cancelled { throw CancellationError() }
    if !state.reported {
      state.reported = true
      if writeTasks[threadID] == nil { writeStates[threadID] = nil }
      if outcome == .failed { throw SubmissionError.threadWriteFailed }
      if outcome == .timedOut { throw SubmissionError.threadWriteTimeout }
    }
    if await state.completionResult?.value == .cancelled { throw CancellationError() }
    await state.completion?.value
    try Task.checkCancellation()
  }
}
