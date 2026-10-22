// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

public struct SavedConsole: Identifiable, Codable, Sendable, Equatable {
  /// Also the data namespace. An endpoint edit always gets a new UUID.
  public let id: UUID
  public var name: String
  public let endpoint: ConsoleEndpoint
  public var httpAcknowledged: Bool
  public var lastIdentity: ConsoleIdentity?
  public init(
    id: UUID = UUID(), name: String, endpoint: ConsoleEndpoint,
    httpAcknowledged: Bool = false, lastIdentity: ConsoleIdentity? = nil
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.httpAcknowledged = httpAcknowledged
    self.lastIdentity = lastIdentity
  }
}

public struct ProfileSnapshot: Codable, Sendable {
  public var version = 1
  public var consoles: [SavedConsole]
  public var selectedID: UUID?
  public var revision: UInt64
  public init(consoles: [SavedConsole] = [], selectedID: UUID? = nil, revision: UInt64 = 0) {
    self.consoles = consoles
    self.selectedID = selectedID
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey { case version, consoles, selectedID, revision }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    consoles = try container.decode([SavedConsole].self, forKey: .consoles)
    selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
    // Existing v1 profiles predate ordered writes.
    revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
  }
}

public protocol ProfileRepository: Sendable {
  func load() async throws -> ProfileSnapshot
  /// Ignore stale/equal revisions; asynchronous callers may reach storage out of order.
  func save(_ snapshot: ProfileSnapshot) async throws
}

public actor FileProfileRepository: ProfileRepository {
  private let directory: URL
  private var latestRevision: UInt64?
  private var file: URL { directory.appendingPathComponent("profiles-v1.json") }
  public init(directory: URL) { self.directory = directory }

  public func load() throws -> ProfileSnapshot {
    guard FileManager.default.fileExists(atPath: file.path) else { return ProfileSnapshot() }
    let snapshot = try JSONDecoder().decode(ProfileSnapshot.self, from: Data(contentsOf: file))
    guard snapshot.version == 1,
      Set(snapshot.consoles.map(\.id)).count == snapshot.consoles.count
    else { throw RepositoryError.invalidFormat }
    latestRevision = max(latestRevision ?? 0, snapshot.revision)
    return snapshot
  }

  public func save(_ snapshot: ProfileSnapshot) throws {
    if latestRevision == nil, FileManager.default.fileExists(atPath: file.path) {
      _ = try load()
    }
    guard latestRevision.map({ snapshot.revision > $0 }) ?? true else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var directory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let data = try JSONEncoder().encode(snapshot)
    #if os(iOS)
      try data.write(
        to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: file, options: .atomic)
    #endif
    // No suspension between comparison and atomic replacement inside this actor.
    latestRevision = snapshot.revision
  }
}

public enum RepositoryError: Error { case invalidFormat }
