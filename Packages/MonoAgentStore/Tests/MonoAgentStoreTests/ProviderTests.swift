// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentTestSupport
import Testing

@testable import MonoAgentStore

@MainActor struct ProviderTests {
  let source = "agent-example"
  var base: String { "/api/v1/agents/\(source)/provider-auth" }
  var usagePath: String { "/api/v1/agents/\(source)/provider-usage" }
  let statusJSON =
    #"{"schema":"mono-agent.provider-auth.v1","generatedAt":"2026-05-17T12:00:00Z","providers":[{"providerId":"openai","label":"OpenAI","usages":[],"state":"present","source":"stored","credentialType":"oauth","verification":"not_verified","methods":[{"authType":"api_key","strategy":"api_key_prompt","label":"API key","recommended":true}]}]}"#
  func session(_ id: String = "auth-one", state: String = "awaiting_input") throws
    -> ProviderAuthSessionSnapshot
  {
    try decode(
      #"{"schema":"mono-agent.provider-auth-session.v1","id":"\#(id)","providerId":"openai","authType":"api_key","strategy":"api_key_prompt","state":"\#(state)","createdAt":"2026-05-17T12:00:00Z","updatedAt":"2026-05-17T12:00:00Z","expiresAt":"2026-05-17T12:10:00Z","authUrl":{"url":"https://auth.example.net/private-flow","instructions":"Sign in"},"prompt":{"id":"prompt-one","type":"secret","message":"API key"}}"#
    )
  }
  func usage(_ percent: Int = 25, stale: Bool = false) throws -> ProviderUsageSnapshot {
    try decode(
      #"{"schema":"mono-agent.provider-usage.v1","providers":[{"providerId":"openai-codex","label":"Codex","fetchedAt":"2026-05-17T12:00:00Z","stale":\#(stale),"windows":[{"kind":"weekly","label":"Weekly","usedPercent":\#(percent),"periodMs":604800000}]}]}"#
    )
  }
  func live() async throws -> Harness {
    let h = try await AgentSettingsTests().live()
    h.store.bootstrap?.agents[0].supportsProviderAuth = true
    h.store.bootstrap?.agents[0].supportsProviderAuthChecks = true
    h.store.bootstrap?.agents[0].supportsProviderUsage = true
    h.store.bootstrap?.agents[0].supportsProviderUsageRefresh = true
    await h.transport.set(
      base, [.response(try response(try decode(statusJSON) as ProviderAuthStatusSnapshot))])
    await h.transport.set(usagePath, [.response(try response(try usage()))])
    h.store.openProviders(sourceID: source)
    await eventually {
      !h.store.providerState(source).statusLoading && !h.store.providerState(source).usageLoading
    }
    return h
  }
  func method(_ h: Harness) throws -> ProviderAuthMethod {
    try #require(h.store.providerState(source).status?.providers.first?.methods.first)
  }
  func start(_ h: Harness) throws {
    let m = try method(h)
    h.store.startProviderAuth(sourceID: source, providerID: "openai", method: m)
    h.store.startProviderAuth(
      sourceID: source, providerID: "openai", method: m, confirmedReplacement: true)
  }

