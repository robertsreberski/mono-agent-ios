// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI

#if DEBUG
  import MonoAgentTestSupport
#endif

@MainActor @Observable
final class AppModel {
  let registry: ConnectionRegistry
  private(set) var store: ConsoleStore?
  @ObservationIgnored private let consoleRepository: any ConsoleRepository
  @ObservationIgnored private var networkAdapter: ConsoleNetworkAdapter?
  @ObservationIgnored private var compositionGeneration: UInt64 = 0
  @ObservationIgnored private var compositionTask: Task<Void, Never>?
  var connectedProfile: SavedConsole? {
    guard let id = registry.selectedID, case .connected = registry.states[id] else { return nil }
    return registry.consoles.first { $0.id == id }
  }
  private var retainedProfile: SavedConsole? {
    guard let id = registry.selectedID else { return nil }
    return registry.consoles.first { $0.id == id && $0.lastIdentity != nil }
  }
  /// A retained identity is selected, so a Store is (or is about to be) composed for it.
  var expectsStore: Bool { retainedProfile != nil }
  var storeCompositionKey: String {
    guard let profile = retainedProfile else { return "none" }
    return profile.id.uuidString + ConsoleNamespace(profile: profile).identity
      + (connectedProfile == nil ? "offline" : "connected")
  }
  private(set) var isReady = false
  @ObservationIgnored private var providerPrivacyCovered = false
  let appearance: ColorScheme?
  /// Fixed "now" for relative times in synthetic fixtures; `nil` follows the clock.
  let referenceDate: Date?
  /// DEBUG fixture launch state applied once the dashboard is ready; always `nil` in Release.
  let launchQuery: String?
  let launchThreadID: String?
  /// DEBUG `--open-settings <index|section>`: agent settings opened once after readiness.
  let launchSettings: AgentSettingsTarget?
  let launchAutomations: Bool
  let launchCronJob: String?
  @ObservationIgnored private var started = false
  #if DEBUG
    @ObservationIgnored private let scenario: Scenario?
    @ObservationIgnored private let storeScenario: StoreScenario?
    @ObservationIgnored private let fixtureTheme: String
    /// A DEBUG design-catalog scenario replaces the console shell; storage stays isolated.
    let catalog: DesignCatalogScenario?
    @ObservationIgnored private(set) var composerScript: ComposerScript?
    private(set) var mcpScript: McpUiScript?
    /// Composer fixture scenarios add a synthetic attachment source to the attach menu.
    var offersSampleAttachments: Bool { storeScenario?.isComposer == true }
    var opaqueFixtureSurfaces: Bool {
      scenario != nil && ProcessInfo.processInfo.arguments.contains("--fixture-opaque")
    }
    /// Fixtures never leave the app: "Open web console" records the URL it would open.
    private(set) var fixtureExternalURL: URL?
    var isFixture: Bool { scenario != nil }
    func recordExternalOpen(_ url: URL) { fixtureExternalURL = url }
  #else
    var offersSampleAttachments: Bool { false }
  #endif

