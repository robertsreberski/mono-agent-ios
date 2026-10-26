// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

/// An unsaved new-conversation run-defaults choice for one agent (web `settings-drafts.ts`).
/// Memory only. `""` means "use the agent config"; `context1M == nil` is no explicit 1M choice.
public struct RunDefaultsDraft: Sendable, Equatable {
  public var model: String
  public var effort: String
  public var context1M: Bool?
  public init(model: String = "", effort: String = "", context1M: Bool? = nil) {
    self.model = model
    self.effort = effort
    self.context1M = context1M
  }
  /// The saved console override in the draft's shape; no override is the agent config.
  public init(saved override: RunConfiguration?) {
    self.init(
      model: override?.model ?? "", effort: override?.effort ?? "", context1M: override?.context1M)
  }
  /// Saving this draft removes the console override (DELETE) instead of writing one (PUT).
  public var usesAgentConfig: Bool { model.isEmpty && effort.isEmpty && context1M == nil }
}

/// The web settings page's targets (`data-settings-target`). `nil` is the page title.
public enum AgentSettingsSection: String, Sendable, CaseIterable, Hashable {
  case newConversations = "new-conversations"
  case providers
  case agent
}

/// Explicit opening or a changed intent may move focus and scroll; nothing else does.
public struct AgentSettingsTarget: Sendable, Equatable, Hashable {
  public var section: AgentSettingsSection?
  public var intent: Int
  public init(section: AgentSettingsSection? = nil, intent: Int = 0) {
    self.section = section
    self.intent = intent
  }
}

/// Per-agent settings state. Pin and run-defaults writes share one ordered lane per agent.
@MainActor @Observable public final class AgentSettingsState {
  public let sourceID: String
  public internal(set) var draft: RunDefaultsDraft?
  public internal(set) var saving = false
  public internal(set) var saveError: String?
  /// The latest confirmation, with a serial so an identical repeat is announced again.
  public internal(set) var notice: String?
  public internal(set) var noticeSerial = 0
  public internal(set) var requestedPin: Bool?
  public internal(set) var pinPending = false
  public internal(set) var pinError: String?
  @ObservationIgnored var draftVersion: UInt64 = 0
  init(sourceID: String) { self.sourceID = sourceID }
}

/// Confirmed agent fields that an older in-flight bootstrap read must not undo. Each field has
/// its own confirmation clock: a later pin must not re-assert older run settings.
struct AgentWrite {
  /// `.some(nil)` is a confirmed unpinned/absent value; `nil` means pin was not written.
  var pinned: Bool??
  var pinnedClock: UInt64 = 0
  var runSettings: WebAgentRunSettings?
  var runSettingsClock: UInt64 = 0
}

extension ConsoleStore {
  /// Lane key for one agent's ordered pin/defaults writes; never collides with a thread ID.
  static func agentLane(_ sourceID: String) -> String { "\u{0}agent\u{0}" + sourceID }

  public func agentSettingsState(_ sourceID: String) -> AgentSettingsState {
    if let state = agentSettings[sourceID] { return state }
    if agentSettings.count >= 64,
      let key = agentSettings.first(where: {
        $0.value.draft == nil && !$0.value.saving && !$0.value.pinPending
      })?.key
    {
      agentSettings[key] = nil
    }
    let state = AgentSettingsState(sourceID: sourceID)
    agentSettings[sourceID] = state
    return state
  }

  public func agent(_ sourceID: String) -> WebAgentSummary? {
    agents.first { $0.sourceId == sourceID }
  }

  /// The saved console override for `sourceID`, in the draft's shape.
  public func savedRunDefaults(_ sourceID: String) -> RunDefaultsDraft {
    RunDefaultsDraft(saved: agent(sourceID)?.runSettings.override)
  }

  /// Web header dot: a draft whose model or effort differs from the saved override.
  public func hasUnsavedRunDefaults(_ sourceID: String) -> Bool {
    // Reading through the state object registers observation even before the first draft.
    guard let draft = agentSettingsState(sourceID).draft else { return false }
    let saved = savedRunDefaults(sourceID)
    return draft.model != saved.model || draft.effort != saved.effort
  }

  /// Web section `dirty`: any difference from the saved override, including the 1M choice.
  public func runDefaultsDirty(_ sourceID: String) -> Bool {
    guard let draft = agentSettingsState(sourceID).draft else { return false }
    return draft != savedRunDefaults(sourceID)
  }

  /// Edits never write. An identical edit is not a new draft version.
  public func editRunDefaults(sourceID: String, _ draft: RunDefaultsDraft) {
    let state = agentSettingsState(sourceID)
    state.saveError = nil
    guard state.draft != draft else { return }
    state.draft = draft
    state.draftVersion &+= 1
  }

  /// Web disables Discard while saving; the submitted draft settles first.
  public func discardRunDefaults(sourceID: String) {
    guard let state = agentSettings[sourceID], !state.saving else { return }
    state.saveError = nil
    guard state.draft != nil else { return }
    state.draft = nil
    state.draftVersion &+= 1
  }

  /// Web `clearSettingsDraftIfEqual`: a draft equal to what is now saved is not unsaved work.
  public func reconcileRunDefaultsDraft(sourceID: String) {
    guard let state = agentSettings[sourceID], let draft = state.draft, !state.saving,
      agent(sourceID) != nil, draft == savedRunDefaults(sourceID)
    else { return }
    state.draft = nil
    state.draftVersion &+= 1
  }

  func reconcileRunDefaultsDrafts() {
    for sourceID in agentSettings.keys { reconcileRunDefaultsDraft(sourceID: sourceID) }
  }

  /// Applies a confirmed agent row and protects it from bootstrap reads that began earlier.
  func applyAgentWrite(_ written: WebAgentSummary, pinOnly: Bool) {
    guard var value = bootstrap,
      let index = value.agents.firstIndex(where: { $0.sourceId == written.sourceId })
    else { return }
    agentWriteClock &+= 1
    var record = agentWrites[written.sourceId] ?? AgentWrite()
    record.pinned = .some(written.pinned)
    record.pinnedClock = agentWriteClock
    if pinOnly {
      value.agents[index].pinned = written.pinned
    } else {
      value.agents[index] = written
      record.runSettings = written.runSettings
      record.runSettingsClock = agentWriteClock
    }
    agentWrites[written.sourceId] = record
    bootstrap = value
    reconcileAgentRestarts()
    scheduleCache()
  }

  /// Overlays writes confirmed after `began` onto a bootstrap read that started before them.
  func protectAgentWrites(_ value: inout ApiBootstrap, began: UInt64) -> Bool {
    var patched = false
    for index in value.agents.indices {
      guard let write = agentWrites[value.agents[index].sourceId] else { continue }
      // Only fields confirmed after this read began are newer than its rows.
      if let pinned = write.pinned, write.pinnedClock > began {
        value.agents[index].pinned = pinned
        patched = true
      }
      if let runSettings = write.runSettings, write.runSettingsClock > began {
        value.agents[index].runSettings = runSettings
        patched = true
      }
    }
    return patched
  }

  /// Safe, locally generated failure text; never a server body.
  static func settingsFailure(_ error: any Error) -> String {
    if let error = error as? APIError { return error.safeDetails }
    return "The console could not be reached."
  }
}
