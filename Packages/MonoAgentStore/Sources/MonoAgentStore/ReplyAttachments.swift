// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import MonoAgentKit

public enum ReplyDownloadFailure: Error, Sendable, Equatable {
  case unavailable, expired, tooLarge, integrity, interrupted, cacheFull
  public init(_ error: any Error) {
    switch error {
    case ReplyContentError.tooLarge: self = .tooLarge
    case is ReplyFileCacheError: self = .cacheFull
    case ReplyContentError.integrity: self = .integrity
    case ReplyContentError.unavailable, CapabilityError.missingURL, CapabilityError.invalidURL:
      self = .unavailable
    case let error as APIError:
      if error.status == 404 || error.status == 410 {
        self = .unavailable
        return
      }
      switch error.code {
      case "reply_access_expired": self = .expired
      case "reply_part_expired", "reply_part_not_found", "reply_artifact_not_found",
        "reply_artifact_unavailable", "reply_attachment_unavailable":
        self = .unavailable
      case "reply_attachment_too_large", "reply_artifact_too_large": self = .tooLarge
      default: self = .interrupted
      }
    default: self = .interrupted
    }
  }
  public var message: String {
    switch self {
    case .unavailable: "This file is no longer available."
    case .expired: "Download access expired. Refresh and try again."
    case .tooLarge: "This file is too large to download."
    case .cacheFull: "The download cache is full. Close other files and try again."
    case .integrity: "The downloaded file failed integrity validation."
    case .interrupted: "The download was interrupted. Check your connection and try again."
    }
  }
}

extension ConsoleStore {
  /// Views receive only an app-owned local file. Authorization material stays inside Kit.
  public func downloadReplyAttachment(threadID: String, messageID: String, partID: String)
    async throws -> ReplyFileLease
  {
    guard enabled, started, !stopping, !backgrounded, selectedThreadID == threadID,
      !tombstones.keys.contains(threadID), let state = conversations[threadID],
      let part = replyAttachment(threadID: threadID, messageID: messageID, partID: partID)
    else { throw ReplyDownloadFailure.unavailable }
    let generation = epoch
    let selected = selection
    func valid() -> Bool {
      enabled && started && !stopping && !backgrounded && epoch == generation
        && selection == selected && selectedThreadID == threadID
        && conversations[threadID] === state
        && !tombstones.keys.contains(threadID)
        && replyAttachment(threadID: threadID, messageID: messageID, partID: partID)?.hasSameFile(
          as: part) == true
        && !Task.isCancelled
    }
    guard part.sizeBytes <= ReplyFileCache.maximumFileBytes, part.sizeBytes >= 0 else {
      throw ReplyDownloadFailure.tooLarge
    }
    // A canonical tuple is collision-safe and contains no capability fields.
    let key = String(
      decoding: try JSONEncoder().encode([
        threadID, messageID, partID, part.artifactId, part.integrityId, String(part.sizeBytes),
        part.name, part.mediaType, part.expiresAt ?? "",
      ]), as: UTF8.self)
    let hit = try await replyFiles.cached(key: key, name: part.name)
    if let hit {
      guard valid() else {
        try? await replyFiles.release(hit)
        throw CancellationError()
      }
      return hit
    }
    let data: Data
    do {
      data = try await CapabilityService(endpoint: profile.endpoint, api: api).downloadAttachment(
        part, reference: .init(threadId: threadID, messageId: messageID, partId: partID))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard valid() else { throw CancellationError() }
      throw ReplyDownloadFailure(error)
    }
    guard valid() else { throw CancellationError() }
    let lease = try await replyFiles.insert(data, key: key, name: part.name)
    guard valid() else {
      try? await replyFiles.release(lease)
      throw CancellationError()
    }
    return lease
  }
  /// Only a sent, held upload is downloadable. Durable IDs survive cache sanitization;
  /// advertised URLs are neither followed nor retained in the binary file cache.
  public func downloadMessageAttachment(threadID: String, messageID: String, attachmentID: String)
    async throws -> ReplyFileLease
  {
    func attachment() -> WebAttachment? {
      conversations[threadID]?.messages.first(where: { $0.id == messageID })?.attachments.first(
        where: { $0.id == attachmentID })
    }
    guard enabled, started, !stopping, !backgrounded, selectedThreadID == threadID,
      !tombstones.keys.contains(threadID), let state = conversations[threadID],
      let file = attachment(),
      file.uploaded, file.status == "committed"
    else { throw ReplyDownloadFailure.unavailable }
    let generation = epoch
    let selected = selection
    func valid() -> Bool {
      enabled && started && !stopping && !backgrounded && epoch == generation
        && selection == selected
        && selectedThreadID == threadID && conversations[threadID] === state
        && !tombstones.keys.contains(threadID) && attachment()?.hasSameFile(as: file) == true
        && !Task.isCancelled
    }
    guard file.sizeBytes >= 0, file.sizeBytes <= ReplyFileCache.maximumFileBytes else {
      throw ReplyDownloadFailure.tooLarge
    }
    let key = String(
      decoding: try JSONEncoder().encode([
        "sent-upload", threadID, messageID, file.id, file.name, file.contentType,
        String(file.sizeBytes), file.createdAt,
      ]), as: UTF8.self)
    if let hit = try await replyFiles.cached(key: key, name: file.name) {
      guard valid() else {
        try? await replyFiles.release(hit)
        throw CancellationError()
      }
      return hit
    }
    let data: Data
    do { data = try await api.downloadUpload(file) } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard valid() else { throw CancellationError() }
      throw ReplyDownloadFailure(error)
    }
    guard valid() else { throw CancellationError() }
    let lease = try await replyFiles.insert(data, key: key, name: file.name)
    guard valid() else {
      try? await replyFiles.release(lease)
      throw CancellationError()
    }
    return lease
  }
  public func releaseReplyFile(_ lease: ReplyFileLease) async {
    try? await replyFiles.release(lease)
  }
  public func clearReplyFileCache() async throws {
    try await replyFiles.clear()
    await replyImages.clear()
  }
  public func decodeReplyImage(_ lease: ReplyFileLease) async throws -> CGImage {
    let generation = epoch
    let selected = selection
    guard enabled, started, !stopping, !backgrounded else { throw ReplyDownloadFailure.unavailable }
    let image = try await replyImages.image(at: lease.url, lean: effectiveDataMode == .lean)
    guard epoch == generation, selection == selected, enabled, started, !stopping, !backgrounded,
      !Task.isCancelled
    else { throw CancellationError() }
    return image
  }

  func replyAttachment(threadID: String, messageID: String, partID: String) -> ReplyAttachmentPart?
  {
    conversations[threadID]?.messages.first(where: { $0.id == messageID })?.parts.compactMap {
      if case .attachment(let value) = $0, value.id == partID { return value }
      return nil
    }.first
  }
}
