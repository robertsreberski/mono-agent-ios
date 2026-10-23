// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO

public enum ReplyImageError: Error, Sendable, Equatable { case invalid, dimensions, tooLarge }

/// ImageIO lives on this actor, never MainActor. Eager thumbnail decompression prevents a
/// later SwiftUI draw from decoding untrusted full-resolution bytes on the main thread.
public actor ReplyImageCache {
  public static let maximumSourcePixels = 40_000_000
  public static let maximumSourceDimension = 16_384
  public static let maximumDecodedDimension = 2048
  private struct Entry {
    let image: CGImage
    let bytes: Int
    var used: Date
  }
  private var entries: [String: Entry] = [:]
  public init() {}

  public func image(at url: URL, lean: Bool, now: Date = .now) throws -> CGImage {
    let byteLimit = lean ? 8 * 1024 * 1024 : 32 * 1024 * 1024
    let countLimit = lean ? 8 : 24
    let retention: TimeInterval = lean ? 20 : 60
    entries = entries.filter { now.timeIntervalSince($0.value.used) < retention }
    let key = url.path
    if var hit = entries[key] {
      hit.used = now
      entries[key] = hit
      prune(bytes: byteLimit, count: countLimit)
      return hit.image
    }
    try Task.checkCancellation()
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= ReplyFileCache.maximumFileBytes else { throw ReplyImageError.tooLarge }
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let type = CGImageSourceGetType(source) as String?,
      ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { throw ReplyImageError.invalid }
    try Self.validateDimensions(width: width, height: height)
    let maxDimension = lean ? 1448 : Self.maximumDecodedDimension
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ] as CFDictionary)
    else { throw ReplyImageError.invalid }
    try Task.checkCancellation()
    let bytes = image.bytesPerRow * image.height
    guard bytes <= byteLimit else { throw ReplyImageError.tooLarge }
    entries[key] = Entry(image: image, bytes: bytes, used: now)
    prune(bytes: byteLimit, count: countLimit)
    return image
  }
  public nonisolated static func validateDimensions(width: Int, height: Int) throws {
    guard width > 0, height > 0, width <= maximumSourceDimension, height <= maximumSourceDimension,
      width <= maximumSourcePixels / height
    else { throw ReplyImageError.dimensions }
  }
  private func prune(bytes: Int, count: Int) {
    var total = entries.values.reduce(0) { $0 + $1.bytes }
    for key in entries.keys.sorted(by: { entries[$0]!.used < entries[$1]!.used }) {
      guard total > bytes || entries.count > count else { break }
      total -= entries.removeValue(forKey: key)!.bytes
    }
  }
  public func clear() { entries.removeAll() }
  public var retainedBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
  public var retainedCount: Int { entries.count }
}
