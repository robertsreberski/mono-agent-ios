// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgentKit

@Test func incrementalParserHandlesUTF8CRLFCommentsMultilineAndUnknownFields() throws {
  let text =
    ": heartbeat\r\nevent: ready\r\ndata: {\"text\":\"雪🦉\",\r\ndata: \"value\":1}\r\nid: sample\r\nignored: field\r\nretry: 2500\r\n\r\n"
  for split in 0...text.utf8.count {
    let bytes = Data(text.utf8)
    var parser = SSEParser()
    let items = try parser.feed(bytes.prefix(split)) + parser.feed(bytes.dropFirst(split))
    let frames = items.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
    #expect(frames == [.init(name: "ready", data: "{\"text\":\"雪🦉\",\n\"value\":1}", id: "sample")])
    #expect(items.contains(.retry(milliseconds: 2500)))
    #expect(items.filter { $0 == .line }.count == 8)
  }
  var parser = SSEParser(maxFrameBytes: 4)
  #expect(throws: StreamFailure.oversizedFrame) { try parser.feed(Data("data: long".utf8)) }
}
@Test func unknownEventsAndFutureVersionsSkipPerFrameButMalformedKnownEventsFail() throws {
  #expect(
    try EventDecoder.decode(.init(name: "future", data: "not JSON", id: nil))
      == .skipped(.unknownName))
  #expect(
    try EventDecoder.decode(.init(name: "ready", data: #"{"type":"ready","version":2}"#, id: nil))
      == .skipped(.unsupportedVersion))
  #expect(throws: StreamFailure.malformedEvent) {
    try EventDecoder.decode(.init(name: "ready", data: "{}", id: nil))
  }
  #expect(throws: StreamFailure.envelopeMismatch) {
    try EventDecoder.decode(
      .init(name: "ready", data: #"{"type":"turn.changed","version":1}"#, id: nil))
  }
}
@Test func boundedBackoffJitterAndRetryAfter() {
  #expect(ReconnectPolicy.delay(failures: 0, random: 0) == 1)
  #expect(ReconnectPolicy.delay(failures: 3, random: 0.5) == 6)
  #expect(ReconnectPolicy.delay(failures: 200, random: 1) == 30)
  #expect(ReconnectPolicy.delay(failures: 200, random: 0) == 15)
  #expect(ReconnectPolicy.delay(failures: 0, random: 1, retryAfter: "90") == 90)
  #expect(
    ReconnectPolicy.delay(
      failures: 0, random: 0, retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT",
      now: Date(timeIntervalSince1970: 0)) == 60)
}
actor ManualStreamClock: StreamClock {
  var instant: Double = 0
  var sleepers: [UUID: (Double, CheckedContinuation<Void, any Error>)] = [:]
  func now() -> Double { instant }
  func wallNow() -> Date { Date(timeIntervalSince1970: instant) }
  func sleep(seconds: Double) async throws {
    let id = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        sleepers[id] = (instant + seconds, continuation)
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  func cancel(_ id: UUID) {
    sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
  }
  func advance(to now: Double) {
    instant = now
    for (id, entry) in sleepers where entry.0 <= now {
      sleepers.removeValue(forKey: id)
      entry.1.resume()
    }
  }
  var count: Int { sleepers.count }
}
actor ByteScript: SSETransport {
  let attempts: [SSEAttempt]
  var requests: [URLRequest] = []
  init(_ attempts: [SSEAttempt]) { self.attempts = attempts }
  func open(_ request: URLRequest) throws -> SSEAttempt {
    requests.append(request)
    guard requests.count <= attempts.count else { throw URLError(.resourceUnavailable) }
    return attempts[requests.count - 1]
  }
}
func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
  for _ in 0..<10000 {
    if await condition() { return true }
    await Task.yield()
  }
  return false
}
func readyFrame() throws -> Data {
  Data(try #require(goldens().first { $0.name == "event-ready" }?.frame).utf8)
}
func scriptedAttempt(
  _ stream: AsyncThrowingStream<Data, any Error>, status: Int = 200, headers: [String: String] = [:]
) -> SSEAttempt {
  .init(
    status: status,
    headers: headers.merging(["content-type": "text/event-stream"]) { value, _ in value },
    bytes: stream)
}
@Test(.timeLimit(.minutes(1)))
func supervisorHeartbeatsResetLineWatchdogReconnectGenerationsAndReadyBackoff() async throws {
  let clock = ManualStreamClock()
  let (bytes, input) = AsyncThrowingStream<Data, any Error>.makeStream()
  let script = ByteScript([
    scriptedAttempt(bytes), scriptedAttempt(AsyncThrowingStream { $0.finish() }),
  ])
  let supervisor = EventStream(
    endpoint: Scenario.endpoint, transport: script, clock: clock, random: { 1 })
  let stream = await supervisor.subscribe(thread: "opaque ?雪")
  var iterator = stream.makeAsyncIterator()
  guard case .connecting(let first, .initial) = try await iterator.next() else {
    Issue.record("Missing initial gap")
    return
  }
  try #require(await eventually { await script.requests.count == 1 })
  input.yield(try readyFrame())
  guard case .event(let eventGeneration, _, let event) = try await iterator.next() else {
    Issue.record("Missing ready")
    return
  }
  #expect(first == eventGeneration && event.event.name == "ready")
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 40)
  input.yield(Data(": heartbeat\n\nevent: future\ndata: {}\n\n".utf8))
  guard case .diagnostic(_, .unknownName) = try await iterator.next() else {
    Issue.record("Missing diagnostic fence")
    return
  }
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 84)
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 85)
  guard case .waiting(let waitingGeneration, .watchdog, let seconds) = try await iterator.next()
  else {
    Issue.record("Missing watchdog reconnect")
    return
  }
  #expect(waitingGeneration == first && seconds == 1)
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 86)
  guard case .connecting(let second, .watchdog) = try await iterator.next() else {
    Issue.record("Missing next attempt")
    return
  }
  #expect(second > first)
  await supervisor.cancel()
  let requests = await script.requests
  #expect(requests.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
  #expect(
    URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
      == "opaque ?雪")
  input.finish()
}
@Test(.timeLimit(.minutes(1))) func subscriptionChangesRestartAndOverflowReportsGenerationGap()
  async throws
{
  let clock = ManualStreamClock()
  let (bytes, input) = AsyncThrowingStream<Data, any Error>.makeStream()
  let probe = CancellationProbe()
  let (oldBytes, oldInput) = AsyncThrowingStream<Data, any Error>.makeStream()
  let overflowing = SSEAttempt(
    status: 200, headers: ["content-type": "text/event-stream"], bytes: bytes,
    cancel: { Task { await probe.mark() } })
  let script = ByteScript([scriptedAttempt(oldBytes), overflowing])
  let supervisor = EventStream(endpoint: Scenario.endpoint, transport: script, clock: clock)
  let old = await supervisor.subscribe(thread: "old")
  var oldIterator = old.makeAsyncIterator()
  _ = try await oldIterator.next()
  try #require(await eventually { await script.requests.count == 1 })
  let replacement = await supervisor.subscribe(thread: "new", capacity: 1)
  try #require(await eventually { await script.requests.count == 2 })
  input.yield(try readyFrame())  // connecting occupies the only delivery slot.
  var iterator = replacement.makeAsyncIterator()
  // Wait for the attempt to detect overflow before draining the bounded slot.
  try #require(await eventually { await probe.cancelled })
  guard case .connecting(_, .subscriptionChanged) = try await iterator.next() else {
    Issue.record("Missing changed subscription")
    return
  }
  await #expect(throws: StreamDeliveryGap.self) { try await iterator.next() }
  #expect(try await oldIterator.next() == nil)
  input.finish()
  oldInput.finish()
  await supervisor.cancel()
}
@Test(.timeLimit(.minutes(1))) func initialReadyDeadlineAndHTTPRetryAfter() async throws {
  let clock = ManualStreamClock()
  let (bytes, input) = AsyncThrowingStream<Data, any Error>.makeStream()
  let script = ByteScript([scriptedAttempt(bytes)])
  let supervisor = EventStream(
    endpoint: Scenario.endpoint, transport: script, clock: clock, random: { 0 })
  var iterator = await supervisor.subscribe().makeAsyncIterator()
  _ = try await iterator.next()
  try #require(
    await eventually {
      let c = await clock.count
      let r = await script.requests.count
      return c > 0 && r > 0
    })
  await clock.advance(to: 20)
  guard case .waiting(_, .readyTimeout, 1) = try await iterator.next() else {
    Issue.record("Missing ready deadline")
    return
  }
  await supervisor.cancel()
  input.finish()
  let httpClock = ManualStreamClock()
  let httpScript = ByteScript([
    scriptedAttempt(AsyncThrowingStream { $0.finish() }, status: 429, headers: ["retry-after": "7"])
  ])
  let http = EventStream(endpoint: Scenario.endpoint, transport: httpScript, clock: httpClock)
  var httpIterator = await http.subscribe().makeAsyncIterator()
  _ = try await httpIterator.next()
  guard case .waiting(_, .http, 7) = try await httpIterator.next() else {
    Issue.record("Missing Retry-After")
    return
  }
  await http.cancel()
}

