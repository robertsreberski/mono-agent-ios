// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentDesign
import MonoAgentStore

/// The banners above the dashboard: connection/freshness, refresh problems, storage and
/// insecure HTTP. A live, fresh console draws none of the first two — the state is spoken
/// through the navigation subtitle instead, as the web console announces it.
struct DashboardBanner: Equatable, Identifiable {
  enum Action: Equatable {
    /// Probe the saved console (explicit user action only).
    case connect
    /// Clear the reported problem and run one Store reconciliation.
    case reconcile
  }

  var kind: ConnectionBanner.Kind
  var title: String
  var message: String?
  var action: Action?
  var actionTitle: String?
  var identifier: String
  var id: String { identifier }

  struct Inputs: Equatable {
    var registry: ConnectionState?
    var started: Bool
    var sync: SyncState
    var freshness: Freshness
    var errorMessage: String?
    var storage: [PersistenceState]
    var insecure: Bool
  }

  static func banners(_ inputs: Inputs) -> [DashboardBanner] {
    var result: [DashboardBanner] = []
    var errorShown = false
    switch inputs.registry ?? .disconnected {
    case .connecting:
      result.append(
        .init(
          kind: .offline, title: "Checking console…",
          message: "Showing conversations saved on this device.", identifier: "banner-connecting"))
    case .failed(let error):
      result.append(
        .init(
          kind: .offline, title: "Console unreachable",
          message: "Showing conversations saved on this device. \(error.localizedDescription)",
          action: .connect, actionTitle: "Retry", identifier: "banner-offline"))
    case .disconnected:
      result.append(
        .init(
          kind: .offline, title: "Offline",
          message: "Showing conversations saved on this device. Connect to refresh them.",
          action: .connect, actionTitle: "Connect", identifier: "banner-offline"))
    case .connected:
      if !inputs.started {
        result.append(
          .init(
            kind: .offline, title: "Opening console…",
            message: "Showing conversations saved on this device.", identifier: "banner-connecting")
        )
      } else if inputs.sync == .waiting
        || (inputs.sync == .offline && inputs.errorMessage != nil)
      {
        result.append(
          .init(
            kind: .offline, title: "Offline",
            message: inputs.errorMessage.map { "Showing conversations saved on this device. \($0)" }
              ?? "Showing conversations saved on this device; they may be out of date.",
            action: .reconcile, actionTitle: "Retry", identifier: "banner-offline"))
        errorShown = true
      } else if inputs.sync != .live && inputs.freshness == .stale {
        result.append(
          .init(
            kind: .offline, title: "Connecting…",
            message: "Saved conversations stay visible while the console catches up.",
            identifier: "banner-connecting"))
      }
    }
    if !errorShown, let error = inputs.errorMessage {
      result.append(
        .init(
          kind: .problem, title: error,
          message: inputs.freshness == .stale ? "Some of what is shown may be out of date." : nil,
          action: inputs.started ? .reconcile : nil, actionTitle: inputs.started ? "Retry" : nil,
          identifier: "banner-problem"))
    }
    if let worst = inputs.storage.first(where: { $0 != .durable }) {
      result.append(
        .init(
          kind: .storage, title: "Storage warning",
          message: worst == .memoryOnly
            ? "Some local data could not be read; changes are kept in memory only."
            : "Some changes could not be saved on this device.",
          identifier: "banner-storage"))
    }
    if inputs.insecure {
      result.append(
        .init(
          kind: .insecureHTTP, title: "Insecure HTTP",
          message: "Traffic to this console can be read or changed on the network.",
          identifier: "banner-insecure"))
    }
    return result
  }

  /// The spoken/subtitle connection state when no connection banner is drawn.
  static func subtitle(console: String, inputs: Inputs) -> String {
    if case .connected = inputs.registry, inputs.started, inputs.sync == .live {
      return "\(console) · Online"
    }
    if case .connected = inputs.registry, inputs.started, inputs.sync != .waiting,
      inputs.errorMessage == nil
    {
      return "\(console) · Connecting"
    }
    return "\(console) · Offline"
  }
}
