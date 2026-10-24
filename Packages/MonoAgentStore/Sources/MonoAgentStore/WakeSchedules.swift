// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public enum WakeAction: String, Sendable { case save, pause, resume, delete }
public struct WakeEditorState: Sendable, Identifiable {
  public let id: UUID
  public let threadID: String
  public var draft: WakeDraft
  public var schedule: WebWakeSchedule?
  public var loaded = false
  public var busy: WakeAction?
  public var failure: WakeFailure?
  public var changedElsewhere = false
  public var deletionConfirmation: UUID?
  let epoch: UInt64
  let selection: UInt64
  var read = UUID()
  var mutation = UUID()
  var refreshAfterMutation = false
  public var dirty: Bool { WakeScheduleModel.isDirty(draft, baseline: schedule?.definition) }
}

extension ConsoleStore {
  @discardableResult public func openWakeEditor(threadID: String, now: Date = Date()) -> UUID? {
    guard canOrganize, let thread = conversations[threadID]?.thread, thread.trigger == nil else {
      return nil
    }
    let id = UUID()
    wakeEditor = .init(
      id: id, threadID: threadID, draft: WakeScheduleModel.newDraft(now: now), epoch: epoch,
      selection: selection)
    return id
  }
  public func closeWakeEditor(_ id: UUID) { if wakeEditor?.id == id { wakeEditor = nil } }
  private func currentWake(_ id: UUID) -> WakeEditorState? {
    guard let state = wakeEditor, state.id == id, state.epoch == epoch,
      state.selection == selection, canOrganize,
      conversations[state.threadID]?.thread.trigger == nil, tombstones[state.threadID] == nil
    else { return nil }
    return state
  }
  public func editWakeDraft(_ id: UUID, draft: WakeDraft) {
    guard currentWake(id)?.busy == nil, currentWake(id)?.loaded == true else { return }
    wakeEditor?.draft = draft
  }
  public func refreshWakeEditor(_ id: UUID, explicit: Bool = false) async {
    guard let initial = currentWake(id) else { return }
    if initial.busy != nil {
      wakeEditor?.refreshAfterMutation = true
      return
    }
    let knownSummary = conversations[initial.threadID]?.thread.wakeSchedule
    let token = UUID()
    wakeEditor?.read = token
    do {
      let value = try await api.wakeSchedule(id: initial.threadID, etag: nil).valueRequired()
        .schedule
      guard let state = currentWake(id), state.read == token, !Task.isCancelled else { return }
      guard state.mutation == initial.mutation, state.busy == nil else {
        deferWakeRefresh(id)
        return
      }
      if conversations[initial.threadID]?.thread.wakeSchedule != knownSummary {
        deferWakeRefresh(id)
        return
      }
      if state.loaded && !explicit
        && ((state.schedule != nil && state.dirty) || (state.schedule == nil && value != nil))
      {
        if value?.revision != state.schedule?.revision
          || value?.scheduleId != state.schedule?.scheduleId
        {
          wakeEditor?.changedElsewhere = true
        }
        return
      }
      adoptWakeSummary(threadID: initial.threadID, value: value)
      scheduleCache()
      wakeEditor?.schedule = value
      if let value { wakeEditor?.draft = WakeScheduleModel.draft(from: value.definition) }
      wakeEditor?.loaded = true
      wakeEditor?.failure = nil
      wakeEditor?.changedElsewhere = false
    } catch {
      guard let state = currentWake(id), state.read == token, !Task.isCancelled else { return }
      guard state.mutation == initial.mutation, state.busy == nil else {
        deferWakeRefresh(id)
        return
      }
      var failure = WakeScheduleModel.failure(error)
      failure.message =
        (state.loaded ? "Couldn't load the latest version. " : "Couldn't load this schedule. ")
        + failure.message
      failure.conflict = explicit
      wakeEditor?.failure = failure
    }
  }
  private func deferWakeRefresh(_ id: UUID) {
    guard let state = currentWake(id) else { return }
    if state.busy != nil {
      wakeEditor?.refreshAfterMutation = true
    } else {
      Task { await self.refreshWakeEditor(id) }
    }
  }
  public func requestWakeDeletion(_ id: UUID) {
    guard let state = currentWake(id), state.loaded, state.schedule != nil, state.busy == nil else {
      return
    }
    wakeEditor?.deletionConfirmation = UUID()
  }
  public func cancelWakeDeletion(_ id: UUID) {
    guard wakeEditor?.id == id else { return }
    wakeEditor?.deletionConfirmation = nil
  }
  public func confirmWakeDeletion(_ id: UUID, confirmation: UUID) {
    guard currentWake(id)?.deletionConfirmation == confirmation else { return }
    wakeEditor?.deletionConfirmation = nil
    mutateWakeEditor(id, action: .delete, confirmedDelete: true)
  }
  public func mutateWakeEditor(_ id: UUID, action: WakeAction) {
    mutateWakeEditor(id, action: action, confirmedDelete: false)
  }
  private func mutateWakeEditor(_ id: UUID, action: WakeAction, confirmedDelete: Bool) {
    guard let state = currentWake(id), state.loaded, state.busy == nil,
      let thread = conversations[state.threadID]?.thread
    else { return }
    if action == .delete && !confirmedDelete { return }
    if action == .save {
      guard thread.archivedAt == nil, state.dirty,
        !WakeScheduleModel.validate(state.draft).hasIssues
      else { return }
    } else if action != .delete {
      guard let schedule = state.schedule, !state.dirty,
        action == .pause || thread.archivedAt == nil
      else { return }
      if action == .resume && WakeScheduleModel.onceHasElapsed(schedule.definition) {
        wakeEditor?.failure = .init(
          message:
            "This one-off's time has passed. Pick a future date and time, then save to schedule it again."
        )
        return
      }
    }
    wakeEditor?.busy = action
    wakeEditor?.failure = nil
    wakeEditor?.mutation = UUID()
    enqueueThreadWrite(
      threadID: state.threadID,
      onFinish: { [weak self] outcome in
        guard let self, self.currentWake(id) != nil else { return }
        self.wakeEditor?.busy = nil
        if outcome != .success && self.wakeEditor?.failure == nil {
          self.wakeEditor?.failure = .init(
            message:
              "The change was interrupted or timed out. Load the latest version before retrying.",
            conflict: true)
        }
        if self.wakeEditor?.refreshAfterMutation == true {
          self.wakeEditor?.refreshAfterMutation = false
          Task { await self.refreshWakeEditor(id) }
        }
      }, operation: { [weak self] in try await self?.performWakeMutation(id, action: action) })
  }
  private func adoptWakeSummary(threadID: String, value: WebWakeSchedule?) {
    let summary = value.map {
      WakeSummary(
        state: $0.state, revision: $0.revision, nextFireAt: $0.nextFireAt, kind: $0.definition.kind,
        compactFirst: $0.definition.compactFirst)
    }
    mutateOrganizeRows { if $0.id == threadID { $0.wakeSchedule = summary } }
  }

