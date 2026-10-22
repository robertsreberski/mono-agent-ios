// SPDX-License-Identifier: GPL-3.0-only
import Foundation
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
  var connectedProfile: SavedConsole? {
    guard let id = registry.selectedID, case .connected = registry.states[id] else { return nil }
    return registry.consoles.first { $0.id == id }
  }
  private var retainedProfile: SavedConsole? {
    guard let id = registry.selectedID else { return nil }
    return registry.consoles.first { $0.id == id && $0.lastIdentity != nil }
  }
  var storeCompositionKey: String {
    guard let profile = retainedProfile else { return "none" }
    return profile.id.uuidString + ConsoleNamespace(profile: profile).identity
      + (connectedProfile == nil ? "offline" : "connected")
  }
  private(set) var isReady = false
  let appearance: ColorScheme?
  @ObservationIgnored private var started = false
  #if DEBUG
    @ObservationIgnored private let scenario: Scenario?
    @ObservationIgnored private let storeScenario: StoreScenario?
    /// A DEBUG design-catalog scenario replaces the console shell; storage stays isolated.
    let catalog: DesignCatalogScenario?
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
      if let scenario {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("SyntheticFixtures", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        transport = ScriptedTransport(scenario.steps)
        // Fixture storage is always fresh. Reset never deletes real profiles.
        UIView.setAnimationsEnabled(false)
      } else {
        directory = Self.profileDirectory
        transport = URLSessionTransport()
      }
    #else
      // Release ignores all fixture/reset/appearance arguments.
      appearance = nil
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
    init(scenario: Scenario, appearance: ColorScheme? = nil, storeScenario: StoreScenario? = nil) {
      self.scenario = scenario
      self.storeScenario = storeScenario
      self.appearance = appearance
      catalog = nil
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyntheticPreviews", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      consoleRepository = FileConsoleRepository(
        directory: directory.appendingPathComponent("Consoles"))
      registry = ConnectionRegistry(
        repository: FileProfileRepository(directory: directory),
        probe: ConnectionProbe(transport: ScriptedTransport(scenario.steps)),
        consoleRepository: consoleRepository
      )
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
          let id = try await registry.add(
            name: "Flockbox", endpoint: Scenario.endpoint, httpAcknowledged: false
          )
          await registry.connect(id)
        } catch { fatalError("Synthetic fixture setup failed: \(error)") }
      }
    #endif
    await synchronizeStore()
    isReady = true
  }
  func synchronizeStore() async {
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
        if existing.isStarted {
          await existing.scenePhaseChanged(.active)
        } else {
          await existing.start()
        }
      } else if existing.isStarted {
        await existing.scenePhaseChanged(.background)
      }
      return
    }
    compositionGeneration &+= 1
    let generation = compositionGeneration
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
        api = APIClient(
          endpoint: profile.endpoint, transport: ScenarioConsoleTransport(storeScenario))
        events = ScenarioEventSource(storeScenario)
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
    store = next
    #if DEBUG
      if let storeScenario { try? await storeScenario.prepare(next, repository: consoleRepository) }
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

  func scenePhaseChanged(_ phase: ScenePhase) async {
    switch phase {
    case .active: await store?.scenePhaseChanged(.active)
    case .background: await store?.scenePhaseChanged(.background)
    case .inactive: break
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
    }
  }

  enum LaunchError: Error {
    case missingValue(String)
    case unknownScenario(String)
    case unknownAppearance(String)
  }
#endif
