// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MonoAgentStore

struct ReplyImageCacheTests {
  @Test func sourceDimensionsRejectBombsAndInvalidSizes() throws {
    for (width, height) in [(0, 1), (-1, 10), (16_385, 1), (10_000, 10_000), (Int.max, Int.max)] {
      #expect(throws: ReplyImageError.dimensions) {
        try ReplyImageCache.validateDimensions(width: width, height: height)
      }
    }
    try ReplyImageCache.validateDimensions(width: 4096, height: 4096)
  }
  private func imageFile(_ directory: URL, index: Int, width: Int = 2560, height: Int = 1920) throws
    -> URL
  {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("image-\(index).png")
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
  }
  @Test func decodeIsDownsampledAndMemoryRetentionIsBoundedAndCleared() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReplyImageCache()
    let now = Date()
    for index in 0..<10 {
      let url = try imageFile(directory, index: index)
      let image = try await cache.image(
        at: url, lean: true, now: now.addingTimeInterval(Double(index)))
      #expect(image.width <= 1448 && image.height <= 1448)
      #expect(await cache.retainedBytes <= 8 * 1024 * 1024)
      #expect(await cache.retainedCount <= 8)
    }
    let url = try imageFile(directory, index: 11)
    _ = try await cache.image(at: url, lean: false, now: now.addingTimeInterval(100))
    #expect(await cache.retainedCount == 1)
    await cache.clear()
    #expect(await cache.retainedBytes == 0)
    try Data("not an image".utf8).write(to: url)
    await #expect(throws: ReplyImageError.invalid) { try await cache.image(at: url, lean: false) }
  }
}
