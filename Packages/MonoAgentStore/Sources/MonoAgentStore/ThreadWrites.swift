// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

enum ThreadWriteOutcome: Sendable { case success, failed, timedOut, cancelled }
/// Per-waiter cancellation never changes the operation's outcome or its ordering barrier.
actor ThreadWriteSignal {
  private var result: ThreadWriteOutcome?
  private var waiters: [UUID: CheckedContinuation<ThreadWriteOutcome, Never>] = [:]
  @discardableResult func finish(_ value: ThreadWriteOutcome) -> Bool {
    guard result == nil else { return false }
    result = value
    for waiter in waiters.values { waiter.resume(returning: value) }
    waiters.removeAll()
    return true
  }
  func current() -> ThreadWriteOutcome? { result }
  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(returning: .cancelled)
  }
  func value() async -> ThreadWriteOutcome {
    if Task.isCancelled { return .cancelled }
    if let result { return result }
    let id = UUID()
    return await withTaskCancellationHandler {
      if Task.isCancelled { return .cancelled }
      return await withCheckedContinuation { waiters[id] = $0 }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }
}
@MainActor final class ThreadWriteState {
  let result = ThreadWriteSignal()
  let completionResult = ThreadWriteSignal()
  var completion: Task<Void, Never>?
  var operation: Task<Void, Never>?
  var deadline: Task<Void, Never>?
  var cancel: (() -> Void)?
  var reported = false
}
extension ConsoleStore {
  public func enqueueThreadWrite(
    threadID: String, operation: @escaping @Sendable () async throws -> Void
  ) {
    let previous = writeTasks[threadID]
    let token = UUID()
    let generation = epoch
    let state = ThreadWriteState()
    writeLifetimes[token] = state
    writeStates[threadID] = state
    writeTokens[threadID] = token
    // The caller's deadline includes queue wait, independent of actual request settlement.
    state.deadline = Task { [clock] in
      do {
        try await clock.sleep(seconds: ConsoleBounds.threadWriteTimeout)
        if await state.result.finish(.timedOut) { state.operation?.cancel() }
      } catch {}
    }
    let completion = Task { [weak self] in
      await previous?.value
      let ready = await state.result.current() == nil
      if let self, self.epoch == generation, !Task.isCancelled, ready {
        let request = Task {
          do {
            try Task.checkCancellation()
            try await operation()
            await state.result.finish(.success)
          } catch is CancellationError { await state.result.finish(.cancelled) } catch {
            await state.result.finish(.failed)
          }
        }
        state.operation = request
        // Cancellation/deadline cannot un-send a mutation. Hold the real queue until it finishes.
        await request.value
      } else {
        await state.result.finish(.cancelled)
      }
      state.deadline?.cancel()
      state.deadline = nil
      state.operation = nil
      let outcome = await state.result.current()
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
      await state.completionResult.finish(.success)
    }
    state.completion = completion
    state.cancel = {
      completion.cancel()
      state.operation?.cancel()
      state.deadline?.cancel()
      Task {
        await state.result.finish(.cancelled)
        await state.completionResult.finish(.cancelled)
      }
    }
    writeTasks[threadID] = completion
  }
  private func interruptedWrite() throws {
    if Task.isCancelled || backgrounded { throw CancellationError() }
    errorMessage =
      "A previous edit was interrupted and may still be settling. Check the conversation and retry after it finishes."
    throw SubmissionError.threadWriteInterrupted
  }
  public func settleThreadWrites(_ threadID: String) async throws {
    try Task.checkCancellation()
    guard let state = writeStates[threadID] else { return }
    let outcome = await state.result.value()
    try Task.checkCancellation()
    if outcome == .cancelled { try interruptedWrite() }
    if !state.reported {
      state.reported = true
      if writeTasks[threadID] == nil { writeStates[threadID] = nil }
      if outcome == .failed { throw SubmissionError.threadWriteFailed }
      if outcome == .timedOut { throw SubmissionError.threadWriteTimeout }
    }
    // Await a cancellation-aware signal, never the unstructured physical Task.value.
    if await state.completionResult.value() == .cancelled { try interruptedWrite() }
    try Task.checkCancellation()
  }
}
