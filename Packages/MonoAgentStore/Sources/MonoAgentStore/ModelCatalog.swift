// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// One provider's fetched `/agents/:id/models` catalog (web `ProviderCatalogState`).
public struct ProviderCatalogState: Sendable, Equatable {
  public enum Status: Sendable, Equatable { case loading, loaded, failed }
  public internal(set) var models: [WebCatalogModel]
  public internal(set) var status: Status
  var fetchedAt: Date?
}

/// Per-agent provider catalogs, valid only for the agent generation that served them.
public struct AgentModelCatalog: Sendable, Equatable {
  let generation: String?
  /// First-requested order, which the settings rows preserve (web object insertion order).
  public internal(set) var order: [String] = []
  public internal(set) var providers: [String: ProviderCatalogState] = [:]
  public var ordered: [(provider: String, state: ProviderCatalogState)] {
    order.compactMap { id in providers[id].map { (id, $0) } }
  }
}

public enum ModelCatalogBounds {
  /// 5 × 100 rows is well past any advertised cap (web `CATALOG_PAGE_LIMIT`).
  public static let pageLimit = 5
  public static let pageSize = 100
  /// A loaded catalog is trusted this long before a request revalidates it (web `CATALOG_TTL_MS`).
  public static let ttl: TimeInterval = 60
}

extension ConsoleStore {
  /// The catalogs for the agent's current generation; another generation's pages are invisible.
  public func modelCatalog(sourceID: String) -> AgentModelCatalog {
    guard let catalog = modelCatalogs[sourceID],
      catalog.generation == agent(sourceID)?.generation
    else { return AgentModelCatalog(generation: agent(sourceID)?.generation) }
    return catalog
  }

  /// Web `ensureProviderCatalog`: single flight per agent/provider; an error always refetches,
  /// a loaded catalog refetches after the TTL; pages are walked by cursor, bounded, and replace
  /// (never merge into) what was held.
  public func ensureProviderCatalog(sourceID: String, provider: String) async {
    guard !provider.isEmpty, started, !stopping, !backgrounded,
      let generation = agent(sourceID).map(\.generation)
    else { return }
    // One flight per agent generation and Store lifetime: a newer generation (or lifetime)
    // never waits on an older flight whose answer it will reject.
    let lifetime = epoch
    let flight = [sourceID, provider, generation ?? "", String(lifetime)].joined(separator: "\u{0}")
    let resource = sourceID + "\u{0}" + provider
    guard !catalogFlights.contains(flight) else { return }
    let now = await clock.wallNow()
    guard !catalogFlights.contains(flight), epoch == lifetime,
      agent(sourceID)?.generation == generation
    else {
      return
    }
    // A "loading" state is authoritative only while this generation/lifetime's own flight is
    // open (checked above). Otherwise it was left by a flight a stop or background abandoned,
    // and the resource must be fetched again rather than wait for an answer it will reject.
    if let existing = modelCatalog(sourceID: sourceID).providers[provider],
      existing.status == .loaded,
      now.timeIntervalSince(existing.fetchedAt ?? .distantPast) < ModelCatalogBounds.ttl
    {
      return
    }
    catalogFlights.insert(flight)
    let owner = UUID()
    catalogOwners[resource] = owner
    defer {
      catalogFlights.remove(flight)
      // An abandoned walk must not leave a permanent "loading" that blocks every later request,
      // but only the latest owner may settle the resource's state.
      if catalogOwners[resource] == owner {
        catalogOwners[resource] = nil
        if modelCatalogs[sourceID]?.generation == generation,
          modelCatalogs[sourceID]?.providers[provider]?.status == .loading
        {
          update(sourceID, generation: generation, provider: provider) { $0?.status = .failed }
        }
      }
    }
    func current() -> Bool {
      epoch == lifetime && !Task.isCancelled && agent(sourceID)?.generation == generation
        && catalogOwners[resource] == owner
    }
    update(sourceID, generation: generation, provider: provider) { state in
      state = ProviderCatalogState(
        models: state?.models ?? [], status: .loading, fetchedAt: state?.fetchedAt)
    }
    var collected: [WebCatalogModel] = []
    var cursor: String?
    var lastCursor: String?
    do {
      for _ in 0..<ModelCatalogBounds.pageLimit {
        let page = try await api.models(
          id: sourceID,
          query: .init(limit: ModelCatalogBounds.pageSize, provider: provider, cursor: cursor),
          etag: nil
        ).valueRequired()
        guard current() else { return }
        collected.append(contentsOf: page.models)
        // A producer that repeats a cursor would loop forever; stop instead.
        guard let next = page.nextCursor, next != lastCursor else { break }
        lastCursor = next
        cursor = next
      }
      let fetchedAt = await clock.wallNow()
      guard current() else { return }
      // Replaced, not merged: a revalidation must be able to drop a model no longer served.
      // Later duplicates replace earlier values but keep the first position (JS Map order).
      var deduplicated: [WebCatalogModel] = []
      var positions: [String: Int] = [:]
      for model in collected {
        if let position = positions[model.id] {
          deduplicated[position] = model
        } else {
          positions[model.id] = deduplicated.count
          deduplicated.append(model)
        }
      }
      update(sourceID, generation: generation, provider: provider) { state in
        state = ProviderCatalogState(models: deduplicated, status: .loaded, fetchedAt: fetchedAt)
      }
    } catch {
      guard current() else { return }
      update(sourceID, generation: generation, provider: provider) { state in
        state = ProviderCatalogState(
          models: state?.models ?? [], status: .failed, fetchedAt: state?.fetchedAt)
      }
    }
  }

  private func update(
    _ sourceID: String, generation: String?, provider: String,
    _ change: (inout ProviderCatalogState?) -> Void
  ) {
    var catalog =
      modelCatalogs[sourceID].flatMap { $0.generation == generation ? $0 : nil }
      ?? AgentModelCatalog(generation: generation)
    var state = catalog.providers[provider]
    change(&state)
    if !catalog.order.contains(provider) { catalog.order.append(provider) }
    catalog.providers[provider] = state
    modelCatalogs[sourceID] = catalog
  }
}
