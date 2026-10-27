// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit

/// Rebase a cache writer after a competing writer committed. No UI or network effects.
public enum CacheMerge {
  public static func prune(_ values: [String: ThreadTombstone], now: Date) -> [String:
    ThreadTombstone]
  {
    Dictionary(
      uniqueKeysWithValues: values.filter {
        now.timeIntervalSince($0.value.removedAt) <= ConsoleBounds.tombstoneAge
      }
      .sorted { $0.value.removedAt > $1.value.removedAt }.prefix(ConsoleBounds.tombstoneCount).map {
        ($0.key, $0.value)
      })
  }
  public static func rebase(
    _ local: CacheRecord, onto disk: CacheRecord, authoritativeAt: [String: Date] = [:]
  ) -> CacheRecord {
    var result = local
    result.bootstrap = local.bootstrap ?? disk.bootstrap
    result.revision = disk.revision + 1
    var snapshots: [String: CachedAutomationOverview] = [:]
    for entry in (disk.automationOverviews ?? []) + (local.automationOverviews ?? []) {
      if let previous = snapshots[entry.sourceID], previous.savedAt > entry.savedAt { continue }
      snapshots[entry.sourceID] = entry
    }
    result.automationOverviews = Array(snapshots.values)
    result.tombstones = disk.tombstones.merging(local.tombstones) { old, new in
      if old.revision != new.revision { return old.revision > new.revision ? old : new }
      if old.origin != new.origin {
        if old.origin == .removed { return old }
        if new.origin == .removed { return new }
      }
      return old.removedAt > new.removedAt ? old : new
    }
    let rows: [(WebThread, Date?)] =
      ((local.bootstrap?.threads ?? []) + (local.bootstrap?.activeThreads?.threads ?? [])).map {
        ($0, nil)
      }
      + local.buckets.flatMap { bucket in bucket.threads.map { ($0, bucket.savedAt) } }
      + local.conversations.map { ($0.thread, $0.savedAt) }
    for (row, fetchedAt) in rows {
      if local.tombstones[row.id] == nil, let removed = result.tombstones[row.id],
        removed.allows(revision: row.revision, fetchedAt: authoritativeAt[row.id] ?? fetchedAt)
      {
        result.tombstones[row.id] = nil
      }
    }
    var entries = Dictionary(
      disk.conversations.map { ($0.thread.id, $0) }, uniquingKeysWith: { first, _ in first })
    for entry in local.conversations {
      guard let old = entries[entry.thread.id] else {
        entries[entry.thread.id] = entry
        continue
      }
      var chosen = entry.savedAt >= old.savedAt ? entry : old
      let other = entry.savedAt >= old.savedAt ? old : entry
      if other.thread.revision > chosen.thread.revision { chosen.thread = other.thread }
      chosen.repairedToolCallIDs.formUnion(other.repairedToolCallIDs)
      chosen.pagedIDs.formUnion(other.pagedIDs)
      for message in other.messages {
        TranscriptMerge.insert(
          message, into: &chosen.messages, repaired: chosen.repairedToolCallIDs)
      }
      entries[entry.thread.id] = chosen
    }
    result.conversations = entries.values.filter { result.tombstones[$0.thread.id] == nil }
    var buckets = Dictionary(
      disk.buckets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    for var bucket in local.buckets {
      if let old = buckets[bucket.key] {
        bucket.threads = bucket.threads.map { row in
          let previous = old.threads.first { $0.id == row.id }
          return previous.map { $0.revision > row.revision ? $0 : row } ?? row
        }
      }
      buckets[bucket.key] = bucket
    }
    result.buckets = Array(buckets.values)
    if var bootstrap = result.bootstrap, let previous = disk.bootstrap {
      bootstrap.agents = bootstrap.agents.map { row in
        let old = previous.agents.first { $0.sourceId == row.sourceId }
        return old.map { $0.updatedAt > row.updatedAt ? $0 : row } ?? row
      }
      bootstrap.threads = bootstrap.threads.map { row in
        let old = previous.threads.first { $0.id == row.id }
        return old.map { $0.revision > row.revision ? $0 : row } ?? row
      }
      result.bootstrap = bootstrap
    }
    return result
  }
}