  @Test func presenceNeverMeansVerifiedAndAllEvidenceLabelsMatch() throws {
    var provider = try #require(
      (try decode(statusJSON) as ProviderAuthStatusSnapshot).providers.first)
    #expect(ProviderPresentation.authLabel(provider) == "Not verified")
    provider.verification = "verified_by_live_request"
    #expect(ProviderPresentation.authLabel(provider) == "OK")
    provider.verification = "verified_by_account_request"
    #expect(ProviderPresentation.authLabel(provider) == "Credential OK")
    provider.state = "not_applicable"
    #expect(ProviderPresentation.authLabel(provider) == "Not applicable")
    provider.state = "missing"
    #expect(ProviderPresentation.authLabel(provider) == "Needs action")
  }
  @Test func serverErrorTextIsBoundedAtUTF8Boundaries() {
    let text = ProviderPresentation.boundedText(String(repeating: "🦉", count: 2000))
    #expect(text.utf8.count == 4096)
    #expect(text.count == 1024)
    #expect(ProviderPresentation.boundedText("<b>plain text</b>") == "<b>plain text</b>")
  }
  @Test func replacementNeedsAnOwnerBoundConfirmationAndOneAdmission() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    let m = try method(h)
    await h.transport.set(base + "/sessions", [.paused])
    h.store.startProviderAuth(sourceID: source, providerID: "openai", method: m)
    #expect(state.replacement == m)
    #expect(await h.transport.count(base + "/sessions") == 0)
    h.store.startProviderAuth(
      sourceID: source, providerID: "openai", method: m, confirmedReplacement: true)
    h.store.startProviderAuth(
      sourceID: source, providerID: "openai", method: m, confirmedReplacement: true)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(try response(try session(), status: 201))
    await eventually { !state.busy }
    #expect(state.session?.id == "auth-one")
    #expect(await h.transport.count(base + "/sessions", method: "POST") == 1)
    h.store.closeProviders(sourceID: source)
  }
  @Test func slowUsageGETDoesNotStrandAuthAndManualSupersedesIt() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(usagePath, [.paused])
    h.store.loadProviderUsage(sourceID: source)
    await eventually { await h.transport.pauseCount() == 1 }
    // Ordinary GET is not an action exclusion.
    await h.transport.set(base + "/sessions", [.response(try response(try session(), status: 201))])
    try start(h)
    await eventually { !state.busy }
    #expect(state.session?.id == "auth-one")
    h.store.cancelProviderAuth(sourceID: source)  // active auth blocks manual refresh
    h.store.refreshProviderUsage(sourceID: source)
    #expect(await h.transport.count(usagePath + "/refresh") == 0)
    await h.transport.release(try response(try usage(40)))
    h.store.closeProviders(sourceID: source)
  }
  @Test func manualRefreshWinsAgainstCancellationIgnoringGETAndKeepsLastGoodOnFailure() async throws
  {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(usagePath, [.paused])
    h.store.loadProviderUsage(sourceID: source)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(usagePath + "/refresh", [.response(try response(try usage(75)))])
    h.store.refreshProviderUsage(sourceID: source)
    h.store.refreshProviderUsage(sourceID: source)
    await eventually { !state.usageRefreshing }
    await h.transport.release(try response(try usage(10)))
    await eventually { !state.usageLoading }
    #expect(state.usage?.providers.first?.windows.first?.usedPercent == 75)
    #expect(await h.transport.count(usagePath + "/refresh", method: "POST") == 1)
    await h.transport.set(
      usagePath + "/refresh",
      [.response(HTTPResponse(data: Data("raw private response".utf8), status: 500))])
    h.store.refreshProviderUsage(sourceID: source)
    await eventually { !state.usageRefreshing }
    #expect(state.usage?.providers.first?.windows.first?.usedPercent == 75)
    #expect(state.usage?.providers.first?.stale == true)
    #expect(state.usageError == "Provider usage is unavailable.")
    h.store.closeProviders(sourceID: source)
  }
  @Test func lateAdmissionAfterCloseIsCancelledWithoutResurrectingTheSession() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.paused])
    await h.transport.set(
      base + "/sessions/auth-one", [.response(HTTPResponse(data: Data(), status: 204))])
    try start(h)
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.closeProviders(sourceID: source)
    await h.transport.release(try response(try session(), status: 201))
    await eventually { await h.transport.count(base + "/sessions/auth-one", method: "DELETE") == 1 }
    #expect(state.session == nil && !state.busy)
  }
  @Test func backgroundClearsAuthMaterialAndLateAdmissionCannotWriteCleanup() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.paused])
    try start(h)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.store.scenePhaseChanged(.background)
    await h.transport.release(try response(try session(), status: 201))
    await eventually { await h.transport.pauseCount() == 0 }
    #expect(state.session == nil && state.methodProviderID == nil && state.replacement == nil)
    #expect(await h.transport.count(base + "/sessions/auth-one", method: "DELETE") == 0)
  }
  @Test func inactiveOnlyCoversAndBackgroundRetainsOnlyIDsForGETResume() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.response(try response(try session(), status: 201))])
    try start(h)
    await eventually { !state.busy }
    await h.store.scenePhaseChanged(.inactive)
    #expect(h.store.providerPrivacyCovered)
    #expect(state.session?.authUrl != nil)
    await h.store.scenePhaseChanged(.background)
    #expect(state.session == nil && state.resumeSessionID == "auth-one")
    // Resume under a new epoch, no replayed POST, by-id GET only.
    h.store.backgrounded = false
    h.store.connection = .live
    await h.transport.set(
      base + "/sessions/auth-one", [.response(try response(try session(state: "succeeded")))])
    h.store.resumeProviders(state)
    await eventually { state.session?.state == "succeeded" }
    #expect(await h.transport.count(base + "/sessions", method: "POST") == 1)
    h.store.closeProviders(sourceID: source)
  }
  @Test func submissionIsSingleFlightAndCredentialNeverEntersStorageOrDiagnostics() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.response(try response(try session(), status: 201))])
    try start(h)
    await eventually { !state.busy }
    await h.transport.set(base + "/sessions/auth-one/input", [.paused])
    h.store.submitProviderAuth(
      sourceID: source, sessionID: "auth-one", promptID: "prompt-one",
      value: "fictional-secret-marker")
    h.store.submitProviderAuth(
      sourceID: source, sessionID: "auth-one", promptID: "prompt-one",
      value: "fictional-secret-marker")
    await eventually { await h.transport.pauseCount() == 1 }
    #expect(await h.transport.count(base + "/sessions/auth-one/input") == 1)
    #expect(!String(reflecting: state).contains("fictional-secret-marker"))
    #expect(!String(reflecting: state.session).contains("private-flow"))
    await h.store.flushAuthored()
    await h.store.flushCache()
    let files = FileManager.default.enumerator(at: h.directory, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      guard let data = try? Data(contentsOf: file) else { continue }
      let text = String(decoding: data, as: UTF8.self)
      #expect(!text.contains("fictional-secret-marker") && !text.contains("private-flow"))
    }
    await h.transport.release(try response(try session(state: "succeeded")))
    await eventually { !state.busy }
    h.store.closeProviders(sourceID: source)
  }
  @Test func pollingUsesOneSecondAndAbsentResourceClearsWithoutCredentialFailure() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.response(try response(try session(), status: 201))])
    await h.transport.set(
      base + "/sessions/auth-one",
      [
        .response(
          HTTPResponse(
            data: Data(#"{"error":{"code":"provider_auth_not_found","message":"expired"}}"#.utf8),
            status: 404))
      ])
    try start(h)
    await eventually { !state.busy }
    await eventually { await h.clock.pending() >= 2 }
    await h.clock.advance(0.9)
    #expect(await h.transport.count(base + "/sessions/auth-one") == 0)
    await h.clock.advance(0.1)
    await eventually { state.session == nil }
    #expect(state.authError == nil && state.resumeSessionID == nil)
    h.store.closeProviders(sourceID: source)
  }
  @Test func checksAreSingleFlightAndExcludeAuthAndManualRefresh() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    let check: ProviderAuthCheckSessionSnapshot = try decode(
      #"{"schema":"mono-agent.provider-auth-check.v1","id":"check-one","state":"running","createdAt":"2026-05-17T12:00:00Z","updatedAt":"2026-05-17T12:00:00Z","expiresAt":"2026-05-17T12:10:00Z","results":[{"providerId":"openai","label":"OpenAI","state":"running"}]}"#
    )
    await h.transport.set(base + "/checks", [.paused])
    h.store.startProviderCheck(sourceID: source)
    h.store.startProviderCheck(sourceID: source)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.release(try response(check, status: 201))
    await eventually { !state.busy }
    #expect(state.checkActive)
    h.store.openProviderAuth(sourceID: source, providerID: "openai")
    h.store.refreshProviderUsage(sourceID: source)
    #expect(state.methodProviderID == nil && !state.usageRefreshing)
    var done = check
    done.state = "completed"
    done.results[0].state = "passed"
    await h.transport.set(base + "/checks/check-one", [.response(try response(done))])
    await eventually { await h.clock.pending() >= 2 }
    await h.clock.advance(1)
    await eventually { state.check?.state == "completed" }
    #expect(!state.checkActive)
    #expect(ProviderPresentation.checkSummary(state.check!) == "Checks complete: 1 of 1 passed.")
    h.store.adoptProviderCheck(check, state: state)
    #expect(state.check?.state == "completed", "terminal checks never regress")
    #expect(await h.transport.count(base + "/checks", method: "POST") == 1)
    h.store.closeProviders(sourceID: source)
  }
  @Test func staleUsageWithoutErrorUsesFifteenSecondsAndNormalUsesThreeHundred() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(
      usagePath,
      [.response(try response(try usage(30, stale: true))), .response(try response(try usage(35)))])
    h.store.loadProviderUsage(sourceID: source)
    await eventually { !state.usageLoading }
    let before = await h.transport.count(usagePath)
    await eventually { await h.clock.pending() >= 1 }
    await h.clock.advance(14)
    #expect(await h.transport.count(usagePath) == before)
    await h.clock.advance(1)
    await eventually { state.usage?.providers.first?.windows.first?.usedPercent == 35 }
    await eventually { !state.usageLoading }
    let after = await h.transport.count(usagePath)
    await eventually { await h.clock.pending() >= 1 }
    await h.clock.advance(299)
    #expect(await h.transport.count(usagePath) == after)
    await h.clock.advance(1)
    await eventually { await h.transport.count(usagePath) == after + 1 }
    h.store.closeProviders(sourceID: source)
  }
  @Test func latePollCannotRegressAnInputCompletion() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.response(try response(try session(), status: 201))])
    try start(h)
    await eventually { !state.busy }
    await h.transport.set(base + "/sessions/auth-one", [.paused])
    await eventually { await h.clock.pending() >= 2 }
    await h.clock.advance(1)
    await eventually { await h.transport.pauseCount() == 1 }
    await h.transport.set(
      base + "/sessions/auth-one/input", [.response(try response(try session(state: "succeeded")))])
    h.store.submitProviderAuth(
      sourceID: source, sessionID: "auth-one", promptID: "prompt-one", value: "fictional-input")
    await eventually { !state.busy }
    await h.transport.release(try response(try session()))
    #expect(state.session?.state == "succeeded")
    #expect(state.authError == nil)
    h.store.closeProviders(sourceID: source)
  }
  @Test func capabilityAndLiveStateAreRecheckedImmediatelyBeforeDispatch() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    let m = try method(h)
    h.store.startProviderAuth(sourceID: source, providerID: "openai", method: m)
    h.store.startProviderAuth(
      sourceID: source, providerID: "openai", method: m, confirmedReplacement: true)
    h.store.bootstrap?.agents[0].supportsProviderAuth = false
    await eventually { !state.busy }
    #expect(await h.transport.count(base + "/sessions", method: "POST") == 0)
    h.store.startProviderCheck(sourceID: source)
    h.store.connection = .offline
    await eventually { !state.busy }
    #expect(await h.transport.count(base + "/checks", method: "POST") == 0)
    h.store.closeProviders(sourceID: source)
  }
  @Test func failedReplacementPreservesThePriorSession() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(
      base + "/sessions",
      [
        .response(try response(try session(), status: 201)),
        .response(HTTPResponse(data: Data("private".utf8), status: 500)),
      ])
    try start(h)
    await eventually { !state.busy }
    try start(h)
    await eventually { !state.busy }
    #expect(state.session?.id == "auth-one")
    #expect(state.authError == "Console request failed (HTTP 500).")
    #expect(await h.transport.count(base + "/sessions") == 2)
    h.store.closeProviders(sourceID: source)
  }
  @Test func generationReplacementRejectsLateInputAndOfflineGuardsRefuseAllActions() async throws {
    let h = try await live()
    let state = h.store.providerState(source)
    await h.transport.set(base + "/sessions", [.paused])
    try start(h)
    await eventually { await h.transport.pauseCount() == 1 }
    h.store.bootstrap?.agents[0].generation = "new-generation"
    h.store.reconcileProviderOwners()
    await h.transport.release(try response(try session(), status: 201))
    #expect(state.session == nil && !state.open)
    h.store.connection = .offline
    h.store.openProviders(sourceID: source)
    h.store.startProviderCheck(sourceID: source)
    h.store.refreshProviderUsage(sourceID: source)
    #expect(!state.busy && !state.usageRefreshing)
    h.store.closeProviders(sourceID: source)
  }
}

