// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public protocol FileUploadTransport: HTTPTransport {
  func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void)
    async throws -> HTTPResponse
}
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
  let progress: @Sendable (Double) -> Void
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    if totalBytesExpectedToSend > 0 {
      progress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
extension APIClient {
  func upload(id: String, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    -> ApiUpload
  {
    guard let transport = transport as? any FileUploadTransport else {
      throw APIError(status: 0, code: "upload_transport_unavailable")
    }
    var request = try request(.uploadContent, parameters: ["id": id], query: nil, body: nil)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let response: HTTPResponse
    do {
      response = try await transport.upload(
        request, file: file, progress: { if $0.isFinite { progress(min(0.99, max(0, $0))) } })
    } catch is CancellationError { throw CancellationError() } catch let error as URLError {
      throw URLError(error.code)
    } catch { throw APIError(status: 0, code: "upload_failed") }
    let result: ApiUpload = try decode(response, route: .uploadContent)
    guard result.attachment.uploaded else {
      throw APIError(status: 200, code: "upload_not_accepted")
    }
    progress(1)
    return result
  }
}
public struct UploadFile: Sendable {
  public let url: URL
  public let name: String
  public let contentType: String
  public let sizeBytes: Int
  public init(url: URL, name: String, contentType: String, sizeBytes: Int) {
    self.url = url
    self.name = name
    self.contentType = contentType
    self.sizeBytes = sizeBytes
  }
}
public enum UploadValidationError: Error, Sendable, Equatable {
  case type, size, count, turnSize, changedFile
}
public struct UploadProgress: Sendable, Equatable {
  public let fileIndex: Int
  public let fraction: Double
}
public actor UploadService {
  private let api: any ConsoleAPI
  public init(api: any ConsoleAPI) { self.api = api }
  public static func validate(
    _ files: [UploadFile], limits: UploadLimits, existing: [WebAttachment] = []
  ) throws {
    let files =
      files
      + existing.map {
        UploadFile(
          url: URL(fileURLWithPath: "/"), name: $0.name, contentType: $0.contentType,
          sizeBytes: $0.sizeBytes)
      }
    guard files.count <= min(10, limits.maxFilesPerTurn) else { throw UploadValidationError.count }
    var total = 0
    for file in files {
      guard file.sizeBytes >= 0, file.sizeBytes <= min(20 * 1024 * 1024, limits.maxFileBytes) else {
        throw UploadValidationError.size
      }
      guard
        limits.accept.contains(where: {
          $0 == file.contentType || $0 == "*/*"
            || ($0.hasSuffix("/*") && file.contentType.hasPrefix($0.dropLast()))
        })
      else { throw UploadValidationError.type }
      total += file.sizeBytes
    }
    guard total <= min(64 * 1024 * 1024, limits.maxTurnBytes) else {
      throw UploadValidationError.turnSize
    }
  }
  /// Cancel the caller's Task to cancel the upload. Reservations are deleted best-effort
  /// from an independent structured cleanup task, including a cancelled parent task.
  public func upload(
    _ files: [UploadFile], limits: UploadLimits, existing: [WebAttachment] = [],
    progress: @escaping @Sendable (UploadProgress) -> Void = { _ in }
  ) async throws -> [WebAttachment] {
    try Self.validate(files, limits: limits, existing: existing)
    var reserved: [String] = []
    do {
      var attachments: [WebAttachment] = []
      for (index, file) in files.enumerated() {
        try Task.checkCancellation()
        let actualSize = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actualSize == file.sizeBytes else { throw UploadValidationError.changedFile }
        let reservation = try await api.createUpload(
          body: .init(name: file.name, contentType: file.contentType, sizeBytes: file.sizeBytes))
        reserved.append(reservation.attachment.id)
        try Task.checkCancellation()
        let uploaded = try await api.uploadContent(id: reservation.attachment.id, file: file.url) {
          value in
          progress(.init(fileIndex: index, fraction: value))
        }
        attachments.append(uploaded.attachment)
      }
      return attachments
    } catch {
      let api = api
      let cleanup = Task { for id in reserved { try? await api.deleteUpload(id: id) } }
      await cleanup.value
      throw error
    }
  }
  public func discard(_ attachments: [WebAttachment]) async {
    for attachment in attachments { try? await api.deleteUpload(id: attachment.id) }
  }
}
