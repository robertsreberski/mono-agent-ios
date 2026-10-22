// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Preserve another writer's edits; a known version is required to delete its draft.
enum AuthoredMerge {
  static func rebase(
    _ local: AuthoredRecord, onto disk: AuthoredRecord, baseline: AuthoredRecord,
    removedVersions: Set<UUID>
  ) -> AuthoredRecord {
    var result = local
    result.revision = max(local.revision, disk.revision) + 1
    if local.dataMode == baseline.dataMode { result.dataMode = disk.dataMode }
    var drafts = Dictionary(
      disk.drafts.filter { !removedVersions.contains($0.version) }.map { ($0.key, $0) },
      uniquingKeysWith: { first, _ in first })
    for draft in local.drafts {
      guard let other = drafts[draft.key] else {
        drafts[draft.key] = draft
        continue
      }
      let oldVersion = baseline.drafts.first { $0.key == draft.key }?.version
      if other.version == draft.version || other.version == oldVersion
        || (draft.version != oldVersion && draft.updatedAt > other.updatedAt)
      {
        drafts[draft.key] = draft
      }
    }
    result.drafts = Array(drafts.values.sorted { $0.updatedAt < $1.updatedAt }.suffix(40))
    var seen: [String: Int] = [:]
    var order: [String] = []
    for marker in disk.seen + local.seen {
      seen[marker.id] = max(seen[marker.id] ?? 0, marker.revision)
      order.removeAll { $0 == marker.id }
      order.append(marker.id)
    }
    result.seen = order.suffix(200).map { .init(id: $0, revision: seen[$0] ?? 0) }
    return result
  }
}
