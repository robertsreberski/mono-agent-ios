// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@MainActor
private func verifyReplacedRecords(_ verify: (URL, URL) throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = FileConsoleRepository(directory: directory)
  let profile = SavedConsole(
    name: "Flockbox", endpoint: try ConsoleEndpoint("https://console.example.ts.net"))
  let namespace = ConsoleNamespace(profile: profile)
  for revision in 1...2 {
    var cache = CacheRecord()
    cache.revision = UInt64(revision)
    var authored = AuthoredRecord()
    authored.revision = UInt64(revision)
    var journal = JournalRecord()
    journal.revision = UInt64(revision)
    try await repository.saveCache(cache, namespace: namespace)
    try await repository.saveAuthored(authored, namespace: namespace)
    try await repository.saveJournal(journal, namespace: namespace)
    let folder = directory.appendingPathComponent(profile.id.uuidString).appendingPathComponent(
      namespace.identity)
    for name in ["cache", "authored", "journal"] {
      try verify(folder, folder.appendingPathComponent(name + "-v1.json"))
    }
  }
}
@MainActor @Test func replacedConsoleRecordsRetainBackupExclusion() async throws {
  try await verifyReplacedRecords { folder, file in
    let folderValues = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
    let fileValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(folderValues.isExcludedFromBackup == true)
    #expect(fileValues.isExcludedFromBackup == true)
  }
}
#if os(iOS) && !targetEnvironment(simulator)
  // Physical-device-only: CoreSimulator exposes no Data Protection attribute. Not CI coverage.
  @MainActor @Test func physicalDeviceOnlyReplacedConsoleRecordsRetainFirstUnlockProtection()
    async throws
  {
    try await verifyReplacedRecords { _, file in
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      #expect(
        (attributes[.protectionKey] as? FileProtectionType
          ?? (attributes[.protectionKey] as? String).map(FileProtectionType.init(rawValue:)))
          == .completeUntilFirstUserAuthentication)
    }
  }
#endif
