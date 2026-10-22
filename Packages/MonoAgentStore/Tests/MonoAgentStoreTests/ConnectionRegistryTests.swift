// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import MonoAgentTestSupport
import Testing

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test @MainActor func savedConsolesSurviveRelaunchAndEndpointEditsAreIsolated() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = FileProfileRepository(directory: directory)
  let registry = ConnectionRegistry(
    repository: repository,
    probe: ConnectionProbe(transport: ScriptedTransport(Scenario.consoleOnline.steps)))
  await registry.load()
  let first = try await registry.add(
    name: "Flockbox", endpoint: Scenario.endpoint, httpAcknowledged: false)
  await registry.connect(first)
  #expect(registry.states[first] == .connected(registry.consoles[0].lastIdentity!))
  let second = try await registry.add(
    name: "Second", endpoint: ConsoleEndpoint("http://192.168.1.9:8787"), httpAcknowledged: false)
  await registry.select(first)
  let restarted = ConnectionRegistry(
    repository: repository, probe: ConnectionProbe(transport: ScriptedTransport([])))
  await restarted.load()
  #expect(restarted.consoles.count == 2)
  #expect(restarted.selectedID == first)
  #expect(restarted.states[first] == nil)
  let renamed = try await restarted.edit(
    id: first, name: "New label", endpoint: Scenario.endpoint, httpAcknowledged: false)
  #expect(renamed == first)
  let replacement = try await restarted.edit(
    id: first, name: "New endpoint", endpoint: ConsoleEndpoint("https://other.example.com"),
    httpAcknowledged: false)
  #expect(replacement != first)
  #expect(restarted.selectedID == replacement)
  #expect(restarted.consoles.first?.lastIdentity == nil)
  #expect(restarted.states[first] == nil)
  await restarted.remove(replacement)
  let final = try await repository.load()
  #expect(final.consoles.map(\.id) == [second])
  #expect(final.selectedID == second)
}

@Test @MainActor func failureNeverConnectsAndRetryCanSucceed() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let registry = ConnectionRegistry(
    repository: FileProfileRepository(directory: directory),
    probe: ConnectionProbe(
      transport: ScriptedTransport([.failure(.timedOut)] + Scenario.consoleOnline.steps)))
  await registry.load()
  let id = try await registry.add(
    name: "Flockbox", endpoint: Scenario.endpoint, httpAcknowledged: false)
  await registry.connect(id)
  #expect(registry.states[id] == .failed(.timeout))
  #expect(registry.consoles[0].lastIdentity == nil)
  await registry.connect(id)
  guard case .connected = registry.states[id] else {
    Issue.record("Retry did not connect")
    return
  }
}

@Test(arguments: [
  "http://example.com", "http://10.0.0.1.evil.example", "http://127.0.0.1.attacker.example",
  "http://0127.0.0.1", "http://0x7f.0.0.1",
]) @MainActor func httpAcknowledgmentIsRequiredForPublicHosts(input: String) async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let registry = ConnectionRegistry(
    repository: FileProfileRepository(directory: directory),
    probe: ConnectionProbe(transport: ScriptedTransport([])))
  await registry.load()
  await #expect(throws: RegistryError.httpConfirmationRequired) {
    try await registry.add(
      name: "Plaintext", endpoint: ConsoleEndpoint(input), httpAcknowledged: false)
  }
  #expect(registry.consoles.isEmpty)
  _ = try await registry.add(
    name: "Plaintext", endpoint: ConsoleEndpoint(input), httpAcknowledged: true)
  #expect(registry.consoles[0].httpAcknowledged)
}

private actor SuspendedTransport: HTTPTransport {
  private var continuation: CheckedContinuation<HTTPResponse, Never>?
  private var hasStarted = false
  func send(_ request: URLRequest) async -> HTTPResponse {
    if request.url?.path == "/api/v1/bootstrap" { return Scenario.bootstrap }
    return await withCheckedContinuation {
      continuation = $0
      hasStarted = true
    }
  }
  func started() -> Bool { hasStarted }
  func finish() {
    continuation?.resume(returning: Scenario.health)
    continuation = nil
  }
}

@Test @MainActor func removedConsoleCannotBeResurrectedByLateProbe() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let transport = SuspendedTransport()
  let registry = ConnectionRegistry(
    repository: FileProfileRepository(directory: directory),
    probe: ConnectionProbe(transport: transport))
  await registry.load()
  let id = try await registry.add(
    name: "Flockbox", endpoint: Scenario.endpoint, httpAcknowledged: false)
  let task = Task { await registry.connect(id) }
  while !(await transport.started()) { await Task.yield() }
  await registry.remove(id)
  await transport.finish()
  await task.value
  #expect(registry.consoles.isEmpty)
  #expect(registry.states[id] == nil)
}

@Test @MainActor func corruptProfilesAreNotOverwritten() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appendingPathComponent("profiles-v1.json")
  let bytes = Data("not JSON".utf8)
  try bytes.write(to: file)
  let registry = ConnectionRegistry(
    repository: FileProfileRepository(directory: directory),
    probe: ConnectionProbe(transport: ScriptedTransport([])))
  await registry.load()
  #expect(registry.storageError != nil)
  _ = try await registry.add(
    name: "Memory only", endpoint: Scenario.endpoint, httpAcknowledged: false)
  #expect(try Data(contentsOf: file) == bytes)
}

