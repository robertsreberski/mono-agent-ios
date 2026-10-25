// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// One file that is still uploading. Visible-context memory only; never persisted.
public struct UploadProgressItem: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let contentType: String
  public let sizeBytes: Int
  public internal(set) var fraction: Double
}

extension ConsoleStore {
  /// The agent that owns the selected composer context (a conversation or a new one).
  public var selectedAgent: WebAgentSummary? {
    let source = selectedConversation?.thread.sourceId ?? selectedBucket?.sourceID
    return agents.first { $0.sourceId == source }
  }
  /// Mirrors the web console's `canSendInConsole`: live, agent online, conversation permits it.
  /// A new conversation (no selected thread) is sendable whenever its agent is.
  public var canSend: Bool {
    guard connection == .live, let agent = selectedAgent, agent.status != "offline" else {
      return false
    }
    guard selectedThreadID != nil else { return true }
    guard let thread = selectedConversation?.thread else { return false }
    return thread.canSend && thread.archivedAt == nil
  }
  /// Mirrors the web console's `canUploadInConsole`, including new conversations.
  public var canUpload: Bool {
    guard connection == .live, let agent = selectedAgent, agent.status != "offline",
      agent.supportsAttachments
    else { return false }
    guard selectedThreadID != nil else { return true }
    guard let thread = selectedConversation?.thread else { return false }
    return thread.canUpload && thread.archivedAt == nil
  }
  /// Uploads and reservations are visible-context memory only. Nothing here enters a disk record.
  public func stageUploads(_ files: [UploadFile]) async throws {
    guard let limits = bootstrap?.limits, canUpload else { throw SubmissionError.notReady }
    let selected = selection
    let service = UploadService(api: api)
    let existing = stagedAttachments
    // Validate before any progress row appears, so a rejected pick shows only its error.
    try UploadService.validate(files, limits: limits, existing: existing)
    let items = files.map {
      UploadProgressItem(
        id: UUID(), name: $0.name, contentType: $0.contentType, sizeBytes: $0.sizeBytes,
        fraction: 0)
    }
    let ids = items.map(\.id)
    uploadProgress += items
    defer { uploadProgress.removeAll { ids.contains($0.id) } }
    let task = Task { [weak self] in
      try await service.upload(files, limits: limits, existing: existing) { [weak self] value in
        guard ids.indices.contains(value.fileIndex) else { return }
        let id = ids[value.fileIndex]
        Task { @MainActor in self?.noteUploadProgress(id, fraction: value.fraction) }
      }
    }
    let id = UUID()
    uploadTasks[id] = task
    defer { uploadTasks[id] = nil }
    let attachments = try await task.value
    // Upload ownership follows the composer context, not the stream/scene epoch.
    // Cancellation still rejects a late transport completion after explicit abandonment.
    guard selection == selected, !task.isCancelled, !stopped, !stopping else {
      await service.discard(attachments)
      throw CancellationError()
    }
    stagedAttachments += attachments
  }
  func noteUploadProgress(_ id: UUID, fraction: Double) {
    guard let index = uploadProgress.firstIndex(where: { $0.id == id }), fraction.isFinite else {
      return
    }
    uploadProgress[index].fraction = max(uploadProgress[index].fraction, min(1, max(0, fraction)))
  }
  /// Explicit removal of one staged chip. Files protected by an active submission stay staged.
  public func discardStagedUpload(_ id: String) async {
    guard !protectedAttachmentIDs.contains(id),
      let attachment = stagedAttachments.first(where: { $0.id == id })
    else { return }
    stagedAttachments.removeAll { $0.id == id }
    await UploadService(api: api).discard([attachment])
  }
  public func discardStagedUploads() async {
    for task in uploadTasks.values { task.cancel() }
    uploadTasks.removeAll()
    uploadProgress.removeAll()
    let protected = protectedAttachmentIDs
    let abandoned = stagedAttachments.filter { !protected.contains($0.id) }
    stagedAttachments.removeAll { !protected.contains($0.id) }
    await UploadService(api: api).discard(abandoned)
    await uploads.disposeVisible()
  }
}
