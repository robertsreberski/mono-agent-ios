// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public struct RefreshBudget: Sendable {
  public var maximumReads: Int
  public var seconds: TimeInterval
  public init(maximumReads: Int = 4, seconds: TimeInterval = 20) {
    self.maximumReads = max(0, maximumReads)
    self.seconds = max(0, seconds)
  }
}
public struct ChangeSummary: Sendable {
  public var changedThreadIDs: Set<String> = []
  public var reads = 0
  public var budgetExhausted = false
  public var persisted = false
  public init() {}
}
/// No observation or UIKit. A future poller supplies scheduling/permission policy separately.
public actor ReconciliationService {
  private let repository: any ConsoleRepository
  private let client: @Sendable (SavedConsole) -> any ConsoleAPI
  private var refreshes: [ConsoleNamespace: UUID] = [:]
  private let clock: any StreamClock
  public init(
    repository: any ConsoleRepository, clock: any StreamClock = SystemStreamClock(),
    client: @escaping @Sendable (SavedConsole) -> any ConsoleAPI = {
      APIClient(endpoint: $0.endpoint)
    }
  ) {
    self.repository = repository
    self.clock = clock
    self.client = client
  }
  public func refresh(profile: SavedConsole, budget: RefreshBudget) async throws -> ChangeSummary {
    let namespace = ConsoleNamespace(profile: profile)
    let request = UUID()
    refreshes[namespace] = request
    defer { if refreshes[namespace] == request { refreshes[namespace] = nil } }
    var record = try await repository.loadCache(namespace)
    let before = Dictionary(
      (record.bootstrap?.threads ?? []).map { ($0.id, $0.revision) }, uniquingKeysWith: max)
    let api = client(profile)
    var summary = ChangeSummary()
    let start = await clock.now()
    guard budget.maximumReads > 0, budget.seconds > 0 else {
      summary.budgetExhausted = true
      return summary
    }
    try Task.checkCancellation()
    // Deadline cancels the in-flight request as well as checking between reads.
    let bootstrap = try await withThrowingTaskGroup(of: ApiBootstrap.self) { group in
      group.addTask { try await api.bootstrap(query: .init(), etag: nil).valueRequired() }
      group.addTask { [clock] in
        try await clock.sleep(seconds: budget.seconds)
        throw CancellationError()
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    summary.reads = 1
    guard refreshes[namespace] == request else { return summary }
    for row in bootstrap.threads where !record.tombstones.contains(row.id) {
      if let revision = before[row.id], row.revision > revision {
        summary.changedThreadIDs.insert(row.id)
      }
    }
    record.bootstrap = bootstrap
    record.revision &+= 1
    if await clock.now() - start >= budget.seconds {
      summary.budgetExhausted = true
      return summary
    }
    try Task.checkCancellation()
    try await repository.saveCache(record, namespace: namespace)
    summary.persisted = true
    return summary
  }
}
