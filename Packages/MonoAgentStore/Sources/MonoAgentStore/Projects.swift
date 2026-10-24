// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum OrganizeError: LocalizedError, Sendable {
  case unavailable, invalid, failed
  public var errorDescription: String? {
    switch self {
    case .unavailable: "Changes are unavailable. Reconnect and try again."
    case .invalid: "Check the name and try again."
    case .failed: "The change was not confirmed. Refresh before retrying."
    }
  }
}

public struct ProjectMembers: Sendable {
  public var threads: [WebThread] = []
  public var nextCursor: String?
  public var loading = false
  public var failed = false
  public init() {}
}

public struct ProjectConfirmation: Sendable, Identifiable {
  public let id: UUID
  public let projectID: String
  public let archive: Bool
  let epoch: UInt64
  let selection: UInt64
  public var message: String {
    archive
      ? "Archive this project? Its conversations stay, keep their context, and leave the Projects list."
      : "Delete this project? Its conversations move back to the agent. This cannot be undone."
  }
}

extension ConsoleStore {
  static func validOrganizeName(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
      && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
  func requireOrganize() throws {
    guard canOrganize else { throw OrganizeError.unavailable }
  }
  func checkOrganizeResponse(epoch generation: UInt64, selection selected: UInt64) throws {
    guard canOrganize, epoch == generation, selection == selected, !Task.isCancelled else {
      throw CancellationError()
    }
  }

  public func createProject(sourceID: String, name: String, color: String, context: String)
    async throws
    -> WebProject
  {
    try requireOrganize()
    guard Self.validOrganizeName(name), context.count <= 4000 else { throw OrganizeError.invalid }
    let generation = epoch
    let selected = selection
    do {
      let value = try await api.createProject(
        body: .init(
          sourceId: sourceID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          color: color, context: context)
      ).project
      try checkOrganizeResponse(epoch: generation, selection: selected)
      adoptProject(value)
      return value
    } catch { try organizeFailure(error, generation: generation, selected: selected) }
  }

  public func updateProject(id: String, name: String, color: String, context: String) async throws {
    try requireOrganize()
    guard Self.validOrganizeName(name), context.count <= 4000 else { throw OrganizeError.invalid }
    let generation = epoch
    let selected = selection
    do {
      let value = try await api.patchProject(
        id: id,
        body: .init(
          color: color, name: name.trimmingCharacters(in: .whitespacesAndNewlines), context: context
        )
      ).project
      try checkOrganizeResponse(epoch: generation, selection: selected)
      adoptProject(value)
    } catch { try organizeFailure(error, generation: generation, selected: selected) }
  }

  func organizeFailure(_ error: any Error, generation: UInt64, selected: UInt64) throws -> Never {
    try checkOrganizeResponse(epoch: generation, selection: selected)
    if error is CancellationError { throw error }
    errorMessage = OrganizeError.failed.localizedDescription
    throw OrganizeError.failed
  }

  func adoptProject(_ value: WebProject) {
    observation &+= 1
    if let index = projects.firstIndex(where: { $0.id == value.id }) {
      if projects[index].revision <= value.revision { projects[index] = value }
    } else {
      projects.append(value)
    }
    errorMessage = nil
    scheduleCache()
  }

  public func requestProjectConfirmation(id: String, archive: Bool = false) {
    guard canOrganize, projects.contains(where: { $0.id == id }) else { return }
    projectConfirmation = .init(
      id: UUID(), projectID: id, archive: archive, epoch: epoch, selection: selection)
  }
  public func cancelProjectConfirmation() { projectConfirmation = nil }

  public func confirmProjectAction(_ id: UUID) async throws {
    guard let request = projectConfirmation, request.id == id else { throw CancellationError() }
    projectConfirmation = nil
    try checkOrganizeResponse(epoch: request.epoch, selection: request.selection)
    do {
      if request.archive {
        let value = try await api.patchProject(id: request.projectID, body: .init(archived: true))
          .project
        try checkOrganizeResponse(epoch: request.epoch, selection: request.selection)
        adoptProject(value)
      } else {
        try await api.deleteProject(id: request.projectID)
        try checkOrganizeResponse(epoch: request.epoch, selection: request.selection)
        observation &+= 1
        projects.removeAll { $0.id == request.projectID }
        projectMembers[request.projectID] = nil
        // SSE also carries detachments. Clear membership locally without altering revision/run data.
        mutateOrganizeRows { row in
          if row.projectId == request.projectID {
            row.projectId = nil
            row.projectName = nil
          }
        }
        errorMessage = nil
        scheduleCache()
      }
    } catch { try organizeFailure(error, generation: request.epoch, selected: request.selection) }
  }

  public func setConversationProject(threadID: String, projectID: String?) {
    if let projectID {
      guard let thread = conversations[threadID]?.thread,
        projects.contains(where: {
          $0.id == projectID && $0.sourceId == thread.sourceId && $0.archivedAt == nil
        })
      else { return }
    }
    queueConversationPatch(
      threadID: threadID, body: .init(projectId: projectID.map(InputField.value) ?? .null))
  }

  public func assignConversationProject(threadID: String, projectID: String) async throws {
    try requireOrganize()
    guard pendingConversationActions[threadID] == nil, let held = conversations[threadID],
      projects.contains(where: {
        $0.id == projectID && $0.sourceId == held.thread.sourceId && $0.archivedAt == nil
      })
    else { throw OrganizeError.unavailable }
    let generation = epoch
    let selected = selection
    setConversationProject(threadID: threadID, projectID: projectID)
    try await settleThreadWrites(threadID)
    try checkOrganizeResponse(epoch: generation, selection: selected)
  }

  func mutateOrganizeRows(_ mutation: (inout WebThread) -> Void) {
    for state in conversations.values {
      mutation(&state.record.thread)
      state.thread = state.record.thread
    }
    for key in buckets.keys {
      guard var bucket = buckets[key] else { continue }
      for index in bucket.threads.indices { mutation(&bucket.threads[index]) }
      buckets[key] = bucket
    }
    if var fleet = activeFleet {
      for index in fleet.threads.indices { mutation(&fleet.threads[index]) }
      activeFleet = fleet
    }
    if var value = bootstrap {
      for index in value.threads.indices { mutation(&value.threads[index]) }
      bootstrap = value
    }
    for id in projectMembers.keys {
      guard var page = projectMembers[id] else { continue }
      for index in page.threads.indices { mutation(&page.threads[index]) }
      projectMembers[id] = page
    }
  }

  /// Lists actual server members, not just the currently paged dashboard bucket.
  public func loadProjectMembers(id: String, older: Bool = false) async {
    guard let project = projects.first(where: { $0.id == id }) else { return }
    var page = projectMembers[id] ?? ProjectMembers()
    if page.threads.isEmpty {
      page.threads = buckets.values.flatMap(\.threads).filter {
        $0.projectId == id && $0.archivedAt == nil
      }
      .reduce(into: [WebThread]()) { rows, row in
        if !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
      }
    }
    guard canOrganize, !page.loading, !older || page.nextCursor != nil else {
      projectMembers[id] = page
      return
    }
    let generation = epoch
    let selected = selection
    let began = observation
    let token = UUID()
    projectMemberRequests[id] = token
    page.loading = true
    page.failed = false
    projectMembers[id] = page
    do {
      let result = try await api.threads(
        query: .init(
          sourceId: project.sourceId, limit: 50, before: older ? page.nextCursor : nil,
          projectId: id), etag: nil
      ).valueRequired()
      try checkOrganizeResponse(epoch: generation, selection: selected)
      guard projectMemberRequests[id] == token else { return }
      guard observation == began else {
        projectMembers[id]?.loading = false
        projectMemberRequests[id] = nil
        return
      }
      let rows = result.threads.filter { $0.projectId == id && tombstones[$0.id] == nil }
      page.threads =
        older ? page.threads.filter { old in !rows.contains { $0.id == old.id } } + rows : rows
      page.nextCursor = result.nextCursor
      page.loading = false
      projectMembers[id] = page
    } catch {
      guard projectMemberRequests[id] == token else { return }
      projectMembers[id]?.loading = false
      if epoch == generation, selection == selected, !(error is CancellationError) {
        projectMembers[id]?.failed = true
      }
    }
    if projectMemberRequests[id] == token { projectMemberRequests[id] = nil }
  }
}
