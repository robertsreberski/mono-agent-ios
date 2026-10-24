// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public enum McpAppStoreError: Error, Sendable, Equatable { case unavailable, accessRequired }

/// One ephemeral session, never part of a cache/authored/journal record. No capability URL
/// is exposed to App: only the sanitized resource and a generation-bound session handle.
@MainActor @Observable
public final class McpAppAccess {
  public let profileID: UUID
  public let reference: ReplyPartReference
  public let generation = UUID()
  public internal(set) var resource: ApiMcpAppResource?
  public internal(set) var retryRequiresConsent = false
  public internal(set) var isClosed = false
  @ObservationIgnored public var onClose: (@MainActor () -> Void)?
  let published: McpAppPart
  let epoch: UInt64
  let selection: UInt64
  let conversation: ConversationState
  @ObservationIgnored var current: McpAppPart?
  @ObservationIgnored var revision: UInt64 = 0
  @ObservationIgnored var cancellations: [UUID: @MainActor () -> Void] = [:]

  init(
    profileID: UUID, reference: ReplyPartReference, published: McpAppPart,
    epoch: UInt64, selection: UInt64, conversation: ConversationState
  ) {
    self.profileID = profileID
    self.reference = reference
    var identity = published
    identity.resourceUrl = nil
    identity.bridgeUrl = nil
    self.published = identity
    self.epoch = epoch
    self.selection = selection
    self.conversation = conversation
  }
  func perform<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T)
    async throws -> T
  {
    let id = UUID()
    let task = Task {
      try Task.checkCancellation()
      return try await operation()
    }
    cancellations[id] = { task.cancel() }
    defer { cancellations[id] = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  func close() {
    guard !isClosed else { return }
    for cancel in cancellations.values { cancel() }
    cancellations.removeAll()
    isClosed = true
    current = nil
    resource = nil
    retryRequiresConsent = false
    revision &+= 1
    let notify = onClose
    onClose = nil
    notify?()
  }
}

extension ConsoleStore {
  public func loadMcpApp(threadID: String, messageID: String, partID: String) async throws
    -> McpAppAccess
  {
    let reference = ReplyPartReference(threadId: threadID, messageId: messageID, partId: partID)
    guard mcpAvailable(threadID: threadID), let part = mcpPart(reference),
      let conversation = conversations[threadID]
    else { throw McpAppStoreError.unavailable }
    mcpApps[reference]?.close()
    let session = McpAppAccess(
      profileID: profile.id, reference: reference, published: part,
      epoch: epoch, selection: selection, conversation: conversation)
    mcpApps[reference] = session
    do {
      let loaded = try await session.perform { [capabilities] in
        try await capabilities.loadMcpApp(part, reference: reference)
      }
      try checkMcpSession(session)
      session.current = loaded.access
      var resource = loaded.resource
      resource.app.resourceUrl = nil
      resource.app.bridgeUrl = nil
      session.resource = resource
      return session
    } catch {
      try checkMcpSession(session)
      if mcpApps[reference] === session {
        session.close()
        mcpApps[reference] = nil
      }
      throw error
    }
  }

  /// Explicit renewal is separate from retry. Confirmed effects always need fresh native consent.
  public func renewMcpApp(_ session: McpAppAccess) async throws {
    try checkMcpSession(session)
    session.revision &+= 1
    let revision = session.revision
    let access = try await session.perform { [capabilities] in
      try await capabilities.renewMcpAppAccess(session.published, reference: session.reference)
    }
    try checkMcpSession(session)
    if session.revision == revision {
      session.current = access
      session.retryRequiresConsent = false
    }
  }

  public func requestMcpApp(_ body: ApiMcpAppRequest, session: McpAppAccess) async throws
    -> JSONValue
  {
    try checkMcpSession(session)
    guard let access = session.current else { throw McpAppStoreError.accessRequired }
    let revision = session.revision
    do {
      let reply = try await session.perform { [capabilities] in
        try await capabilities.requestMcpApp(
          body, published: session.published,
          access: access, reference: session.reference)
      }
      try checkMcpSession(session)
      // Renewal changes capability freshness, not the identity of a completed result.
      if session.revision == revision, reply.access != session.current {
        session.current = reply.access
        session.revision &+= 1
      }
      session.retryRequiresConsent = false
      return reply.result.result
    } catch {
      try checkMcpSession(session)
      if let apiError = error as? APIError, apiError.code == "reply_access_expired",
        body.method != "resources/read"
      {
        session.retryRequiresConsent = true
      }
      throw error
    }
  }

  public func closeMcpApp(_ session: McpAppAccess) {
    session.close()
    if mcpApps[session.reference] === session { mcpApps[session.reference] = nil }
  }

  func invalidateMcpApps() {
    for session in mcpApps.values { session.close() }
    mcpApps.removeAll()
  }
  private func mcpAvailable(threadID: String) -> Bool {
    enabled && started && !stopping && !stopped && !backgrounded && connection != .offline
      && selectedThreadID == threadID && !tombstones.keys.contains(threadID)
  }
  private func mcpPart(_ reference: ReplyPartReference) -> McpAppPart? {
    conversations[reference.threadId]?.record.messages.first { $0.id == reference.messageId }?.parts
      .compactMap {
        if case .mcpApp(let part) = $0, part.id == reference.partId { return part }
        return nil
      }.first
  }
  private func checkMcpSession(_ session: McpAppAccess) throws {
    guard !Task.isCancelled, !session.isClosed, session.profileID == profile.id,
      mcpAvailable(threadID: session.reference.threadId), epoch == session.epoch,
      selection == session.selection,
      conversations[session.reference.threadId] === session.conversation,
      mcpApps[session.reference] === session,
      mcpPart(session.reference)?.hasSameMcpIdentity(as: session.published) == true
    else {
      session.close()
      if mcpApps[session.reference] === session { mcpApps[session.reference] = nil }
      throw CancellationError()
    }
  }
}
