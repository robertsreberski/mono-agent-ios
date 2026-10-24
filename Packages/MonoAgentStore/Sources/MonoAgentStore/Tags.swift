// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public struct TagDeletionConfirmation: Sendable, Identifiable {
  public let id: UUID
  public let tagID: String
  let epoch: UInt64
  let selection: UInt64
  public var message: String {
    "Delete this tag from all conversations? Conversations are kept. This cannot be undone."
  }
}

extension ConsoleStore {
  public func createTag(sourceID: String, name: String, color: String) async throws -> WebTag {
    try requireOrganize()
    guard Self.validOrganizeName(name) else { throw OrganizeError.invalid }
    let generation = epoch
    let selected = selection
    do {
      let value = try await api.createTag(
        body: .init(
          sourceId: sourceID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          color: color)
      ).tag
      try checkOrganizeResponse(epoch: generation, selection: selected)
      adoptTag(value)
      return value
    } catch { try organizeFailure(error, generation: generation, selected: selected) }
  }

  public func updateTag(id: String, name: String, color: String) async throws {
    try requireOrganize()
    guard Self.validOrganizeName(name) else { throw OrganizeError.invalid }
    let generation = epoch
    let selected = selection
    do {
      let value = try await api.patchTag(
        id: id,
        body: .init(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color)
      ).tag
      try checkOrganizeResponse(epoch: generation, selection: selected)
      adoptTag(value)
    } catch { try organizeFailure(error, generation: generation, selected: selected) }
  }

  func adoptTag(_ value: WebTag) {
    observation &+= 1
    if let index = tags.firstIndex(where: { $0.id == value.id }) {
      if tags[index].revision <= value.revision { tags[index] = value }
    } else {
      tags.append(value)
    }
    errorMessage = nil
    scheduleCache()
  }
  public func requestTagDeletion(id: String) {
    guard canOrganize, tags.contains(where: { $0.id == id }) else { return }
    tagDeletionConfirmation = .init(id: UUID(), tagID: id, epoch: epoch, selection: selection)
  }
  public func cancelTagDeletion() { tagDeletionConfirmation = nil }
  public func confirmTagDeletion(_ id: UUID) async throws {
    guard let request = tagDeletionConfirmation, request.id == id else { throw CancellationError() }
    tagDeletionConfirmation = nil
    try checkOrganizeResponse(epoch: request.epoch, selection: request.selection)
    do {
      try await api.deleteTag(id: request.tagID)
      try checkOrganizeResponse(epoch: request.epoch, selection: request.selection)
      observation &+= 1
      tags.removeAll { $0.id == request.tagID }
      mutateOrganizeRows { $0.tagIds.removeAll { $0 == request.tagID } }
      errorMessage = nil
      scheduleCache()
    } catch { try organizeFailure(error, generation: request.epoch, selected: request.selection) }
  }

  /// Dashboard menus may target a listed conversation not currently held in memory.
  func ensureOrganizeConversation(_ threadID: String) async throws {
    try requireOrganize()
    if conversations[threadID] != nil { return }
    let generation = epoch
    let selected = selection
    let detail: ApiThreadDetail
    do {
      detail = try await api.thread(id: threadID, query: .init(), etag: nil).valueRequired()
    } catch { try organizeFailure(error, generation: generation, selected: selected) }
    try checkOrganizeResponse(epoch: generation, selection: selected)
    guard tombstones[threadID] == nil, detail.thread.id == threadID else {
      throw CancellationError()
    }
    hold(
      .init(
        thread: detail.thread, messages: detail.messages, nextCursor: detail.messagesNextCursor,
        savedAt: Date()))
  }

  public func setConversationTags(threadID: String, tagIDs: [String]) async throws {
    try await ensureOrganizeConversation(threadID)
    guard let thread = conversations[threadID]?.thread, pendingConversationActions[threadID] == nil
    else { throw OrganizeError.unavailable }
    let ids = tagIDs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    guard
      ids.allSatisfy({ id in
        thread.tagIds.contains(id)
          || tags.contains { $0.id == id && $0.sourceId == thread.sourceId }
      })
    else { throw OrganizeError.invalid }
    let generation = epoch
    let selected = selection
    queueConversationPatch(threadID: threadID, body: .init(tagIds: ids))
    try await settleThreadWrites(threadID)
    try checkOrganizeResponse(epoch: generation, selection: selected)
  }
}