  init() {
    let directory: URL
    let transport: any HTTPTransport
    #if DEBUG
      let configuration: LaunchConfiguration
      do {
        configuration = try LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
      } catch { fatalError("Invalid DEBUG launch configuration: \(error)") }
      scenario = configuration.scenario
      storeScenario = configuration.storeScenario
      catalog = configuration.catalog
      appearance = configuration.appearance
      fixtureTheme = configuration.fixtureTheme
      referenceDate = configuration.storeScenario?.isDashboard == true ? DashboardFixture.now : nil
      launchAutomations = configuration.storeScenario?.isAutomations == true
      launchCronJob =
        configuration.storeScenario?.rawValue.hasPrefix("cron-") == true
        ? AutomationsFixture.jobID : nil
      launchQuery = configuration.storeScenario?.launchQuery
      launchThreadID = configuration.storeScenario?.launchThreadID
      launchSettings = configuration.storeScenario == nil ? nil : configuration.settings
      if let scenario {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("SyntheticFixtures", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        transport = ConsoleProbeFixture(
          steps: Self.steps(scenario, theme: configuration.fixtureTheme))
        // Fixture storage is always fresh. Reset never deletes real profiles.
        UIView.setAnimationsEnabled(false)
      } else {
        directory = Self.profileDirectory
        transport = URLSessionTransport()
      }
    #else
      // Release ignores all fixture/reset/appearance arguments.
      appearance = nil
      referenceDate = nil
      launchAutomations = false
      launchCronJob = nil
      launchQuery = nil
      launchThreadID = nil
      launchSettings = nil
      directory = Self.profileDirectory
      transport = URLSessionTransport()
    #endif
    consoleRepository = FileConsoleRepository(
      directory: directory.appendingPathComponent("Consoles"))
    registry = ConnectionRegistry(
      repository: FileProfileRepository(directory: directory),
      probe: ConnectionProbe(transport: transport), consoleRepository: consoleRepository
    )
  }

  #if DEBUG
    /// Previews share the exact same catalog and fail-closed transport as XCUI screenshots.
    init(
      scenario: Scenario, appearance: ColorScheme? = nil, storeScenario: StoreScenario? = nil,
      consoleRepository: (any ConsoleRepository)? = nil, fixtureTheme: String = "evergreen"
    ) {
      self.scenario = scenario
      self.storeScenario = storeScenario
      self.appearance = appearance
      self.fixtureTheme = fixtureTheme
      referenceDate = storeScenario?.isDashboard == true ? DashboardFixture.now : nil
      launchAutomations = storeScenario?.isAutomations == true
      launchCronJob =
        storeScenario?.rawValue.hasPrefix("cron-") == true ? AutomationsFixture.jobID : nil
      launchQuery = storeScenario?.launchQuery
      launchThreadID = storeScenario?.launchThreadID
      launchSettings = nil
      catalog = nil
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyntheticPreviews", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      self.consoleRepository =
        consoleRepository
        ?? FileConsoleRepository(
          directory: directory.appendingPathComponent("Consoles"))
      registry = ConnectionRegistry(
        repository: FileProfileRepository(directory: directory),
        probe: ConnectionProbe(
          transport: ScriptedTransport(Self.steps(scenario, theme: fixtureTheme))),
        consoleRepository: self.consoleRepository
      )
    }

    /// The probe script, with the fixture identity's theme swapped when one is requested.
    private static func steps(_ scenario: Scenario, theme: String) -> [ScriptedTransport.Step] {
      guard theme != "evergreen", scenario == .consoleOnline else { return scenario.steps }
      let text = String(decoding: Scenario.bootstrap.data, as: UTF8.self)
        .replacingOccurrences(of: #""theme":"evergreen""#, with: #""theme":"\#(theme)""#)
      return [.response(Scenario.health), .response(HTTPResponse(data: Data(text.utf8)))]
    }
  #endif

  private static var profileDirectory: URL {
    URL.applicationSupportDirectory.appendingPathComponent("MonoAgent", isDirectory: true)
  }

  func start() async {
    guard !started else { return }
    started = true
    await registry.load()
    #if DEBUG
      if let scenario, scenario != .connectionEmpty {
        do {
          let insecure = storeScenario?.usesInsecureEndpoint == true
          let id = try await registry.add(
            name: "Flockbox",
            endpoint: insecure ? AgentSettingsFixture.insecureEndpoint : Scenario.endpoint,
            httpAcknowledged: insecure
          )
          await registry.connect(id)
          if ProcessInfo.processInfo.arguments.contains("--fixture-console-states") {
            try await prepareConsoleVariants(selectedID: id)
          }
        } catch { fatalError("Synthetic fixture setup failed: \(error)") }
      }
    #endif
    // Connection/navigation readiness must not wait for cache, journal or stream initialization.
    // Store fixture readiness still guarantees that its prepared state has been hydrated.
    // The dashboard adds its own data readiness (`DashboardView.ready`).
    #if DEBUG
      if storeScenario == nil { isReady = true }
    #else
      isReady = true
    #endif
    await synchronizeStore()
    isReady = true
  }
  func synchronizeStore() async {
    compositionGeneration &+= 1
    let generation = compositionGeneration
    let previous = compositionTask
    let task = Task { [weak self] in
      await previous?.value
      guard let self, self.compositionGeneration == generation else { return }
      await self.synchronizeStoreNow(generation: generation)
    }
    compositionTask = task
    var waiting = task
    var waitingGeneration = generation
    while true {
      await waiting.value
      if compositionGeneration == waitingGeneration {
        compositionTask = nil
        return
      }
      guard let latest = compositionTask else { return }
      waiting = latest
      waitingGeneration = compositionGeneration
    }
  }
  private func synchronizeStoreNow(generation: UInt64) async {
    let profile = retainedProfile
    let connected = connectedProfile != nil
    if let profile, let existing = store, existing.namespace == ConsoleNamespace(profile: profile) {
      if connected {
        #if DEBUG
          if scenario == nil && networkAdapter == nil {
            networkAdapter = ConsoleNetworkAdapter(store: existing)
          }
        #else
          if networkAdapter == nil { networkAdapter = ConsoleNetworkAdapter(store: existing) }
        #endif
        await existing.start()
      } else {
        networkAdapter?.cancel()
        networkAdapter = nil
        await existing.stop()
      }
      return
    }
    let previous = store
    store = nil
    networkAdapter?.cancel()
    networkAdapter = nil
    await previous?.stop()
    guard generation == compositionGeneration, let profile else { return }
    let api: any ConsoleAPI
    let events: any ConsoleEventSource
    #if DEBUG
      if scenario != nil {
        let script = storeScenario?.isComposer == true ? ComposerScript(storeScenario) : nil
        composerScript = script
        let mcp = storeScenario.flatMap {
          $0.isMcp
            ? McpUiScript($0, diagnostics: McpUiDiagnostics(interactive: $0 == .conversationMcpApp))
            : nil
        }
        mcpScript = mcp
        api = APIClient(
          endpoint: profile.endpoint,
          transport: ScenarioConsoleTransport(
            storeScenario, theme: fixtureTheme, script: script, mcp: mcp))
        events = ScenarioEventSource(storeScenario, script: script)
      } else {
        api = APIClient(endpoint: profile.endpoint)
        events = EventStream(endpoint: profile.endpoint)
      }
    #else
      api = APIClient(endpoint: profile.endpoint)
      events = EventStream(endpoint: profile.endpoint)
    #endif
    let next = ConsoleStore(
      profile: profile, api: api, events: events, repository: consoleRepository)
    next.setProviderPrivacyCovered(providerPrivacyCovered)
    store = next
    #if DEBUG
      if let storeScenario {
        try? await storeScenario.prepare(next, repository: consoleRepository, theme: fixtureTheme)
      }
    #endif
    guard generation == compositionGeneration else { return }
    #if DEBUG
      if scenario == nil && connected { networkAdapter = ConsoleNetworkAdapter(store: next) }
    #else
      if connected { networkAdapter = ConsoleNetworkAdapter(store: next) }
    #endif
    // Saved identity permits offline hydration, never an automatic probe or network start.
    if connected { await next.start() } else { await next.hydrate() }
  }

  /// Snapshot protection is published synchronously, before scheduling lifecycle work.
  func scenePrivacyChanged(_ phase: ScenePhase) {
    providerPrivacyCovered = phase != .active
    store?.setProviderPrivacyCovered(providerPrivacyCovered)
  }

  func scenePhaseChanged(_ phase: ScenePhase) async {
    switch phase {
    case .active: await store?.scenePhaseChanged(.active)
    case .background: await store?.scenePhaseChanged(.background)
    case .inactive: await store?.scenePhaseChanged(.inactive)
    @unknown default: break
    }
  }

}

#if DEBUG
  struct LaunchConfiguration {
    let scenario: Scenario?
    let storeScenario: StoreScenario?
    let catalog: DesignCatalogScenario?
    let appearance: ColorScheme?
    /// `--fixture-theme <evergreen|ocean|plum|terracotta>` for the synthetic console identity.
    let fixtureTheme: String
    /// `--open-settings <index|new-conversations|providers|agent>`.
    let settings: AgentSettingsTarget?

    init(arguments: [String]) throws {
      func value(_ flag: String) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
          throw LaunchError.missingValue(flag)
        }
        return arguments[index + 1]
      }
      let requestedScenario = try value("--scenario")
      storeScenario = requestedScenario.flatMap(StoreScenario.init(rawValue:))
      if let name = requestedScenario {
        if storeScenario != nil {
          scenario = .consoleOnline
          catalog = nil
        } else if let catalog = DesignCatalogScenario(rawValue: name) {
          // The catalog never touches real profiles: it runs on the isolated empty fixture.
          self.catalog = catalog
          scenario = .connectionEmpty
        } else if let scenario = Scenario(rawValue: name) {
          self.scenario = scenario
          catalog = nil
        } else {
          throw LaunchError.unknownScenario(name)
        }
      } else {
        scenario = arguments.contains("--reset-test-data") ? .connectionEmpty : nil
        catalog = nil
      }
      if let name = try value("--appearance") {
        switch name {
        case "light": appearance = .light
        case "dark": appearance = .dark
        default: throw LaunchError.unknownAppearance(name)
        }
      } else {
        appearance = nil
      }
      if let name = try value("--open-settings") {
        if name == "index" {
          settings = AgentSettingsTarget()
        } else if let section = AgentSettingsSection(rawValue: name) {
          settings = AgentSettingsTarget(section: section)
        } else {
          throw LaunchError.unknownSettingsSection(name)
        }
      } else {
        settings = nil
      }
      if let name = try value("--fixture-theme") {
        guard ConsoleTheme(rawValue: name) != nil else { throw LaunchError.unknownTheme(name) }
        fixtureTheme = name
      } else {
        fixtureTheme = "evergreen"
      }
    }
  }

  enum LaunchError: Error {
    case missingValue(String)
    case unknownScenario(String)
    case unknownAppearance(String)
    case unknownTheme(String)
    case unknownSettingsSection(String)
  }
#endif
