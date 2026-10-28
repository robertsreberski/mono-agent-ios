// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

@MainActor @Observable public final class CronRunsState {
  public internal(set) var runs: [WebCronRunSummary] = []
  public internal(set) var nextCursor: String?
  public internal(set) var loaded = false
  public internal(set) var loading = false
  public internal(set) var error: String?
  public internal(set) var details: [String: WebMessage] = [:]
  public internal(set) var loadingDetails: Set<String> = []
  @ObservationIgnored var pageTask: Task<Void, Never>?
  @ObservationIgnored var detailTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var cursors: Set<String> = []
}

extension ConsoleStore {
  func cronConversationCurrent(sourceID: String, job: CronJobState, conversation: ConversationState)
    -> Bool
  {
    cronReplyRecovery.isAvailable(namespace) && cronReadable(sourceID)
      && automations[sourceID]?.scope == cronScope(sourceID)
      && automations[sourceID]?.job === job && selectedBucket?.sourceID == sourceID
      && selectedThreadID == job.threadID && conversations[job.threadID] === conversation
      && conversation.thread.sourceId == sourceID && tombstones[job.threadID] == nil
      && automationJob(sourceID: sourceID, jobID: job.jobID)?.threadId == job.threadID
  }
  public func loadCronRuns(sourceID: String, older: Bool = false) async {
    guard let owner = automations[sourceID], let job = owner.job,
      let conversation = conversations[job.threadID],
      cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation)
    else { return }
    let state = job.runs
    if let flight = state.pageTask {
      await flight.value
      return
    }
    guard !older || state.nextCursor != nil else { return }
    let cursor = older ? state.nextCursor : nil
    let epoch = epoch
    let scope = cronScope(sourceID)
    let lifetime = job.lifetime
    let revision = owner.revision
    let selected = selection
    state.loading = true
    state.error = nil
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        state.loading = false
        state.pageTask = nil
      }
      @MainActor func current() -> Bool {
        self.epoch == epoch && self.selection == selected && owner.revision == revision
          && job.lifetime == lifetime && self.cronScope(sourceID) == scope && !Task.isCancelled
          && self.cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation)
      }
      guard current() else { return }
      do {
        let page = try await self.api.cronRuns(
          id: sourceID, jobId: job.jobID, query: .init(limit: 30, before: cursor), etag: nil
        ).valueRequired()
        guard current() else { return }
        guard page.runs.allSatisfy({ $0.jobId == job.jobID }),
          (page.messages ?? []).allSatisfy({ $0.threadId == job.threadID })
        else { throw APIError(status: 502, code: "unexpected_cron_page") }
        var merged = Dictionary(state.runs.map { ($0.runId, $0) }, uniquingKeysWith: { a, _ in a })
        for run in page.runs { merged[run.runId] = run }
        state.runs = merged.values.sorted {
          $0.sequence == $1.sequence ? $0.runId > $1.runId : $0.sequence > $1.sequence
        }
        // A repeated cursor is not a promise of more history.
        if let cursor { state.cursors.insert(cursor) }
        if older || !state.loaded {
          state.nextCursor = page.nextCursor.flatMap { state.cursors.contains($0) ? nil : $0 }
        }
        state.loaded = true
        self.mergeCronMessages(page.messages ?? [], conversation: conversation, replace: false)
      } catch {
        guard current() else { return }
        state.error = (error as? APIError)?.safeDetails ?? "Couldn't load cron runs."
      }
    }
    state.pageTask = task
    await task.value
  }
  public func loadCronRunActivity(sourceID: String, runID: String) async {
    guard let owner = automations[sourceID], let job = owner.job,
      let conversation = conversations[job.threadID],
      cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation),
      cronRunStatus(job: job, conversation: conversation, runID: runID) != nil
    else { return }
    let state = job.runs
    if let task = state.detailTasks[runID] {
      await task.value
      return
    }
    let epoch = epoch
    let scope = cronScope(sourceID)
    let lifetime = job.lifetime
    let revision = owner.revision
    let selected = selection
    state.loadingDetails.insert(runID)
    state.error = nil
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        state.loadingDetails.remove(runID)
        state.detailTasks[runID] = nil
      }
      @MainActor func current() -> Bool {
        self.epoch == epoch && self.selection == selected && owner.revision == revision
          && job.lifetime == lifetime && self.cronScope(sourceID) == scope && !Task.isCancelled
          && self.cronConversationCurrent(sourceID: sourceID, job: job, conversation: conversation)
      }
      guard current() else { return }
      do {
        let message = try await self.api.cronRun(
          id: sourceID, jobId: job.jobID, runId: runID, etag: nil
        ).valueRequired().message
        guard current() else { return }
        guard message.threadId == job.threadID, Self.cronRunID(message) == runID else {
          throw APIError(status: 502, code: "unexpected_cron_run")
        }
        if let held = conversation.messageStates[message.id]?.message,
          (held.seq ?? 0) > (message.seq ?? 0)
        {
          return
        }
        state.details[runID] = message
        self.mergeCronMessages([message], conversation: conversation, replace: true)
      } catch {
        guard current() else { return }
        if let error = error as? APIError, error.status == 404, error.code == "cron_run_not_visible"
        {
          state.runs.removeAll { $0.runId == runID }
          state.details[runID] = nil
          conversation.record.messages.removeAll { Self.cronRunID($0) == runID }
          conversation.publish()
          self.scheduleCache()
        } else {
          state.error = (error as? APIError)?.safeDetails ?? "Couldn't load run activity."
        }
      }
    }
    state.detailTasks[runID] = task
    await task.value
  }
  static func cronRunID(_ message: WebMessage) -> String? {
    for part in message.parts {
      if case .telemetry(let value) = part, value.event == "cron_run",
        case .object(let fields) = value.data, case .string(let id) = fields["runId"]
      {
        return id
      }
    }
    return nil
  }
  func cronRunStatus(job: CronJobState, conversation: ConversationState, runID: String) -> String? {
    if let run = job.runs.runs.first(where: { $0.runId == runID }) { return run.status }
    for message in conversation.messages where Self.cronRunID(message) == runID {
      for part in message.parts {
        if case .telemetry(let value) = part, value.event == "cron_run",
          case .object(let fields) = value.data, case .string(let status) = fields["status"]
        {
          return status
        }
      }
    }
    return nil
  }
  private func mergeCronMessages(
    _ messages: [WebMessage], conversation: ConversationState, replace: Bool
  ) {
    for message in messages {
      if let index = conversation.record.messages.firstIndex(where: { $0.id == message.id }) {
        let held = conversation.record.messages[index]
        if (message.seq ?? 0) > (held.seq ?? 0) || (replace && message.seq == held.seq) {
          conversation.record.messages[index] = message
        }
      } else {
        conversation.record.messages.append(message)
      }
    }
    conversation.record.messages = ProcessJobEvents.orderedMessages(conversation.record.messages)
    conversation.publish()
    scheduleCache()
  }
}
