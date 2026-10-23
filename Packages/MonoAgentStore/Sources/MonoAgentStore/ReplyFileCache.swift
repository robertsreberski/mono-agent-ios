// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

public struct ReplyFileLease: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let url: URL
}

/// App-owned, backup-excluded bytes only. No DTO, capability or network URL is written.
/// Leases prevent eviction while QuickLook, Share or Files is using a local file.
public actor ReplyFileCache {
  public static let maximumFileBytes = 32 * 1024 * 1024
  private let directory: URL
  private let maximumBytes: Int
  private let maximumCount: Int
  private let retention: TimeInterval
  private var leases: [UUID: URL] = [:]

  public init(
    directory: URL, maximumBytes: Int = 64 * 1024 * 1024, maximumCount: Int = 24,
    retention: TimeInterval = 86_400
  ) {
    self.directory = directory.resolvingSymlinksInPath()
    self.maximumBytes = maximumBytes
    self.maximumCount = maximumCount
    self.retention = retention
  }
  static func live(namespace: String) -> ReplyFileCache {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MonoAgent/ReplyFiles", isDirectory: true)
      .appendingPathComponent(digest(namespace), isDirectory: true)
    return ReplyFileCache(directory: root)
  }
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func location(key: String, name: String) -> URL {
    let safe = String(name.prefix(120)).map {
      $0.isASCII && ($0.isLetter || $0.isNumber || " .-_".contains($0)) ? $0 : "_"
    }
    return directory.appendingPathComponent(Self.digest(key) + "-" + String(safe))
  }
  public func cached(key: String, name: String, now: Date = .now) throws -> ReplyFileLease? {
    try prune(now: now)
    let url = location(key: key, name: name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    return lease(url)
  }
  public func insert(_ data: Data, key: String, name: String, now: Date = .now) throws
    -> ReplyFileLease
  {
    guard data.count <= Self.maximumFileBytes, data.count <= maximumBytes, maximumCount > 0 else {
      throw ReplyFileCacheError.full
    }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var root = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
    let url = location(key: key, name: name)
    if let hit = try cached(key: key, name: name, now: now) { return hit }
    try prune(now: now, reservingBytes: data.count, reservingCount: 1)
    try data.write(to: url, options: .atomic)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    return lease(url)
  }
  private func lease(_ url: URL) -> ReplyFileLease {
    let id = UUID()
    leases[id] = url
    return ReplyFileLease(id: id, url: url)
  }
  public func release(_ lease: ReplyFileLease, now: Date = .now) throws {
    leases.removeValue(forKey: lease.id)
    try prune(now: now)
  }
  public func clear() throws {
    for entry in try entries()
    where !leases.values.contains(where: {
      $0.resolvingSymlinksInPath().path == entry.url.resolvingSymlinksInPath().path
    }) {
      try FileManager.default.removeItem(at: entry.url)
    }
  }
  private struct Entry {
    let url: URL
    let bytes: Int
    let date: Date
  }
  private func entries() throws -> [Entry] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    ).compactMap { url in
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
      ])
      guard values.isRegularFile == true else { return nil }
      return Entry(
        url: url, bytes: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast)
    }.sorted { $0.date < $1.date }
  }
  private func prune(now: Date, reservingBytes: Int = 0, reservingCount: Int = 0) throws {
    let files = try entries()
    var count = files.count + reservingCount
    var bytes = files.reduce(reservingBytes) { $0 + $1.bytes }
    for entry in files
    where !leases.values.contains(where: {
      $0.resolvingSymlinksInPath().path == entry.url.resolvingSymlinksInPath().path
    }) {
      if count > maximumCount || bytes > maximumBytes
        || now.timeIntervalSince(entry.date) >= retention
      {
        try FileManager.default.removeItem(at: entry.url)
        count -= 1
        bytes -= entry.bytes
      }
    }
    guard count <= maximumCount, bytes <= maximumBytes else { throw ReplyFileCacheError.full }
  }
}
public enum ReplyFileCacheError: Error, Sendable { case full }
