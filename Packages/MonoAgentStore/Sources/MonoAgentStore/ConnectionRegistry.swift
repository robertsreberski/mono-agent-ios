// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation

public enum ConnectionState: Sendable, Equatable {
  case disconnected
  case connecting
  case connected(ConsoleIdentity)
  case failed(ProbeError)
}

@MainActor @Observable
public final class ConnectionRegistry {
  public private(set) var consoles: [SavedConsole] = []
  public private(set) var selectedID: UUID?
  public private(set) var states: [UUID: ConnectionState] = [:]
  public private(set) var storageError: String?
  public private(set) var localDataError: String?
  public private(set) var isLoaded = false
  @ObservationIgnored private let repository: any ProfileRepository
  @ObservationIgnored private let consoleRepository: (any ConsoleRepository)?
  @ObservationIgnored private let cronReplyRecovery: CronReplyRecoveryStore?
  @ObservationIgnored private let probe: ConnectionProbe
  @ObservationIgnored private var loadStarted = false
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var generations: [UUID: UUID] = [:]

  public init(
    repository: any ProfileRepository, probe: ConnectionProbe,
    consoleRepository: (any ConsoleRepository)? = nil,
    cronReplyRecovery: CronReplyRecoveryStore? = nil
  ) {
    self.cronReplyRecovery = cronReplyRecovery
    self.consoleRepository = consoleRepository
    self.repository = repository
    self.probe = probe
  }

  public func load() async {
    guard !loadStarted else { return }
    // Reserve before suspension so overlapping view tasks cannot overwrite subsequent edits.
    loadStarted = true
    defer { isLoaded = true }
    do {
      let snapshot = try await repository.load()
      revision = snapshot.revision
      consoles = snapshot.consoles
      selectedID = snapshot.selectedID.flatMap { id in consoles.contains { $0.id == id } ? id : nil
      }
      storageError = nil
    } catch {
      storageError =
        "Saved consoles could not be loaded. They have not been overwritten. Relaunch to retry after fixing storage, or delete local app data to reset."
    }
  }

  @discardableResult
  public func add(name: String, endpoint: ConsoleEndpoint, httpAcknowledged: Bool) async throws
    -> UUID
  {
    guard isLoaded else { throw RegistryError.notLoaded }
    try validate(endpoint, acknowledged: httpAcknowledged)
    let console = SavedConsole(name: name, endpoint: endpoint, httpAcknowledged: httpAcknowledged)
    consoles.append(console)
    selectedID = console.id
    await persist()
    return console.id
  }

  /// A changed URL is a new namespace, even if a server advertises the same hostName.
  @discardableResult
  public func edit(id: UUID, name: String, endpoint: ConsoleEndpoint, httpAcknowledged: Bool)
    async throws -> UUID
  {
    guard isLoaded else { throw RegistryError.notLoaded }
    try validate(endpoint, acknowledged: httpAcknowledged)
    guard let index = consoles.firstIndex(where: { $0.id == id }) else {
      throw RegistryError.notFound
    }
    if consoles[index].endpoint == endpoint {
      consoles[index].name = name
      consoles[index].httpAcknowledged = httpAcknowledged
    } else {
      generations[id] = nil
      states[id] = nil
      let replacement = SavedConsole(
        name: name, endpoint: endpoint, httpAcknowledged: httpAcknowledged)
      consoles[index] = replacement
      if selectedID == id { selectedID = replacement.id }
    }
    let newID = consoles[index].id
    await persist()
    return newID
  }

  public func select(_ id: UUID) async {
    guard isLoaded, consoles.contains(where: { $0.id == id }) else { return }
    selectedID = id
    await persist()
  }

  public func remove(_ id: UUID) async {
    guard isLoaded else { return }
    consoles.removeAll { $0.id == id }
    generations[id] = nil
    states[id] = nil
    if selectedID == id { selectedID = consoles.first?.id }
    await cronReplyRecovery?.delete(profileID: id)
    await persist()
    do { try await consoleRepository?.delete(profileID: id) } catch {
      localDataError =
        "Retained console data could not be deleted. Delete local app data to remove it."
    }
  }

  /// Only a deliberate user action (or DEBUG scripted scenario) should call connect.
  public func connect(_ id: UUID) async {
    guard isLoaded, let console = consoles.first(where: { $0.id == id }) else { return }
    do { try validate(console.endpoint, acknowledged: console.httpAcknowledged) } catch { return }
    let generation = UUID()
    generations[id] = generation
    states[id] = .connecting
    do {
      let identity = try await probe.probe(console.endpoint)
      guard generations[id] == generation,
        let index = consoles.firstIndex(where: { $0.id == id })
      else { return }
      consoles[index].lastIdentity = identity
      states[id] = .connected(identity)
      await persist()
    } catch is CancellationError {
      if generations[id] == generation { states[id] = .disconnected }
    } catch {
      guard generations[id] == generation else { return }
      states[id] = .failed(error as? ProbeError ?? .connectivity)
    }
  }

  private func validate(_ endpoint: ConsoleEndpoint, acknowledged: Bool) throws {
    if endpoint.isInsecure && !endpoint.isLocalHost && !acknowledged {
      throw RegistryError.httpConfirmationRequired
    }
  }

  private func persist() async {
    // Do not destroy an unreadable or newer-format file by writing an empty replacement.
    guard isLoaded, storageError == nil else { return }
    guard revision < UInt64.max else {
      storageError = "Changes are in memory only: the profile revision limit was reached."
      return
    }
    revision += 1
    let snapshot = ProfileSnapshot(consoles: consoles, selectedID: selectedID, revision: revision)
    do {
      try await repository.save(snapshot)
    } catch {
      guard revision == snapshot.revision else { return }
      storageError =
        "Changes are in memory only: saved consoles could not be written. Relaunch may lose changes."
    }
  }
}

public enum RegistryError: Error, LocalizedError {
  case notLoaded
  case notFound
  case httpConfirmationRequired
  public var errorDescription: String? {
    switch self {
    case .notLoaded: "Wait for saved consoles to finish loading."
    case .notFound: "This console is no longer saved."
    case .httpConfirmationRequired:
      "Confirm the plaintext HTTP risk before connecting to this non-local host."
    }
  }
}
