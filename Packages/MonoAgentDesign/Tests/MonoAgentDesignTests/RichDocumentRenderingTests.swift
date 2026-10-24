// SPDX-License-Identifier: GPL-3.0-only
import Testing

@testable import MonoAgentDesign

@MainActor struct RichDocumentRenderingTests {
  @Test func continuousPublicationsLandEveryThrottleWindowWithoutCancellation() async {
    let renderer = RichDocumentRendering()
    let clock = RenderTestClock()
    var landed: [Duration] = []
    let prefix = String(repeating: "sample ", count: 800)
    let task = Task {
      await renderer.run(
        source: prefix + "initial", key: "throttle-initial", streaming: true,
        parse: { source in
          landed.append(clock.now)
          return RichDocument.parse(source)
        }, pause: { await clock.sleep(for: $0) })
    }
    await clock.waitForSleep()
    for tick in 1...12 {
      // Continuous 16 ms writes keep replacing the trailing request, not the parse task.
      for update in 1...5 {
        clock.advance(by: .milliseconds(16))
        renderer.submit(
          source: prefix + "version-\(tick)-\(update)", key: "throttle-\(tick)-\(update)",
          streaming: true)
      }
      clock.advance(by: .milliseconds(3))
      await clock.waitForSleep()
      #expect(landed.count == tick + 1)
      #expect(landed.last == .milliseconds(tick * 83))
      #expect(
        renderer.document?.blocks.last?.runs.last?.text.hasSuffix("version-\(tick)-5") == true)
    }
    task.cancel()
    clock.advance(by: .milliseconds(83))
    await task.value
  }
}

@MainActor private final class RenderTestClock {
  var now: Duration = .zero
  private var deadline: Duration?
  private var sleeper: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func sleep(for duration: Duration) async {
    deadline = now + duration
    await withCheckedContinuation { continuation in
      sleeper = continuation
      let ready = observers
      observers.removeAll()
      for observer in ready { observer.resume() }
    }
  }
  func waitForSleep() async {
    if sleeper != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func advance(by duration: Duration) {
    now += duration
    if let deadline, now >= deadline, let sleeper {
      self.sleeper = nil
      self.deadline = nil
      sleeper.resume()
    }
  }
}