private actor OrderedProbeTransport: HTTPTransport {
  private var waiters: [Int: CheckedContinuation<HTTPResponse, any Error>] = [:]
  private(set) var startedCount = 0

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    if request.url?.path == "/healthz" { return Scenario.health }
    let index = startedCount
    startedCount += 1
    return try await withCheckedThrowingContinuation { waiters[index] = $0 }
  }

  func succeed(_ index: Int, identity: ConsoleIdentity) throws {
    struct Fixture: Encodable {
      let version = 1
      let console: ConsoleIdentity
    }
    let data = try JSONEncoder().encode(Fixture(console: identity))
    waiters.removeValue(forKey: index)?.resume(returning: HTTPResponse(data: data))
  }

  func fail(_ index: Int) {
    waiters.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut))
  }
}

@Test(arguments: [false, true]) @MainActor
func overlappingProbesKeepNewerSuccess(olderFails: Bool) async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let transport = OrderedProbeTransport()
  let repository = FileProfileRepository(directory: directory)
  let registry = ConnectionRegistry(
    repository: repository, probe: ConnectionProbe(transport: transport))
  await registry.load()
  let id = try await registry.add(
    name: "Flockbox", endpoint: Scenario.endpoint, httpAcknowledged: false)
  let older = Task { await registry.connect(id) }
  while await transport.startedCount < 1 { await Task.yield() }
  let newer = Task { await registry.connect(id) }
  while await transport.startedCount < 2 { await Task.yield() }
  let identity = ConsoleIdentity(
    hostName: "console.example.ts.net", displayName: "New result", theme: "ocean")
  try await transport.succeed(1, identity: identity)
  await newer.value
  #expect(registry.states[id] == .connected(identity))
  if olderFails {
    await transport.fail(0)
  } else {
    try await transport.succeed(
      0,
      identity: ConsoleIdentity(
        hostName: "console.example.ts.net", displayName: "Old result", theme: "plum"))
  }
  await older.value
  #expect(registry.states[id] == .connected(identity))
  #expect(registry.consoles.first?.lastIdentity == identity)
  #expect(try await repository.load().consoles.first?.lastIdentity == identity)
}

private actor LoadGateRepository: ProfileRepository {
  private var continuation: CheckedContinuation<ProfileSnapshot, Never>?
  private let initial: ProfileSnapshot
  private(set) var waiting = false
  private(set) var saved: [ProfileSnapshot] = []
  init(_ snapshot: ProfileSnapshot) { initial = snapshot }
  func load() async -> ProfileSnapshot {
    await withCheckedContinuation {
      continuation = $0
      waiting = true
    }
  }
  func finishLoad() {
    continuation?.resume(returning: initial)
    continuation = nil
  }
  func save(_ snapshot: ProfileSnapshot) {
    guard snapshot.revision > (saved.last?.revision ?? initial.revision) else { return }
    saved.append(snapshot)
  }
}

@Test @MainActor func mutationsCannotRaceInitialLoad() async throws {
  let existing = SavedConsole(name: "Existing", endpoint: Scenario.endpoint)
  let repository = LoadGateRepository(
    ProfileSnapshot(consoles: [existing], selectedID: existing.id, revision: 4))
  let registry = ConnectionRegistry(
    repository: repository, probe: ConnectionProbe(transport: ScriptedTransport([])))
  let loading = Task { await registry.load() }
  while !(await repository.waiting) { await Task.yield() }
  await #expect(throws: RegistryError.notLoaded) {
    try await registry.add(name: "Too early", endpoint: Scenario.endpoint, httpAcknowledged: false)
  }
  await #expect(throws: RegistryError.notLoaded) {
    try await registry.edit(
      id: existing.id, name: "Too early", endpoint: Scenario.endpoint, httpAcknowledged: false)
  }
  await registry.select(existing.id)
  await registry.remove(existing.id)
  await registry.connect(existing.id)
  #expect(await repository.saved.isEmpty)
  #expect(registry.consoles.isEmpty)
  #expect(registry.states.isEmpty)
  await repository.finishLoad()
  await loading.value
  #expect(registry.isLoaded)
  #expect(registry.consoles == [existing])
  _ = try await registry.add(
    name: "After load", endpoint: Scenario.endpoint, httpAcknowledged: false)
  #expect(await repository.saved.last?.consoles.count == 2)
  #expect(await repository.saved.last?.revision == 5)
}

@Test func fileRepositoryRejectsOutOfOrderAndEqualRevisionSnapshots() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let console = SavedConsole(name: "Newer", endpoint: Scenario.endpoint)
  let repository = FileProfileRepository(directory: directory)
  try await repository.save(
    ProfileSnapshot(consoles: [console], selectedID: console.id, revision: 2))
  try await repository.save(ProfileSnapshot(revision: 1))
  try await repository.save(ProfileSnapshot(revision: 2))
  let freshRepository = FileProfileRepository(directory: directory)
  // Even a caller that has not loaded yet cannot overwrite a newer on-disk revision.
  try await freshRepository.save(ProfileSnapshot(revision: 1))
  let loaded = try await freshRepository.load()
  #expect(loaded.consoles == [console])
  #expect(loaded.selectedID == console.id)
  #expect(loaded.revision == 2)
}

@Test func legacyProfilesStartAtRevisionZero() throws {
  let snapshot = try JSONDecoder().decode(
    ProfileSnapshot.self, from: Data(#"{"version":1,"consoles":[]}"#.utf8))
  #expect(snapshot.revision == 0)
}
