// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import SwiftUI

/// Shared bounded retention survives lazy row recreation. All UI/AttributedString access is main-isolated.
@MainActor enum RichRenderingCache {
  /// <=4 KiB sources parse synchronously, so ordinary prose has its final first layout.
  static let synchronousBytes = 4096
  private final class DocumentBox {
    let value: RichDocument
    init(_ value: RichDocument) { self.value = value }
  }
  private final class AttributedBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
  }
  final class RunKey: NSObject {
    let runs: [RichDocument.Run]
    let em: Double
    let theme: String
    init(_ runs: [RichDocument.Run], em: Double, theme: String) {
      self.runs = runs
      self.em = em
      self.theme = theme
    }
    override var hash: Int {
      var hasher = Hasher()
      hasher.combine(runs)
      hasher.combine(em)
      hasher.combine(theme)
      return hasher.finalize()
    }
    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? RunKey else { return false }
      return runs == other.runs && em == other.em && theme == other.theme
    }
  }
  private static let documents: NSCache<NSString, DocumentBox> = {
    let cache = NSCache<NSString, DocumentBox>()
    cache.countLimit = 256
    cache.totalCostLimit = 8 * 1024 * 1024
    return cache
  }()
  private static let attributedRuns: NSCache<RunKey, AttributedBox> = {
    let cache = NSCache<RunKey, AttributedBox>()
    cache.countLimit = 2048
    cache.totalCostLimit = 4 * 1024 * 1024
    return cache
  }()
  static func key(source: String, identity: String) -> String {
    let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    return identity + ":" + digest
  }
  static func document(key: String) -> RichDocument? {
    documents.object(forKey: key as NSString)?.value
  }
  static func insert(_ document: RichDocument, key: String, bytes: Int) {
    documents.setObject(
      DocumentBox(document), forKey: key as NSString,
      cost: min(bytes, RichDocument.maximumBytes) * 4 + 256)
  }
  static func initial(source: String, key: String) -> RichDocument? {
    if let cached = document(key: key) { return cached }
    guard source.utf8.count <= synchronousBytes else { return nil }
    let parsed = RichDocument.parse(source)
    insert(parsed, key: key, bytes: source.utf8.count)
    return parsed
  }
  static func attributed(_ key: RunKey, build: () -> AttributedString) -> AttributedString {
    if let cached = attributedRuns.object(forKey: key) { return cached.value }
    let value = build()
    attributedRuns.setObject(
      AttributedBox(value), forKey: key,
      cost: key.runs.reduce(64) { $0 + $1.text.utf8.count * 4 + 128 })
    return value
  }
}

/// One serial parser: superseded queued work is dropped before cmark, cancellation is checked
/// throughout traversal and after the bounded, noninterruptible cmark call. No detached tasks.
actor RichDocumentParser {
  static let shared = RichDocumentParser()
  func parse(_ source: String) throws -> RichDocument {
    try Task.checkCancellation()
    let parsed = RichDocument.parse(source, cancelled: { Task.isCancelled })
    try Task.checkCancellation()
    return parsed
  }
}