  private func performWakeMutation(_ id: UUID, action: WakeAction) async throws {
    guard let state = currentWake(id), state.busy == action else { throw CancellationError() }
    if action == .save || action == .resume {
      guard conversations[state.threadID]?.thread.archivedAt == nil else {
        throw OrganizeError.unavailable
      }
    }
    let knownSummary = conversations[state.threadID]?.thread.wakeSchedule
    do {
      let result: WebWakeSchedule?
      if action == .delete {
        guard let schedule = state.schedule else { throw CancellationError() }
        try await api.deleteWake(
          id: state.threadID, body: .init(expectedRevision: schedule.revision))
        result = nil
      } else if action == .pause || action == .resume {
        guard let schedule = state.schedule else { throw CancellationError() }
        result = try await api.patchWake(
          id: state.threadID,
          body: .init(
            expectedRevision: schedule.revision, state: action == .pause ? "paused" : "active")
        ).schedule
      } else {
        let definition = WakeScheduleModel.definition(from: state.draft)
        if let schedule = state.schedule {
          result = try await api.putWake(
            id: state.threadID,
            body: .init(expectedRevision: schedule.revision, definition: definition)
          ).schedule
        } else {
          result = try await api.createWake(id: state.threadID, body: definition).schedule
        }
      }
      guard currentWake(id) != nil, !Task.isCancelled else { throw CancellationError() }
      observation &+= 1
      if conversations[state.threadID]?.thread.wakeSchedule == knownSummary {
        adoptWakeSummary(threadID: state.threadID, value: result)
      } else {
        wakeEditor?.refreshAfterMutation = true
      }
      scheduleCache()
      errorMessage = nil
      if action == .save || action == .delete {
        wakeEditor = nil
      } else {
        wakeEditor?.schedule = result
      }
    } catch {
      if currentWake(id) != nil, !Task.isCancelled, !(error is CancellationError) {
        wakeEditor?.failure = WakeScheduleModel.failure(error)
      }
      throw error
    }
  }
}
