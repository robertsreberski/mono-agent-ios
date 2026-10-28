// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgentKit

@Test func everyRouteUsesClaimedOriginAndOpaquePathSegments() throws {
  let endpoint = try ConsoleEndpoint("https://console.example.ts.net:9443")
  let builder = RequestBuilder(endpoint: endpoint)
  for route in APIRoute.allCases {
    let parameters = [
      "id", "threadId", "messageId", "partId", "jobId", "runId", "operationId", "sessionId",
      "checkId", "submissionId", "interactionId", "toolCallId", "eventId",
    ].reduce(into: [String: String]()) { $0[$1] = "opaque /?%#雪" }
    let request = try builder.request(
      route: route.descriptor, parameters: parameters, query: ["cursor": "a+/=&雪"])
    #expect(request.value(forHTTPHeaderField: "X-Mono-Agent-Web-Origin") == endpoint.origin)
    #expect(request.value(forHTTPHeaderField: "Host") == nil)
    #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    #expect(request.url?.host == endpoint.url.host)
    #expect(request.httpMethod == route.descriptor.method)
    #expect(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        == "a+/=&雪")
  }
}
@Test func conditionalRead304AndETag() async throws {
  let transport = ScriptedTransport([
    .response(.init(data: Scenario.health.data, headers: ["ETag": "\"sample\""])),
    .response(.init(data: Data(), status: 304)), .response(.init(data: Data(), status: 304)),
  ])
  let api = APIClient(endpoint: Scenario.endpoint, transport: transport)
  guard case .modified(let health, let etag) = try await api.health() else {
    Issue.record("Missing value")
    return
  }
  #expect(health.status == "ok" && etag == "\"sample\"")
  guard case .notModified = try await api.health(etag: etag) else {
    Issue.record("Expected 304")
    return
  }
  await #expect(throws: APIError(status: 304, code: "unexpected_not_modified")) {
    try await api.health()
  }
  #expect(await transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == etag)
}
@Test func typed409ReceiptAnd428ConfirmationAndNoMutationRetry() async throws {
  let transport = ScriptedTransport([
    .response(.init(data: try fixture("submission-receipt"), status: 409)),
    .response(
      .init(
        data: Data(
          #"{"kind":"confirmation_required","confirmation":{"token":"fictional","expiresAt":"2030-01-02T12:00:00Z","message":"Confirm"}}"#
            .utf8), status: 428)),
    .response(
      .init(
        data: Data(#"{"error":{"code":"rate_limited","message":"secret token=fictional"}}"#.utf8),
        status: 429, headers: ["Retry-After": "17"])),
  ])
  let api = APIClient(endpoint: Scenario.endpoint, transport: transport)
  let receipt = try await api.startSubmission(
    id: "thread", body: .init(submissionId: "fictional", text: "Sample"))
  #expect(!receipt.submissionId.isEmpty)
  guard
    case .confirmationRequired = try await api.runCron(
      id: "agent", jobId: "job", body: .init(idempotencyKey: "fictional"))
  else {
    Issue.record("Expected typed confirmation")
    return
  }
  do {
    _ = try await api.restartAgent(id: "agent", body: .init())
    Issue.record("Expected failure")
  } catch let error as APIError {
    #expect(
      error.status == 429 && error.code == "rate_limited" && error.retryClass == .throttled
        && error.retryAfter == "17")
    #expect(!error.localizedDescription.contains("secret"))
  }
  #expect(await transport.requests.count == 3)
}
@Test func capabilitiesRejectOtherOriginsNamespacesAndTraversal() throws {
  let builder = RequestBuilder(endpoint: Scenario.endpoint)
  let reference = ReplyPartReference(threadId: "t", messageId: "m", partId: "p")
  let valid = "/api/v1/threads/t/messages/m/reply-attachments/p/content?expires=123&token=fictional"
  #expect(
    try builder.capabilityQuery(valid, route: .attachmentContent, reference: reference).token
      == "fictional")
  for url in [
    "https://console.example.ts.net" + valid, "//elsewhere.example" + valid,
    valid.replacingOccurrences(of: "/t/", with: "/other/"),
    "/api/v1/uploads/p/content?expires=1&token=x", valid + "&token=duplicate",
    valid.replacingOccurrences(of: "/p/", with: "/%2e%2e/"), valid + "#fragment",
  ] {
    #expect(throws: CapabilityError.invalidURL) {
      try builder.capabilityQuery(url, route: .attachmentContent, reference: reference)
    }
  }
  #expect(
    !String(describing: ApiCapabilityQuery(expires: "123", token: "secret")).contains("secret"))
  #expect(!String(reflecting: ApiAuthInput(promptId: "p", value: "secret")).contains("secret"))
}
@Test func attachmentAccessRenewsExactlyOnceOnExpiryNotOther403() async throws {
  let reference = ReplyPartReference(threadId: "t", messageId: "m", partId: "p")
  let partData = Data(
    #"{"type":"attachment","id":"p","artifactId":"a","name":"example.txt","mediaType":"text/plain","sizeBytes":7,"integrityId":"i","contentUrl":"/api/v1/threads/t/messages/m/reply-attachments/p/content?expires=1&token=fictional"}"#
      .utf8)
  let part = try JSONDecoder().decode(ReplyAttachmentPart.self, from: partData)
  let expiry = HTTPResponse(
    data: Data(#"{"error":{"code":"reply_access_expired","message":"Expired"}}"#.utf8), status: 410)
  let access = Data("{\"part\":\(String(decoding: partData, as: UTF8.self))}".utf8)
  let transport = ScriptedTransport([
    .response(expiry), .response(.init(data: access)),
    .response(.init(data: Data("bytes".utf8), contentType: "text/plain")),
  ])
  let api = APIClient(endpoint: Scenario.endpoint, transport: transport)
  #expect(
    try await CapabilityService(endpoint: Scenario.endpoint, api: api).attachment(
      part, reference: reference) == Data("bytes".utf8))
  #expect(await transport.requests.map(\.httpMethod) == ["GET", "POST", "GET"])
  let denied = ScriptedTransport([
    .response(.init(data: Data(#"{"error":{"code":"denied","message":"No"}}"#.utf8), status: 403))
  ])
  await #expect(throws: APIError.self) {
    try await CapabilityService(
      endpoint: Scenario.endpoint, api: APIClient(endpoint: Scenario.endpoint, transport: denied)
    ).attachment(part, reference: reference)
  }
  #expect(await denied.requests.count == 1)
}

/// Request-local immutable scripts: no global registry and no networking fallback.
final class LocalURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let encoded = request.value(forHTTPHeaderField: "X-Fixture-Body"),
      let data = Data(base64Encoded: encoded), let url = request.url
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil,
      headerFields: [
        "Content-Type": request.value(forHTTPHeaderField: "X-Fixture-Content-Type")
          ?? "application/json", "ETag": "local",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
@Test func perSessionURLProtocolSmokeWithoutGlobalMutableMocks() async throws {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [LocalURLProtocol.self]
  let first = URLSessionTransport(configuration: config)
  let second = URLSessionTransport(configuration: config)
  var a = RequestBuilder(endpoint: Scenario.endpoint).get(.health)
  var b = a
  a.setValue(Data("first".utf8).base64EncodedString(), forHTTPHeaderField: "X-Fixture-Body")
  b.setValue(Data("second".utf8).base64EncodedString(), forHTTPHeaderField: "X-Fixture-Body")
  async let ar = first.send(a)
  async let br = second.send(b)
  #expect(try await ar.data == Data("first".utf8))
  #expect(try await br.data == Data("second".utf8))
}

private actor SensitiveErrorTransport: HTTPTransport {
  func send(_ request: URLRequest) throws -> HTTPResponse {
    throw URLError(
      .networkConnectionLost,
      userInfo: [
        NSURLErrorFailingURLStringErrorKey:
          "https://console.example.ts.net/private?token=fictional-secret"
      ])
  }
}
@Test func transportErrorsDoNotLeakCapabilityURLsAndConflictsKeepServerCodes() async throws {
  let api = APIClient(endpoint: Scenario.endpoint, transport: SensitiveErrorTransport())
  do {
    _ = try await api.health()
    Issue.record("Expected transport error")
  } catch let error as URLError {
    #expect(error.code == .networkConnectionLost)
    #expect(error.userInfo.isEmpty)
    #expect(!String(reflecting: error).contains("fictional-secret"))
  }
  let conflict = ScriptedTransport([
    .response(
      .init(
        data: Data(#"{"error":{"code":"submission_conflict","message":"private prose"}}"#.utf8),
        status: 409))
  ])
  let conflicted = APIClient(endpoint: Scenario.endpoint, transport: conflict)
  await #expect(throws: APIError(status: 409, code: "submission_conflict")) {
    try await conflicted.startSubmission(id: "thread", body: .init(submissionId: "fictional"))
  }
}

@Test func queryValuesRoundTripThroughFormStyleServerDecoding() throws {
  let values = ["q": "C++ & = # % 雪", "cursor": "+/&=#%"]
  let request = try RequestBuilder(endpoint: Scenario.endpoint).request(
    route: APIRoute.searchThreads.descriptor, query: values)
  let query = try #require(
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
  #expect(!query.contains("+"))
  #expect(query.contains("%2B"))
  let decoded = try query.split(separator: "&").reduce(into: [String: String]()) { result, item in
    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let key = try #require(
      String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
    let value: String = try #require(
      String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
    result[key] = value
  }
  #expect(decoded == values)
}

@Test func manualCompactionHasItsOwnLongerRequestBudget() async throws {
  let client = APIClient(endpoint: try ConsoleEndpoint("https://console.example.ts.net"))
  let compact = try await client.request(
    .compact, parameters: ["id": "thread-example"], query: nil, body: ApiEmpty())
  #expect(compact.timeoutInterval == APIClient.manualCompactionTimeout)
  #expect(compact.timeoutInterval > 15)
  let patch = try await client.request(
    .patchThread, parameters: ["id": "thread-example"], query: nil,
    body: ApiPatchThread(title: "Title"))
  #expect(patch.timeoutInterval == 15)
}

@Test func pendingCronReplyRetainsOnlyValidatedAllowlistedOperationID() async throws {
  let id = UUID()
  for (status, code, detail, expected) in [
    (409, "cron_reply_pending", id.uuidString, id),
    (503, "cron_reply_pending", id.uuidString, nil),
    (409, "other_conflict", id.uuidString, nil),
    (409, "cron_reply_pending", "not-a-uuid", nil),
  ] {
    let transport = ScriptedTransport([
      .response(
        .init(
          data: Data(
            """
            {"error":{"code":"\(code)","message":"fictional private prose",
            "details":{"operationId":"\(detail)","pendingSince":"private","other":"private"}}}
            """.utf8), status: status))
    ])
    let api = APIClient(endpoint: Scenario.endpoint, transport: transport)
    do {
      _ = try await api.createCronReply(
        id: "agent", jobId: "job", runId: "run",
        body: .init(operationId: UUID().uuidString, snapshotKind: "summary"))
      Issue.record("Expected pending error")
    } catch let error as APIError {
      #expect(error.cronReplyPendingOperationID == expected)
      #expect(!String(reflecting: error).contains("private"))
    }
    #expect(await transport.requests.count == 1)
  }
}
