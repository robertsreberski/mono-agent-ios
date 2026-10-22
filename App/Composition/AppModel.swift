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
  private(set) var isReady = false
  let appearance: ColorScheme?
  @ObservationIgnored private var started = false
  #if DEBUG
    @ObservationIgnored private let scenario: Scenario?
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
    registry = ConnectionRegistry(
      repository: FileProfileRepository(directory: directory),
      probe: ConnectionProbe(transport: transport)
    )
  }

  #if DEBUG
    /// Previews share the exact same catalog and fail-closed transport as XCUI screenshots.
    init(scenario: Scenario, appearance: ColorScheme? = nil) {
      self.scenario = scenario
      self.appearance = appearance
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyntheticPreviews", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      registry = ConnectionRegistry(
        repository: FileProfileRepository(directory: directory),
        probe: ConnectionProbe(transport: ScriptedTransport(scenario.steps))
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
    isReady = true
  }
}

#if DEBUG
  struct LaunchConfiguration {
    let scenario: Scenario?
    let appearance: ColorScheme?

    init(arguments: [String]) throws {
      func value(_ flag: String) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
          throw LaunchError.missingValue(flag)
        }
        return arguments[index + 1]
      }
      if let name = try value("--scenario") {
        guard let scenario = Scenario(rawValue: name) else {
          throw LaunchError.unknownScenario(name)
        }
        self.scenario = scenario
      } else {
        scenario = arguments.contains("--reset-test-data") ? .connectionEmpty : nil
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
