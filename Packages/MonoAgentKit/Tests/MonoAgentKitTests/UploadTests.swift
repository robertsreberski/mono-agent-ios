// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentTestSupport
import Testing

@testable import MonoAgentKit

actor UploadScript: FileUploadTransport {
  let upload: Data
  let fail: Bool
  let cancelDuringUpload: Bool
  var methods: [String] = []
  var contentTypes: [String?] = []
  var received: Data?
  init(fail: Bool = false, cancelDuringUpload: Bool = false) throws {
    self.fail = fail
    self.cancelDuringUpload = cancelDuringUpload
    upload = try fixture("upload-create")
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    methods.append(request.httpMethod!)
    if request.httpMethod == "DELETE" { return .init(data: Data(), status: 204) }
    return .init(data: upload, status: 201)
  }
  func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void)
    async throws -> HTTPResponse
  {
    methods.append(request.httpMethod!)
    contentTypes.append(request.value(forHTTPHeaderField: "Content-Type"))
    received = try Data(contentsOf: file)
    progress(0.5)
    progress(0.99)
    if fail { throw URLError(.networkConnectionLost) }
    if cancelDuringUpload { throw CancellationError() }
    let response = try JSONDecoder().decode(ApiUpload.self, from: upload)
    var accepted = response
    accepted.attachment.uploaded = true
    return .init(data: try JSONEncoder().encode(accepted))
  }
}
func uploadFile() throws -> UploadFile {
  let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      ".build/UploadTests", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(UUID().uuidString)
  try Data("example".utf8).write(to: url)
  return .init(url: url, name: "example.txt", contentType: "text/plain", sizeBytes: 7)
}
@Test func uploadValidatesMimeAndHardCeilings() throws {
  let file = UploadFile(
    url: URL(fileURLWithPath: "/fictional"), name: "example", contentType: "text/plain",
    sizeBytes: 20 * 1024 * 1024 + 1)
  #expect(throws: UploadValidationError.size) {
    try UploadService.validate([file], limits: .init(accept: ["text/plain"]))
  }
  let small = UploadFile(url: file.url, name: "example", contentType: "text/plain", sizeBytes: 1)
  #expect(throws: UploadValidationError.type) {
    try UploadService.validate([small], limits: .init(accept: ["image/*"]))
  }
  #expect(throws: UploadValidationError.count) {
    try UploadService.validate(
      Array(repeating: small, count: 11), limits: .init(accept: ["text/plain"]))
  }
  #expect(throws: UploadValidationError.turnSize) {
    try UploadService.validate(
      [small, small], limits: .init(maxTurnBytes: 1, accept: ["text/plain"]))
  }
}
@Test func uploadIsTwoStepRawFileWithAcceptedProgress() async throws {
  let script = try UploadScript()
  let api = APIClient(endpoint: Scenario.endpoint, transport: script)
  let file = try uploadFile()
  defer { try? FileManager.default.removeItem(at: file.url) }
  let (progress, continuation) = AsyncStream<UploadProgress>.makeStream()
  let result = try await UploadService(api: api).upload(
    [file], limits: .init(accept: ["text/plain"])
  ) { continuation.yield($0) }
  continuation.finish()
  var values: [Double] = []
  for await value in progress { values.append(value.fraction) }
  #expect(values == [0.5, 0.99, 1])
  #expect(result.first?.uploaded == true)
  #expect(await script.methods == ["POST", "PUT"])
  #expect(await script.contentTypes == ["application/octet-stream"])
  #expect(await script.received == Data("example".utf8))
}
@Test(arguments: [false, true])
func uploadFailureOrCancellationDeletesReservationAndNeverReportsComplete(cancel: Bool) async throws
{
  let script = try UploadScript(fail: !cancel, cancelDuringUpload: cancel)
  let file = try uploadFile()
  defer { try? FileManager.default.removeItem(at: file.url) }
  let (progress, continuation) = AsyncStream<UploadProgress>.makeStream()
  await #expect(throws: (any Error).self) {
    try await UploadService(api: APIClient(endpoint: Scenario.endpoint, transport: script)).upload(
      [file], limits: .init(accept: ["text/plain"])
    ) { continuation.yield($0) }
  }
  continuation.finish()
  for await value in progress { #expect(value.fraction < 1) }
  #expect(await script.methods == ["POST", "PUT", "DELETE"])
}

private actor SuspendedUpload: FileUploadTransport {
  var started = false
  var deleted = false
  let data: Data
  init(data: Data) { self.data = data }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()
    if request.httpMethod == "DELETE" {
      deleted = true
      return .init(data: Data(), status: 204)
    }
    return .init(data: data, status: 201)
  }
  func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void)
    async throws -> HTTPResponse
  {
    started = true
    try await Task.sleep(for: .seconds(3600))  // cancelled explicitly, never waited out
    throw URLError(.resourceUnavailable)
  }
}
@Test(.timeLimit(.minutes(1))) func callerTaskCancellationStillRunsReservationCleanup() async throws
{
  let script = SuspendedUpload(data: try fixture("upload-create"))
  let file = try uploadFile()
  defer { try? FileManager.default.removeItem(at: file.url) }
  let service = UploadService(api: APIClient(endpoint: Scenario.endpoint, transport: script))
  let task = Task { try await service.upload([file], limits: .init(accept: ["text/plain"])) }
  try #require(await eventually { await script.started })
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await script.deleted)
}
