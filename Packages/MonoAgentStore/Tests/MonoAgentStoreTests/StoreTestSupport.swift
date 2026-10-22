// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

func decode<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
  try JSONDecoder().decode(type, from: Data(text.utf8))
}
func sampleThread(_ id: String = "thread-example", revision: Int = 1) throws -> WebThread {
  var thread = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data).threads[0]
  thread.id = id
  thread.revision = revision
  return thread
}
func sampleMessage(_ id: String = "message-example", seq: Int = 1, text: String = "Hello") throws
  -> WebMessage
{
  try decode(
    """
    {"id":"\(id)","threadId":"thread-example","role":"assistant","parts":[{"type":"text","text":"\(text)"}],
     "attachments":[],"createdAt":"2030-01-02T12:00:00Z","updatedAt":"2030-01-02T12:00:00Z","status":"running","seq":\(seq)}
    """)
}
func response<T: Encodable>(_ value: T, status: Int = 200, etag: String? = nil) throws
  -> HTTPResponse
{
  HTTPResponse(
    data: try JSONEncoder().encode(value), status: status, headers: etag.map { ["etag": $0] } ?? [:]
  )
}
func detailResponse(
  thread: WebThread? = nil, messages: [WebMessage] = [], cursor: String? = nil,
  etag: String? = nil
) throws -> HTTPResponse {
  let json: JSONValue = .object([
    "thread": try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(thread ?? sampleThread())),
    "messages": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(messages)),
    "messagesNextCursor": cursor.map(JSONValue.string) ?? .null,
  ])
  return try response(json, etag: etag)
}
func event(_ type: String, thread: String? = "thread-example", payload: JSONValue) throws
  -> ApiEvent
{
  try JSONDecoder().decode(
    ApiEvent.self,
    from: JSONEncoder().encode(
      JSONValue.object([
        "id": .string(UUID().uuidString), "version": .number(1), "type": .string(type),
        "at": .string("2030-01-02T12:00:00Z"), "threadId": thread.map(JSONValue.string) ?? .null,
        "payload": payload,
      ])))
}
func deltaEvent(base: Int = 1, seq: Int = 2, status: String = "running") throws -> ApiEvent {
  try event(
    "message.delta",
    payload: .object([
      "messageId": .string("message-example"), "baseSeq": .number(Double(base)),
      "seq": .number(Double(seq)),
      "status": .string(status), "updatedAt": .string("2030-01-02T12:00:01Z"),
      "ops": .array([
        .object(["op": .string("append"), "index": .number(0), "delta": .string("!")])
      ]),
    ]))
}

actor RouteTransport: HTTPTransport {
  enum Reply: Sendable {
    case response(HTTPResponse)
    case failure, paused
  }
  var routes: [String: [Reply]] = [:]
  var requests: [URLRequest] = []
  var paused: [CheckedContinuation<HTTPResponse, any Error>] = []
  func set(_ path: String, _ replies: [Reply]) { routes[path] = replies }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url!.path
    guard var queue = routes[path], !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
    let reply = queue.removeFirst()
    routes[path] = queue
    switch reply {
    case .response(let value): return value
    case .failure: throw URLError(.networkConnectionLost)
    case .paused: return try await withCheckedThrowingContinuation { paused.append($0) }
    }
  }
  func release(_ response: HTTPResponse) { paused.removeFirst().resume(returning: response) }
  func count(_ path: String, method: String? = nil) -> Int {
    requests.filter { $0.url?.path == path && (method == nil || $0.httpMethod == method) }.count
  }
  func pauseCount() -> Int { paused.count }
}
actor TestEvents: ConsoleEventSource {
  var subscriptions: [String?] = []
  var cancellations = 0
  var continuation: AsyncThrowingStream<StreamUpdate, any Error>.Continuation?
  func subscribe(thread: String?, capacity: Int) -> AsyncThrowingStream<StreamUpdate, any Error> {
    subscriptions.append(thread)
    continuation?.finish()
    let pair = AsyncThrowingStream<StreamUpdate, any Error>.makeStream()
    continuation = pair.continuation
    return pair.stream
  }
  func cancel() {
    cancellations += 1
    continuation?.finish()
    continuation = nil
  }
  func send(_ update: StreamUpdate) { continuation?.yield(update) }
  func count() -> Int { subscriptions.count }
}
actor ManualStoreClock: StreamClock {
  var time: Double = 0
  struct Waiter {
    var deadline: Double
    var continuation: CheckedContinuation<Void, any Error>
  }
  var waiters: [UUID: Waiter] = [:]
  func now() -> Double { time }
  func wallNow() async -> Date { Date(timeIntervalSince1970: 1_893_585_600 + time) }
  func sleep(seconds: Double) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        waiters[id] = Waiter(deadline: time + seconds, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
  func advance(_ seconds: Double) {
    time += seconds
    for (id, waiter) in waiters where waiter.deadline <= time {
      waiters[id] = nil
      waiter.continuation.resume()
    }
  }
  func pending() -> Int { waiters.count }
}
@MainActor
func eventually(_ condition: () async -> Bool) async {
  for _ in 0..<10_000 {
    if await condition() { return }
    await Task.yield()
  }
  Issue.record("Condition did not become true")
}
@MainActor
struct Harness {
  let directory: URL
  let profile: SavedConsole
  let repository: FileConsoleRepository
  let transport = RouteTransport()
  let events = TestEvents()
  let clock = ManualStoreClock()
  let store: ConsoleStore
  init(profile: SavedConsole? = nil, directory: URL? = nil) {
    self.directory =
      directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    self.profile = profile ?? SavedConsole(name: "Flockbox", endpoint: Scenario.endpoint)
    repository = FileConsoleRepository(directory: self.directory)
    store = ConsoleStore(
      profile: self.profile, api: APIClient(endpoint: Scenario.endpoint, transport: transport),
      events: events, repository: repository, clock: clock)
  }
  func seed(messages: [WebMessage] = [], revision: Int = 1) throws {
    store.hold(
      .init(thread: try sampleThread(revision: revision), messages: messages, savedAt: Date()))
  }
}
