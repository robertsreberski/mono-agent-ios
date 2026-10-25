// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit
  import MonoAgentTestSupport

  /// Fail-closed probe variants for console management captures. No live URLSession exists.
  actor ConsoleProbeFixture: HTTPTransport {
    let base: ScriptedTransport

    init(steps: [ScriptedTransport.Step]) { base = ScriptedTransport(steps) }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
      switch request.url?.host {
      case "unavailable.example.ts.net": throw URLError(.cannotConnectToHost)
      case "checking.example.ts.net":
        // Deliberately unresolved network work, not a timed screenshot delay. Cancellation
        // terminates AsyncStream's iterator and unwinds the probe.
        let pending = AsyncStream<Never> { _ in }
        for await _ in pending {}
        throw CancellationError()
      default: return try await base.send(request)
      }
    }
  }

  extension AppModel {
    func prepareConsoleVariants(selectedID: UUID) async throws {
      _ = try await registry.add(
        name: "Workroom", endpoint: ConsoleEndpoint("https://workroom.example.ts.net"),
        httpAcknowledged: false)
      let failed = try await registry.add(
        name: "Unavailable console",
        endpoint: ConsoleEndpoint("https://unavailable.example.ts.net"),
        httpAcknowledged: false)
      await registry.connect(failed)
      _ = try await registry.add(
        name: "Field notes", endpoint: ConsoleEndpoint("http://field-notes.example.ts.net:8080"),
        httpAcknowledged: true)
      let checking = try await registry.add(
        name: "Checking console", endpoint: ConsoleEndpoint("https://checking.example.ts.net"),
        httpAcknowledged: false)
      await registry.select(selectedID)
      Task { await registry.connect(checking) }
    }
  }
#endif
