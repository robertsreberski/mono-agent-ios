// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public protocol StreamClock: Sendable {
  func now() async -> TimeInterval
  func wallNow() async -> Date
  func sleep(seconds: TimeInterval) async throws
}
extension StreamClock {
  public func wallNow() async -> Date { Date() }
}
public struct SystemStreamClock: StreamClock {
  private let start = ContinuousClock.now
  public init() {}
  public func now() async -> TimeInterval {
    let c = start.duration(to: .now).components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }
  public func sleep(seconds: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(max(0, seconds)))
  }
}
public struct SSEAttempt: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let bytes: AsyncThrowingStream<Data, any Error>
  public let cancel: @Sendable () -> Void
  public init(
    status: Int, headers: [String: String], bytes: AsyncThrowingStream<Data, any Error>,
    cancel: @escaping @Sendable () -> Void = {}
  ) {
    self.status = status
    self.headers = headers
    self.bytes = bytes
    self.cancel = cancel
  }
}
public protocol SSETransport: Sendable {
  func open(_ request: URLRequest) async throws -> SSEAttempt
}
public actor URLSessionSSETransport: SSETransport {
  private let session: URLSession
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    let config = configuration
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    // The supervisor owns complete-line and initial-ready deadlines.
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = .greatestFiniteMagnitude
    session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  public func open(_ request: URLRequest) async throws -> SSEAttempt {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw StreamFailure.disconnected }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) {
      if let key = $1.key as? String, let value = $1.value as? String {
        $0[key.lowercased()] = value
      }
    }
    // Raw chunks never cause delivery gaps. Only decoded StreamUpdate delivery is bounded.
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .unbounded)
    let task = Task {
      do {
        var chunk = Data()
        for try await byte in bytes {
          try Task.checkCancellation()
          chunk.append(byte)
          if byte == 10 || byte == 13 || chunk.count >= 4096 {
            if case .terminated = continuation.yield(chunk) { throw CancellationError() }
            chunk.removeAll(keepingCapacity: true)
          }
        }
        if !chunk.isEmpty, case .terminated = continuation.yield(chunk) {
          throw CancellationError()
        }
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    continuation.onTermination = { _ in
      task.cancel()
      bytes.task.cancel()
    }
    return .init(
      status: response.statusCode, headers: headers, bytes: stream,
      cancel: {
        task.cancel()
        bytes.task.cancel()
      })
  }
}
public enum GapReason: String, Sendable, Equatable {
  case initial, reconnect, subscriptionChanged, disconnected, watchdog, readyTimeout, overflow,
    malformed, http
}
public enum StreamUpdate: Sendable {
  case connecting(generation: UInt64, gap: GapReason)
  case event(generation: UInt64, gap: GapReason, ApiEvent)
  case diagnostic(generation: UInt64, EventDiagnostic)
  case unreadable(generation: UInt64, UnreadableEvent)
  case gap(generation: UInt64, reason: GapReason)
  case waiting(generation: UInt64, gap: GapReason, seconds: Double)
}
public struct StreamDeliveryGap: Error, Sendable, Equatable {
  public let generation: UInt64
  public let reason: GapReason
}
private actor AttemptState {
  var lastLine: Double
  let started: Double
  var ready = false
  init(now: Double) {
    lastLine = now
    started = now
  }
  func line(at now: Double) { lastLine = now }
  func becameReady() { ready = true }
  func snapshot() -> (lastLine: Double, started: Double, ready: Bool) { (lastLine, started, ready) }
}
public enum ReconnectPolicy {
  /// Server Retry-After values may extend normal backoff, but never beyond five minutes.
  public static let maximumRetryAfter: Double = 300
  public static func delay(
    failures: Int, random: Double, retryAfter: String? = nil, now: Date = Date()
  ) -> Double {
    let ceiling = min(30.0, pow(2, Double(min(5, max(0, failures)))))
    var value = max(1, ceiling * (0.5 + 0.5 * min(1, max(0, random))))
    if let retryAfter {
      if let seconds = Double(retryAfter), seconds.isFinite {
        value = max(value, seconds)
      } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: retryAfter) {
          value = max(value, date.timeIntervalSince(now))
        }
      }
    }
    return min(maximumRetryAfter, value)
  }
}
/// One active subscription. Changing thread restarts immediately; debounce belongs to Store.
public actor EventStream {
  private let endpoint: ConsoleEndpoint
  private let transport: any SSETransport
  private let clock: any StreamClock
  private let random: @Sendable () -> Double
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  public init(
    endpoint: ConsoleEndpoint, transport: any SSETransport = URLSessionSSETransport(),
    clock: any StreamClock = SystemStreamClock(),
    random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.endpoint = endpoint
    self.transport = transport
    self.clock = clock
    self.random = random
  }
  deinit { task?.cancel() }
  public func subscribe(thread: String? = nil, capacity: Int = 128) async -> AsyncThrowingStream<
    StreamUpdate, any Error
  > {
    let changed = task != nil
    task?.cancel()
    let delivery = StreamDelivery(capacity: capacity)
    let active = Task {
      await self.run(
        thread: thread, reason: changed ? .subscriptionChanged : .initial, delivery: delivery)
    }
    task = active
    await delivery.setProducer(active)
    return AsyncThrowingStream(unfolding: { try await delivery.next() })
  }
  public func cancel() {
    task?.cancel()
    task = nil
  }
  private func publish(
    _ update: StreamUpdate, generation: UInt64, delivery: StreamDelivery, overflowing: Bool = true
  ) async throws {
    try await delivery.send(update, generation: generation, overflowing: overflowing)
  }
  private func run(
    thread: String?, reason initialReason: GapReason,
    delivery: StreamDelivery
  ) async {
    var failures = 0
    var reason = initialReason
    do {
      while !Task.isCancelled {
        generation += 1
        let current = generation
        try await publish(
          .connecting(generation: current, gap: reason), generation: current,
          delivery: delivery, overflowing: false)
        var request = try RequestBuilder(endpoint: endpoint).request(
          route: APIRoute.eventsRequest.descriptor, query: thread.map { ["thread": $0] } ?? [:])
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let state = AttemptState(now: await clock.now())
        var retryAfter: String?
        do {
          let transport = transport
          let clock = clock
          let attemptReason = reason
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              while !Task.isCancelled {
                try await clock.sleep(seconds: 1)
                let snapshot = await state.snapshot()
                let now = await clock.now()
                if now - snapshot.lastLine >= 45 { throw StreamFailure.watchdog }
                if !snapshot.ready && now - snapshot.started >= 20 {
                  throw StreamFailure.readyTimeout
                }
              }
            }
            group.addTask { [request] in
              let attempt = try await transport.open(request)
              defer { attempt.cancel() }
              guard attempt.status == 200 else {
                throw APIError(
                  status: attempt.status, code: "stream_http",
                  retryAfter: attempt.headers["retry-after"])
              }
              guard
                attempt.headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true
              else { throw StreamFailure.malformedEvent }
              var parser = SSEParser()
              for try await chunk in attempt.bytes {
                try Task.checkCancellation()
                for item in try parser.feed(chunk) {
                  switch item {
                  case .line: await state.line(at: clock.now())
                  case .retry: break  // Retry-After and bounded client policy are authoritative.
                  case .frame(let frame):
                    switch try EventDecoder.decode(frame) {
                    case .skipped(let diagnostic):
                      try await self.publish(
                        .diagnostic(generation: current, diagnostic), generation: current,
                        delivery: delivery)
                    case .unreadable(let event):
                      try await self.publish(
                        .unreadable(generation: current, event), generation: current,
                        delivery: delivery)
                    case .event(let event):
                      if case .ready = event.event { await state.becameReady() }
                      try await self.publish(
                        .event(generation: current, gap: attemptReason, event), generation: current,
                        delivery: delivery)
                    }
                  }
                }
              }
              throw StreamFailure.disconnected
            }
            defer { group.cancelAll() }
            try await group.next()
          }
        } catch is StreamDeliveryGap {
          reason = .overflow
          try await delivery.reportGap(generation: current)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as APIError {
          if error.retryClass != .transient && error.retryClass != .throttled {
            throw error
          }
          retryAfter = error.retryAfter
          reason = .http
        } catch let error as StreamFailure {
          switch error {
          case .overflow:
            reason = .overflow
            try await delivery.reportGap(generation: current)
          case .watchdog: reason = .watchdog
          case .readyTimeout: reason = .readyTimeout
          case .disconnected: reason = .disconnected
          default: reason = .malformed
          }
        } catch let error as URLError {
          switch error.code {
          case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired:
            throw ProbeError.tls
          case .userAuthenticationRequired, .appTransportSecurityRequiresSecureConnection:
            throw APIError(status: 403, code: "stream_security")
          default: reason = .disconnected
          }
        } catch { reason = .disconnected }
        try Task.checkCancellation()
        if await state.snapshot().ready { failures = 0 }
        let delay = ReconnectPolicy.delay(
          failures: failures, random: random(), retryAfter: retryAfter, now: await clock.wallNow())
        failures += 1
        try await publish(
          .waiting(generation: current, gap: reason, seconds: delay), generation: current,
          delivery: delivery, overflowing: false)
        try await clock.sleep(seconds: delay)
      }
      await delivery.finish()
    } catch is CancellationError { await delivery.finish() } catch {
      await delivery.finish(throwing: error)
    }
  }
}
