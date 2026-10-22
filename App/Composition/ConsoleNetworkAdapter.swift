// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentStore
import Network

/// Path state is a retry hint, never a declaration of console health.
@MainActor
final class ConsoleNetworkAdapter {
  private let monitor = NWPathMonitor()
  init(store: ConsoleStore) {
    monitor.pathUpdateHandler = { [weak store] path in
      let reachable = path.status == .satisfied
      let constrained = path.isConstrained
      Task { @MainActor in
        await store?.networkChanged(reachable: reachable, constrained: constrained)
      }
    }
    monitor.start(queue: DispatchQueue(label: "console-path-hints"))
  }
  func cancel() { monitor.cancel() }
  deinit { monitor.cancel() }
}
