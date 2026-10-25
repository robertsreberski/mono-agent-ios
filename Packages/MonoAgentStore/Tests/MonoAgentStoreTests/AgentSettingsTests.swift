// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Observation
import Testing
import os

@testable import MonoAgentStore

struct ObservedFlag: Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: false)
  func set() { lock.withLock { $0 = true } }
  var value: Bool { lock.withLock { $0 } }
}

func agentEnvelope(_ agent: WebAgentSummary) throws -> HTTPResponse {
  try response(
    JSONValue.object([
      "agent": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(agent))
    ]))
}

@MainActor struct AgentSettingsTests {
  let source = "agent-example"
  var defaults: String { "/api/v1/agents/\(source)/run-defaults" }
  var agentPath: String { "/api/v1/agents/\(source)" }

  func live(status: String = "online", override: RunConfiguration? = nil) async throws -> Harness {
    let h = Harness()
    await h.store.hydrate()
    var bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    bootstrap.agents[0].status = status
    bootstrap.agents[0].runSettings.override = override
    h.store.bootstrap = bootstrap
    h.store.started = true
    h.store.connection = .live
    return h
  }

  func agentResponse(
    _ h: Harness, model: String? = nil, effort: String? = nil, pinned: Bool? = nil,
    override: Bool = true
  ) throws -> HTTPResponse {
    var agent = try #require(h.store.agents.first)
    agent.runSettings.override =
      override ? try decode(#"{"model":\#(quoted(model)),"effort":\#(quoted(effort))}"#) : nil
    if let pinned { agent.pinned = pinned }
    return try agentEnvelope(agent)
  }

  private func quoted(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

  func body(_ h: Harness, _ path: String) async -> [String: JSONValue]? {
    let request = await h.transport.requests.last { $0.url?.path == path }
    guard let data = request?.httpBody,
      case .object(let fields) = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    return fields
  }

  @Test func draftsStayOutOfStorageAndTheDotIgnoresTheContextChoice() async throws {
    let h = try await live()
    #expect(!h.store.hasUnsavedRunDefaults(source))
    h.store.editRunDefaults(sourceID: source, .init(context1M: true))
    #expect(!h.store.hasUnsavedRunDefaults(source), "web header dot compares model/effort")
    #expect(h.store.runDefaultsDirty(source))
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    #expect(h.store.hasUnsavedRunDefaults(source))
    // Memory only: flushing every persisted record writes no trace of the draft.
    h.store.editRunDefaults(sourceID: source, .init(model: "draft:only-in-memory"))
    await h.store.flushAuthored()
    await h.store.flushCache()
    let files = FileManager.default.enumerator(at: h.directory, includingPropertiesForKeys: nil)
    var written = 0
    while let url = files?.nextObject() as? URL {
      guard let data = try? Data(contentsOf: url) else { continue }
      written += 1
      #expect(!String(decoding: data, as: UTF8.self).contains("draft:only-in-memory"))
    }
    #expect(written > 0, "the cache and authored records were written")
    h.store.discardRunDefaults(sourceID: source)
    #expect(h.store.agentSettingsState(source).draft == nil)
    // A draft equal to the saved override is not unsaved work.
    h.store.editRunDefaults(sourceID: source, .init())
    h.store.reconcileRunDefaultsDraft(sourceID: source)
    #expect(h.store.agentSettingsState(source).draft == nil)
    #expect(await h.transport.requests.isEmpty)
  }

  @Test func headerDotIsObservableBeforeTheFirstDraft() async throws {
    let h = try await live()
    let changed = ObservedFlag()
    withObservationTracking {
      _ = h.store.hasUnsavedRunDefaults(source)
    } onChange: {
      changed.set()
    }
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    #expect(changed.value, "a dashboard that read no draft yet still learns about the first one")
  }

  @Test func customSavePutsNullsForBlankFieldsAndPublishesTheReturnedAgent() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.response(try agentResponse(h, model: "sample:small"))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small · Default")
    let state = h.store.agentSettingsState(source)
    #expect(state.saving)
    await eventually { !state.saving }
    #expect(await h.transport.count(defaults, method: "PUT") == 1)
    let fields = await body(h, defaults)
    #expect(fields?["model"] == .string("sample:small"))
    #expect(fields?["effort"] == .null)
    #expect(fields?["context1M"] == nil, "no explicit 1M choice is omitted")
    #expect(h.store.agents.first?.runSettings.override?.model == "sample:small")
    #expect(state.draft == nil && state.saveError == nil)
    #expect(state.notice == "New conversations will start with Sample Small · Default.")
  }

  @Test func explicitContextChoiceIsSent() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.response(try agentResponse(h, model: "sample:large"))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:large", context1M: false))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Large · Default")
    await eventually { !h.store.agentSettingsState(source).saving }
    #expect(await body(h, defaults)?["context1M"] == .bool(false))
  }

  @Test func newerEditDuringSaveStaysUnsaved() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.paused])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:fast"))
    await h.transport.release(try agentResponse(h, model: "sample:small"))
    let state = h.store.agentSettingsState(source)
    await eventually { !state.saving }
    #expect(state.draft == .init(model: "sample:fast"))
    #expect(h.store.hasUnsavedRunDefaults(source))
  }

  @Test func failedSaveKeepsTheDraftShowsSafeTextAndNeverRetries() async throws {
    let h = try await live()
    await h.transport.set(
      defaults,
      [.response(HTTPResponse(data: Data(#"{"error":"secret detail"}"#.utf8), status: 500))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small", effort: "low"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small · Low")
    let state = h.store.agentSettingsState(source)
    await eventually { !state.saving }
    #expect(state.saveError == "Console request failed (HTTP 500).")
    #expect(state.draft == .init(model: "sample:small", effort: "low"))
    #expect(state.notice == nil)
    #expect(await h.transport.count(defaults) == 1)
    // Editing clears the error; an explicit retry is the only second request.
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small", effort: "medium"))
    #expect(state.saveError == nil)
  }

  @Test func offlineAgentBlocksCustomSaveButResetDeletesThroughALiveConsole() async throws {
    let h = try await live(status: "offline", override: try decode(#"{"model":"sample:small"}"#))
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:fast"))
    #expect(h.store.runDefaultsSaveBlocked(source) != nil)
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Fast")
    #expect(!h.store.agentSettingsState(source).saving)
    #expect(await h.transport.requests.isEmpty)
    await h.transport.set(defaults, [.response(try agentResponse(h, override: false))])
    h.store.editRunDefaults(sourceID: source, .init())
    #expect(h.store.runDefaultsSaveBlocked(source) == nil)
    h.store.saveRunDefaults(sourceID: source, summary: "Agent config")
    await eventually { !h.store.agentSettingsState(source).saving }
    #expect(await h.transport.count(defaults, method: "DELETE") == 1)
    #expect(h.store.agents.first?.runSettings.override == nil)
    #expect(h.store.agentSettingsState(source).draft == nil)
  }

  @Test func consoleThatIsNotLiveCannotWriteEvenForAnOnlineAgent() async throws {
    let h = try await live()
    h.store.connection = .waiting
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    #expect(h.store.runDefaultsSaveBlocked(source) == "Reconnect to the console to save.")
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    h.store.setAgentPinned(sourceID: source, pinned: true)
    #expect(await h.transport.requests.isEmpty)
  }

  @Test func pinAndSaveOnOneAgentAreOrdered() async throws {
    let h = try await live()
    await h.transport.set(agentPath, [.paused])
    // The server answers the later save with the row it holds after the pin.
    await h.transport.set(
      defaults, [.response(try agentResponse(h, model: "sample:small", pinned: true))])
    h.store.setAgentPinned(sourceID: source, pinned: true)
    let state = h.store.agentSettingsState(source)
    #expect(state.pinPending && state.requestedPin == true)
    h.store.setAgentPinned(sourceID: source, pinned: false)
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    var pinned = try #require(h.store.agents.first)
    pinned.pinned = true
    await h.transport.release(try agentEnvelope(pinned))
    await eventually { !state.saving }
    // Deterministic order: the save is dispatched only after the pin's reply was released.
    #expect(
      await h.transport.timeline == [
        "PATCH " + agentPath, "release", "PUT " + defaults,
      ], "the save waits behind the pin")
    #expect(await h.transport.count(agentPath, method: "PATCH") == 1, "a pending pin ignores taps")
    #expect(await h.transport.count(defaults) == 1)
    #expect(h.store.agents.first?.pinned == true)
    #expect(!state.pinPending && state.requestedPin == nil)
  }

  @Test func bootstrapThatBeganBeforeAWriteCannotUndoIt() async throws {
    let h = try await live()
    let stale = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    await h.transport.set("/api/v1/bootstrap", [.paused])
    let read = Task { await h.store.refreshBootstrap() }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(defaults, [.response(try agentResponse(h, model: "sample:small"))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { !h.store.agentSettingsState(source).saving }
    await h.transport.release(try response(stale, etag: "\"stale\""))
    await read.value
    #expect(h.store.agents.first?.runSettings.override?.model == "sample:small")
    #expect(h.store.bootstrapETag == nil, "the patched read cannot be revalidated as current")
    // A read that starts after the write is authoritative again.
    await h.transport.set("/api/v1/bootstrap", [.response(try response(stale))])
    await h.store.refreshBootstrap()
    #expect(h.store.agents.first?.runSettings.override == nil)
  }

  /// Review regression: a later pin-only confirmation must not re-assert older run settings
  /// over a bootstrap that started after them and carries another client's newer defaults.
  @Test func pinConfirmationDoesNotResurrectOlderRunSettings() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.response(try agentResponse(h, model: "sample:a"))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:a"))
    h.store.saveRunDefaults(sourceID: source, summary: "A")
    await eventually { !h.store.agentSettingsState(source).saving }
    #expect(h.store.agents.first?.runSettings.override?.model == "sample:a")
    // Another client saves B; this read starts after A was confirmed and pauses with B.
    var other = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    other.agents[0].runSettings.override = try decode(#"{"model":"sample:b","effort":null}"#)
    await h.transport.set("/api/v1/bootstrap", [.paused])
    let read = Task { await h.store.refreshBootstrap() }
    await eventually { await h.transport.pauseCount() == 1 }
    // A pin-only write confirms while the read is paused.
    await h.transport.set(
      agentPath, [.response(try agentResponse(h, model: "sample:a", pinned: true))])
    h.store.setAgentPinned(sourceID: source, pinned: true)
    await eventually { !h.store.agentSettingsState(source).pinPending }
    await h.transport.release(try response(other))
    await read.value
    #expect(h.store.agents.first?.runSettings.override?.model == "sample:b", "B is newer than A")
    #expect(h.store.agents.first?.pinned == true, "the pin confirmed during the read is kept")
  }

  @Test func retryAfterAFailureIsOneExplicitSecondRequest() async throws {
    let h = try await live()
    await h.transport.set(
      defaults,
      [
        .response(HTTPResponse(data: Data(), status: 503)),
        .response(try agentResponse(h, model: "sample:small")),
      ])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    let state = h.store.agentSettingsState(source)
    await eventually { !state.saving }
    #expect(state.saveError != nil && state.draft != nil)
    #expect(await h.transport.count(defaults) == 1)
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { !state.saving }
    #expect(await h.transport.count(defaults) == 2)
    #expect(state.saveError == nil && state.draft == nil)
    #expect(h.store.agents.first?.runSettings.override?.model == "sample:small")
  }

  @Test func discardWhileSavingIsIgnoredLikeTheWebsDisabledButton() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.paused])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { await h.transport.pauseCount() == 1 }
    let state = h.store.agentSettingsState(source)
    h.store.discardRunDefaults(sourceID: source)
    #expect(state.draft == .init(model: "sample:small"), "the submitted draft settles first")
    await h.transport.release(try agentResponse(h, model: "sample:small"))
    await eventually { !state.saving }
    #expect(state.draft == nil && state.notice != nil)
  }

  @Test func lateReplyForOneAgentNeverTouchesAnother() async throws {
    let h = try await live()
    var second = try #require(h.store.agents.first)
    second.sourceId = "agent-second"
    second.label = "Second agent"
    h.store.bootstrap?.agents.append(second)
    await h.transport.set(defaults, [.paused])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { await h.transport.pauseCount() == 1 }
    // The operator moves to the second agent and starts a draft there.
    h.store.selectedBucket = BucketKey(sourceID: "agent-second")
    h.store.editRunDefaults(sourceID: "agent-second", .init(model: "sample:fast"))
    await h.transport.release(try agentResponse(h, model: "sample:small"))
    await eventually { !h.store.agentSettingsState(source).saving }
    #expect(h.store.agent(source)?.runSettings.override?.model == "sample:small")
    #expect(h.store.agent("agent-second")?.runSettings.override == nil)
    #expect(h.store.agentSettingsState("agent-second").draft == .init(model: "sample:fast"))
    #expect(h.store.agentSettingsState("agent-second").notice == nil)
    #expect(h.store.agentSettingsState(source).notice != nil)
  }

  /// Web compares the draft with the saved override, not the agent config: choosing the
  /// config's own values is a real override (PUT), only "Use agent config" removes it.
  @Test func choosingTheConfigValuesWritesAnOverrideLikeTheWeb() async throws {
    let h = try await live()
    h.store.bootstrap?.agents[0].runSettings.config = try decode(
      #"{"model":"sample:large","effort":"medium"}"#)
    await h.transport.set(
      defaults, [.response(try agentResponse(h, model: "sample:large", effort: "medium"))])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:large", effort: "medium"))
    #expect(h.store.runDefaultsDirty(source))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Large · Medium")
    await eventually { !h.store.agentSettingsState(source).saving }
    #expect(await h.transport.count(defaults, method: "PUT") == 1)
    #expect(await h.transport.count(defaults, method: "DELETE") == 0)
    #expect(await body(h, defaults)?["model"] == .string("sample:large"))
  }

  @Test func stoppingDuringASaveNeverPublishesTheLateReply() async throws {
    let h = try await live()
    await h.transport.set(defaults, [.paused])
    h.store.editRunDefaults(sourceID: source, .init(model: "sample:small"))
    h.store.saveRunDefaults(sourceID: source, summary: "Sample Small")
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.stop()
    await h.transport.release(try agentResponse(h, model: "sample:small"))
    let state = h.store.agentSettingsState(source)
    await eventually { !state.saving }
    #expect(h.store.agents.first?.runSettings.override == nil)
    #expect(state.draft == .init(model: "sample:small"), "the unsent choice is kept")
    #expect(state.notice == nil && state.saveError == nil)
  }
}

@MainActor struct ModelCatalogTests {
  let source = "agent-example"
  var path: String { "/api/v1/agents/\(source)/models" }

  func live() async throws -> Harness {
    let h = Harness()
    await h.store.hydrate()
    var bootstrap = try JSONDecoder().decode(ApiBootstrap.self, from: Scenario.bootstrap.data)
    bootstrap.agents[0].generation = "generation-1"
    h.store.bootstrap = bootstrap
    h.store.started = true
    h.store.connection = .live
    return h
  }

  func page(_ ids: [String], name: String? = nil, next: String?) throws -> HTTPResponse {
    let models = ids.map {
      #"{"id":"\#($0)","name":"\#(name ?? $0)","provider":"sample","providerLabel":"Sample"}"#
    }
    let cursor = next.map { "\"\($0)\"" } ?? "null"
    return HTTPResponse(
      data: Data(
        #"{"models":[\#(models.joined(separator: ","))],"nextCursor":\#(cursor),"truncated":false}"#
          .utf8))
  }

  @Test func walksCursorsDeduplicatesAndStopsOnARepeatedCursor() async throws {
    let h = try await live()
    await h.transport.set(
      path,
      [
        .response(try page(["a", "b"], next: "c1")),
        .response(try page(["b"], name: "B renamed", next: "c2")),
        .response(try page(["c"], next: "c2")),
        .response(try page(["never"], next: nil)),
      ])
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == 3)
    let state = try #require(h.store.modelCatalog(sourceID: source).providers["sample"])
    #expect(state.status == .loaded)
    #expect(state.models.map(\.id) == ["a", "b", "c"])
    #expect(state.models[1].name == "B renamed")
    let query = await h.transport.requests.last?.url?.query ?? ""
    #expect(query.contains("limit=100") && query.contains("provider=sample"))
    #expect(query.contains("cursor=c2"))
  }

  @Test func pageWalkIsBoundedToFivePages() async throws {
    let h = try await live()
    await h.transport.set(
      path, (0..<7).map { .response(try! page(["m\($0)"], next: "cursor-\($0)")) })
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == ModelCatalogBounds.pageLimit)
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.models.count == 5)
  }

  @Test func loadedCatalogIsTrustedForTheTTLThenRevalidatedAndReplaced() async throws {
    let h = try await live()
    await h.transport.set(
      path, [.response(try page(["a", "b"], next: nil)), .response(try page(["b"], next: nil))])
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == 1)
    await h.clock.advance(ModelCatalogBounds.ttl + 1)
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == 2)
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.models.map(\.id) == ["b"])
  }

  @Test func failureKeepsHeldRowsAndAlwaysRefetches() async throws {
    let h = try await live()
    await h.transport.set(path, [.failure, .response(try page(["a"], next: nil))])
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.status == .failed)
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.status == .loaded)
  }

  /// Review regression: a newer generation must not wait on (and lose to) an older flight.
  @Test func newerGenerationLoadsWhileTheOlderFlightIsStillOpen() async throws {
    let h = try await live()
    await h.transport.set(path, [.paused, .response(try page(["g2"], next: nil))])
    let first = Task { await h.store.ensureProviderCatalog(sourceID: source, provider: "sample") }
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.bootstrap?.agents[0].generation = "generation-2"
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == 2, "G2 did not return early on the G1 flight")
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.models.map(\.id) == ["g2"])
    await h.transport.release(try page(["g1"], next: nil))
    await first.value
    let state = h.store.modelCatalog(sourceID: source).providers["sample"]
    #expect(state?.status == .loaded && state?.models.map(\.id) == ["g2"], "G1 cannot clobber G2")
  }

  @Test func singleFlightAndGenerationChangeInvalidates() async throws {
    let h = try await live()
    await h.transport.set(path, [.paused, .response(try page(["new"], next: nil))])
    let first = Task { await h.store.ensureProviderCatalog(sourceID: source, provider: "sample") }
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(await h.transport.count(path) == 1, "one flight per agent and provider")
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.status == .loading)
    h.store.bootstrap?.agents[0].generation = "generation-2"
    await h.transport.release(try page(["old"], next: nil))
    await first.value
    #expect(h.store.modelCatalog(sourceID: source).providers.isEmpty, "old generation is hidden")
    await h.store.ensureProviderCatalog(sourceID: source, provider: "sample")
    #expect(h.store.modelCatalog(sourceID: source).providers["sample"]?.models.map(\.id) == ["new"])
  }
}