struct ProviderUsageProjectionTests {
  let half = "2026-09-22T20:10:22.000Z"
  let reset = "2026-09-26T08:10:22.000Z"
  func window(
    _ used: Double, reset: String? = "2026-09-26T08:10:22.000Z", period: Double = 604_800_000
  ) throws -> ProviderUsageWindow {
    var w: ProviderUsageWindow = try decode(
      #"{"kind":"weekly","label":"Weekly","usedPercent":0,"periodMs":604800000}"#)
    w.usedPercent = used
    w.resetsAt = reset
    w.periodMs = period
    return w
  }
  @Test(arguments: [0.0, 25, 49.5, 50, 60, 75, 90, 100]) func halfWindowVectors(_ used: Double)
    throws
  {
    let p = try #require(ProviderUsageProjection.project(try window(used), fetchedAt: half))
    #expect(abs(p.pace - used / 50) < 0.000001)
    #expect(p.elapsedFraction == 0.5 && p.confidence == .normal)
    #expect(p.severity == (used <= 50 ? .ok : used < 75 ? .ahead : .unsustainable))
    #expect((p.exhaustsAt != nil) == (used > 50))
    #expect((p.leadMs != nil) == (used > 50))
    if used < 50 {
      #expect(abs((p.projectedUnusedPercent ?? -1) - (100 - used * 2)) < 0.000001)
    } else {
      #expect(p.projectedUnusedPercent == nil)
    }
    if used == 100 { #expect(p.exhaustsAt == ProviderUsageProjection.parseDate(half)) }
  }
  @Test(arguments: [0.0, 4, 50]) func lowConfidenceSuppressesWarningsAndUnused(_ used: Double)
    throws
  {
    let p = try #require(
      ProviderUsageProjection.project(try window(used), fetchedAt: "2026-09-19T16:34:22.000Z"))
    #expect(abs(p.elapsedFraction - 0.05) < 0.000001)
    #expect(p.confidence == .low && p.severity == .ok)
    #expect(p.exhaustsAt == nil && p.leadMs == nil && p.projectedUnusedPercent == nil)
    #expect(abs(p.pace - used / 5) < 0.000001)
  }
  @Test func invalidWindowsAndSkewHaveNoProjection() throws {
    for anchor in ["not-a-date", "2026-09-19T08:10:21.000Z", "2026-09-26T08:10:23.000Z"] {
      #expect(ProviderUsageProjection.project(try window(50), fetchedAt: anchor) == nil)
    }
    #expect(ProviderUsageProjection.project(try window(50, reset: nil), fetchedAt: half) == nil)
    #expect(
      ProviderUsageProjection.project(try window(50, reset: "not-a-date"), fetchedAt: half) == nil)
    #expect(ProviderUsageProjection.project(try window(50, period: 0), fetchedAt: half) == nil)
  }
  @Test func codexNinetySixPercentAndMillisecondRounding() throws {
    let p = try #require(
      ProviderUsageProjection.project(try window(96), fetchedAt: "2026-09-22T09:35:00.000Z"))
    #expect(p.severity == .unsustainable && p.confidence == .normal && p.pace > 1.5)
    let exhaust = try #require(p.exhaustsAt)
    #expect(exhaust > ProviderUsageProjection.parseDate("2026-09-22T09:35:00.000Z")!)
    #expect(exhaust < ProviderUsageProjection.parseDate(reset)!)
    #expect(
      p.leadMs == ProviderUsageProjection.parseDate(reset)!.timeIntervalSince1970 * 1000 - exhaust
        .timeIntervalSince1970 * 1000)
  }
  @Test func leadFormattingUsesCeilMinutes() {
    let vectors: [(Double, String)] = [
      (0, "0m"), (-1000, "0m"), (720000, "12m"), (61000, "2m"), (3_600_000, "1h 0m"),
      (19_200_000, "5h 20m"), (90_000_000, "1d 1h"), (266_400_000, "3d 2h"),
    ]
    for (ms, expected) in vectors { #expect(ProviderUsageProjection.formatLead(ms) == expected) }
  }
}
