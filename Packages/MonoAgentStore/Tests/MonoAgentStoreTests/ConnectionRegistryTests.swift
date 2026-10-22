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

@Test @MainActor func httpAcknowledgmentIsRequiredForPublicHosts() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let registry = ConnectionRegistry(
    repository: FileProfileRepository(directory: directory),
    probe: ConnectionProbe(transport: ScriptedTransport([])))
  await registry.load()
  await #expect(throws: RegistryError.httpConfirmationRequired) {
    try await registry.add(
      name: "Plaintext", endpoint: ConsoleEndpoint("http://example.com"), httpAcknowledged: false)
  }
  #expect(registry.consoles.isEmpty)
  _ = try await registry.add(
    name: "Plaintext", endpoint: ConsoleEndpoint("http://example.com"), httpAcknowledged: true)
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