actor CancellationProbe {
  var cancelled = false
  func mark() { cancelled = true }
}
@Test(.timeLimit(.minutes(1))) func healthyReadyResetsBackoffAfterFailedHandshakes() async throws {
  let clock = ManualStreamClock()
  let frame = try readyFrame()
  let closed = AsyncThrowingStream<Data, any Error> { $0.finish() }
  let readyThenClose = AsyncThrowingStream<Data, any Error> {
    $0.yield(frame)
    $0.finish()
  }
  let script = ByteScript([
    scriptedAttempt(closed, status: 503), scriptedAttempt(closed, status: 503),
    scriptedAttempt(readyThenClose),
  ])
  let supervisor = EventStream(
    endpoint: Scenario.endpoint, transport: script, clock: clock, random: { 1 })
  var iterator = await supervisor.subscribe().makeAsyncIterator()
  _ = try await iterator.next()
  guard case .waiting(_, .http, 1) = try await iterator.next() else {
    Issue.record("First failure")
    return
  }
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 1)
  _ = try await iterator.next()
  guard case .waiting(_, .http, 2) = try await iterator.next() else {
    Issue.record("Second failure")
    return
  }
  try #require(await eventually { await clock.count > 0 })
  await clock.advance(to: 3)
  _ = try await iterator.next()
  guard case .event(_, _, let ready) = try await iterator.next() else {
    Issue.record("Missing healthy ready")
    return
  }
  #expect(ready.event.name == "ready")
  guard case .waiting(_, .disconnected, 1) = try await iterator.next() else {
    Issue.record("Healthy ready must reset backoff")
    return
  }
  await supervisor.cancel()
}

private struct FailingSSETransport: SSETransport {
  func open(_ request: URLRequest) throws -> SSEAttempt {
    throw URLError(.serverCertificateUntrusted)
  }
}
@Test(.timeLimit(.minutes(1))) func securityFailuresDoNotScheduleReconnects() async throws {
  let clock = ManualStreamClock()
  let supervisor = EventStream(
    endpoint: Scenario.endpoint, transport: FailingSSETransport(), clock: clock)
  var iterator = await supervisor.subscribe().makeAsyncIterator()
  _ = try await iterator.next()
  await #expect(throws: ProbeError.tls) { try await iterator.next() }
  #expect(await clock.count == 0)
  let script = ByteScript([scriptedAttempt(AsyncThrowingStream { $0.finish() }, status: 404)])
  let unavailable = EventStream(endpoint: Scenario.endpoint, transport: script, clock: clock)
  var missing = await unavailable.subscribe().makeAsyncIterator()
  _ = try await missing.next()
  await #expect(throws: APIError(status: 404, code: "stream_http")) { try await missing.next() }
  #expect(await script.requests.count == 1)
}
