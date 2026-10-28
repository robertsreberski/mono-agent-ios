// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public enum CronAction: Sendable, Equatable {
  case run
  case enabled(Bool)
}
public struct CronConfirmation: Sendable {
  public let action: CronAction
  public let idempotencyKey: String
  public let challenge: WebCronConfirmation
}
@MainActor @Observable public final class CronJobState {
  public let jobID: String
  public let threadID: String
  public internal(set) var busy = false
  public internal(set) var error: String?
  public internal(set) var notice: String?
  public internal(set) var confirmation: CronConfirmation?
  public internal(set) var config: WebChannelConfigView?
  public internal(set) var configOpen = false
  @ObservationIgnored var lifetime = UUID()
  @ObservationIgnored var task: Task<Void, Never>?
  init(jobID: String, threadID: String) {
    self.jobID = jobID
    self.threadID = threadID
  }
}
extension ConsoleStore {
  @discardableResult public func openCronJob(sourceID: String, jobID: String, threadID: String)
    -> CronJobState
  {
    let state = automationState(sourceID)
    if let job = state.job, job.jobID == jobID, job.threadID == threadID { return job }
    for previous in automations.values { closeCronJob(sourceID: previous.sourceID) }
    let job = CronJobState(jobID: jobID, threadID: threadID)
    state.job = job
    return job
  }
  public func closeCronJob(sourceID: String) {
    resetCronJob(sourceID: sourceID)
    automations[sourceID]?.job = nil
  }
  func resetCronJob(sourceID: String) {
    guard let job = automations[sourceID]?.job else { return }
    job.lifetime = UUID()
    job.confirmation = nil
    job.config = nil
    job.configOpen = false
    // Cancellation is not proof a POST was not admitted. No automatic retry.
    job.task?.cancel()
    job.error = nil
    job.notice = nil
  }
  private func cronJobCurrent(_ sourceID: String, _ job: CronJobState) -> Bool {
    automations[sourceID]?.job === job && selectedBucket?.sourceID == sourceID
      && selectedThreadID == job.threadID && cronReadable(sourceID)
  }
  public func cronActionUnavailableReason(sourceID: String, jobID: String, threadID: String)
    -> String?
  {
    let state = automations[sourceID]
    if !cronReadable(sourceID) { return "Cron controls require a live, readable agent." }
    if let reason = state?.overview?.degradedReason {
      return ProviderPresentation.boundedText(reason)
    }
    if !automationIsAuthoritative(sourceID) {
      return "Cron controls require current authoritative job state."
    }
    guard let row = automationJob(sourceID: sourceID, jobID: jobID), row.threadId == threadID else {
      return "Cron job identity is unavailable."
    }
    if !row.configured { return "This historical job is no longer configured." }
    if state?.overview?.actionsEnabled != true {
      return "Cron operator actions are disabled by agent configuration."
    }
    if agent(sourceID)?.cron?.actions != true { return "Cron actions require an operator API key." }
    return nil
  }
  public func cancelCronConfirmation(sourceID: String) {
    guard let job = automations[sourceID]?.job, !job.busy else { return }
    job.confirmation = nil
  }
  public func performCronAction(sourceID: String, action: CronAction) {
    guard let job = automations[sourceID]?.job, !job.busy, job.confirmation == nil else { return }
    dispatchCronAction(
      sourceID: sourceID, job: job, action: action,
      key: UUID().uuidString, confirmation: nil)
  }
  public func confirmCronAction(sourceID: String) async {
    guard let job = automations[sourceID]?.job, !job.busy, let pending = job.confirmation else {
      return
    }
    let now = await serverNow()
    guard automations[sourceID]?.job === job, !job.busy,
      job.confirmation?.idempotencyKey == pending.idempotencyKey,
      job.confirmation?.challenge.token == pending.challenge.token
    else { return }
    guard let expires = ServerTimestamp.date(pending.challenge.expiresAt), expires > now
    else {
      job.confirmation = nil
      job.error = "Confirmation expired. Start the action again."
      return
    }
    dispatchCronAction(
      sourceID: sourceID, job: job, action: pending.action,
      key: pending.idempotencyKey, confirmation: pending.challenge.token)
  }
  private func dispatchCronAction(
    sourceID: String, job: CronJobState, action: CronAction,
    key: String, confirmation: String?
  ) {
    guard !automationState(sourceID).pendingJobs.contains(job.jobID), cronJobCurrent(sourceID, job),
      cronActionUnavailableReason(sourceID: sourceID, jobID: job.jobID, threadID: job.threadID)
        == nil
    else { return }
    let scope = cronScope(sourceID)
    let epoch = epoch
    let lifetime = job.lifetime
    let revision = automationState(sourceID).revision
    let effective = automationJob(sourceID: sourceID, jobID: job.jobID)?.effectiveEnabled
    if case .enabled(let value) = action, value == effective { return }
    automationState(sourceID).pendingJobs.insert(job.jobID)
    job.busy = true
    job.error = nil
    job.notice = nil
    job.task = Task { [weak self] in
      guard let self else { return }
      defer {
        self.automations[sourceID]?.pendingJobs.remove(job.jobID)
        job.busy = false
        job.task = nil
      }
      @MainActor func current() -> Bool {
        self.epoch == epoch && job.lifetime == lifetime && self.cronJobCurrent(sourceID, job)
          && self.cronScope(sourceID) == scope && !Task.isCancelled
      }
      guard current(),
        self.cronActionUnavailableReason(
          sourceID: sourceID,
          jobID: job.jobID, threadID: job.threadID) == nil,
        self.automationJob(sourceID: sourceID, jobID: job.jobID)?.effectiveEnabled == effective
      else { return }
      do {
        let challenge: WebCronConfirmation?
        let replayed: Bool
        switch action {
        case .run:
          let result = try await self.api.runCron(
            id: sourceID, jobId: job.jobID,
            body: .init(idempotencyKey: key, confirmationToken: confirmation))
          switch result {
          case .confirmationRequired(let value):
            challenge = value
            replayed = false
          case .completed(let value, let duplicate):
            guard value.run.jobId == job.jobID else {
              throw APIError(status: 502, code: "unexpected_cron_job")
            }
            challenge = nil
            replayed = duplicate
          }
        case .enabled(let enabled):
          let result = try await self.api.enableCron(
            id: sourceID, jobId: job.jobID,
            body: .init(idempotencyKey: key, confirmationToken: confirmation, enabled: enabled))
          switch result {
          case .confirmationRequired(let value):
            challenge = value
            replayed = false
          case .completed(let value, let duplicate):
            guard value.job.jobId == job.jobID, value.job.threadId == job.threadID else {
              throw APIError(status: 502, code: "unexpected_cron_job")
            }
            challenge = nil
            replayed = duplicate
          }
        }
        let publish = current() && self.automations[sourceID]?.revision == revision
        self.cronOutcome(sourceID)
        guard publish else { return }
        if let challenge {
          job.confirmation = .init(action: action, idempotencyKey: key, challenge: challenge)
        } else {
          job.notice = replayed ? "Cron action was already applied." : "Cron action applied."
        }
      } catch {
        let publish = current()
        self.cronOutcome(sourceID)
        guard publish else { return }
        job.error =
          (error as? APIError)?.safeDetails
          ?? "Cron action failed. Check the job before trying again."
      }
    }
  }
  public func openCronConfig(sourceID: String) {
    guard let job = automations[sourceID]?.job, !job.busy, job.confirmation == nil,
      cronJobCurrent(sourceID, job), !automationState(sourceID).pendingJobs.contains(job.jobID)
    else { return }
    let epoch = epoch
    let scope = cronScope(sourceID)
    let lifetime = job.lifetime
    automationState(sourceID).pendingJobs.insert(job.jobID)
    job.busy = true
    job.error = nil
    job.task = Task { [weak self] in
      guard let self else { return }
      defer {
        self.automations[sourceID]?.pendingJobs.remove(job.jobID)
        job.busy = false
        job.task = nil
      }
      @MainActor func current() -> Bool {
        self.epoch == epoch && job.lifetime == lifetime && self.cronJobCurrent(sourceID, job)
          && self.cronScope(sourceID) == scope && !Task.isCancelled
      }
      guard current() else { return }
      do {
        var value = try await self.api.cronConfig(id: sourceID, etag: nil).valueRequired()
          .configView
        guard current() else { return }
        // Fail closed even if an upstream redacted field unexpectedly carries a value.
        for index in value.fields.indices where value.fields[index].redacted == true {
          value.fields[index].value = "••••••••"
        }
        job.config = value
        job.configOpen = true
      } catch {
        guard current() else { return }
        job.error = (error as? APIError)?.safeDetails ?? "Cron configuration is unavailable."
      }
    }
  }
  public func closeCronConfig(sourceID: String) {
    automations[sourceID]?.job?.configOpen = false
    automations[sourceID]?.job?.config = nil
  }
}
