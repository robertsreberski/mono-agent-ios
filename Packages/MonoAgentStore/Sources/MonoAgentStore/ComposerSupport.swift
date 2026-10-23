// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// The composer's view of one agent's skill registry (web `SkillRegistryState`).
public enum SkillRegistryState: Sendable, Equatable {
  case loading
  /// `stale` keeps the previous items while a refresh failed or the console is not live.
  case ready(items: [WebSkillInfo], total: Int?, truncated: Bool, stale: Bool)
  /// Server-reported `error`, `unsupported` or `offline`, or a local read failure (`error`).
  case unavailable(String)

  public var items: [WebSkillInfo] {
    if case .ready(let items, _, _, _) = self { return items }
    return []
  }
  /// Insertion is only allowed from a fresh, ready registry (web `canInsert`).
  public var canInsert: Bool {
    if case .ready(_, _, _, let stale) = self { return !stale }
    return false
  }
}

public enum AskAnswerError: Error, Sendable, Equatable {
  case notReady
  /// `invalid_answer`: the form is incomplete for the server's rules.
  case incomplete
  /// Any other rejection: expired, cancelled, superseded or evicted.
  case inactive(String?)
}

extension ConsoleStore {
  /// Loads (or refreshes) one agent's skill registry. Failures keep earlier items as stale.
  public func loadSkills(sourceID: String) async {
    let previous = skillRegistries[sourceID]
    if previous == nil { skillRegistries[sourceID] = .loading }
    let generation = epoch
    guard started, !backgrounded, connection == .live else {
      skillRegistries[sourceID] = Self.staleRegistry(previous, fallback: "offline")
      return
    }
    do {
      let registry = try await api.skills(id: sourceID, etag: nil).valueRequired()
      guard epoch == generation else { return }
      skillRegistries[sourceID] =
        registry.status == "ready"
        ? .ready(
          items: registry.items, total: registry.total, truncated: registry.truncated == true,
          stale: false)
        : .unavailable(registry.status)
    } catch {
      guard epoch == generation else { return }
      skillRegistries[sourceID] = Self.staleRegistry(previous, fallback: "error")
    }
  }
  static func staleRegistry(_ previous: SkillRegistryState?, fallback: String)
    -> SkillRegistryState
  {
    if case .ready(let items, let total, let truncated, _) = previous {
      return .ready(items: items, total: total, truncated: truncated, stale: true)
    }
    return .unavailable(fallback)
  }

  /// The exact AskUser interaction when its id is known (and the agent supports by-id reads),
  /// otherwise the conversation's single pending ask. `nil` means none is available.
  public func askSnapshot(threadID: String, interactionID: String?) async throws
    -> ChannelAskSnapshot?
  {
    guard started, !backgrounded else { throw AskAnswerError.notReady }
    let byID =
      interactionID != nil
      && conversations[threadID].flatMap { state in
        agents.first { $0.sourceId == state.thread.sourceId }?.supportsAskById
      } != false
    if let interactionID, byID {
      return try await api.askById(id: threadID, interactionId: interactionID, etag: nil)
        .valueRequired().ask
    }
    let pending = try await api.ask(id: threadID, etag: nil).valueRequired().ask
    if let interactionID, let pending, pending.interactionId != interactionID { return nil }
    return pending
  }

  /// Submits AskUser answers through `POST /threads/:id/ask` (web `api.submitAsk`).
  public func answerAsk(
    threadID: String, interactionID: String, answers: [ChannelAskAnswer]
  ) async throws -> ChannelAskSnapshot? {
    guard started, !backgrounded, connection == .live else { throw AskAnswerError.notReady }
    let result = try await api.answerAsk(
      id: threadID, body: .init(interactionId: interactionID, answers: answers))
    guard result.accepted else {
      throw result.code == "invalid_answer"
        ? AskAnswerError.incomplete : AskAnswerError.inactive(result.code)
    }
    return result.snapshot
  }

  /// Per-conversation model/effort override (web `patchThreadOverride`): optimistic, written
  /// through the thread-write queue so a following submission settles after it, and reverted
  /// with a visible error when the server refuses it. Empty strings mean "agent default".
  public func setRunOverride(threadID: String, model: String?, effort: String?) {
    guard let state = conversations[threadID] else { return }
    let previous = state.record.thread
    var next = previous
    if let model { next.runModel = model.isEmpty ? nil : model }
    if let effort { next.runEffort = effort.isEmpty ? nil : effort }
    state.record.thread = next
    state.thread = next
    let body = ApiPatchThread(
      model: model.map { $0.isEmpty ? .null : .value($0) } ?? .omitted,
      effort: effort.map { $0.isEmpty ? .null : .value($0) } ?? .omitted)
    let api = api
    let generation = epoch
    enqueueThreadWrite(threadID: threadID) { [weak self] in
      do {
        let value = try await api.patchThread(id: threadID, body: body)
        await self?.adoptOverride(value.thread, generation: generation)
      } catch {
        await self?.revertOverride(threadID, to: previous, generation: generation)
        throw error
      }
    }
  }
  func adoptOverride(_ thread: WebThread, generation: UInt64) {
    guard epoch == generation else { return }
    patchSummary(thread)
    scheduleCache()
  }
  func revertOverride(_ threadID: String, to thread: WebThread, generation: UInt64) {
    guard epoch == generation, let state = conversations[threadID] else { return }
    state.record.thread.runModel = thread.runModel
    state.record.thread.runEffort = thread.runEffort
    state.thread = state.record.thread
    errorMessage = "The model or effort change was not saved. The previous setting is restored."
  }
}
