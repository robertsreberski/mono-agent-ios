// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

extension ConsoleStore {
  public var canSend: Bool {
    selectedConversation?.thread.canSend == true && selectedConversation?.thread.archivedAt == nil
  }
  public var canUpload: Bool {
    selectedConversation?.thread.canUpload == true && selectedConversation?.thread.archivedAt == nil
  }
  /// Uploads and reservations are visible-context memory only. Nothing here enters a disk record.
  public func stageUploads(_ files: [UploadFile]) async throws {
    guard let limits = bootstrap?.limits, canUpload else { throw SubmissionError.notReady }
    let generation = epoch
    let selected = selection
    let service = UploadService(api: api)
    let existing = stagedAttachments
    let task = Task { try await service.upload(files, limits: limits, existing: existing) }
    let id = UUID()
    uploadTasks[id] = task
    defer { uploadTasks[id] = nil }
    let attachments = try await task.value
    guard epoch == generation, selection == selected, !backgrounded else {
      await service.discard(attachments)
      throw CancellationError()
    }
    stagedAttachments += attachments
  }
  public func discardStagedUploads() async {
    for task in uploadTasks.values { task.cancel() }
    uploadTasks.removeAll()
    let abandoned = stagedAttachments
    stagedAttachments.removeAll()
    await UploadService(api: api).discard(abandoned)
    await uploads.disposeVisible()
  }
}
