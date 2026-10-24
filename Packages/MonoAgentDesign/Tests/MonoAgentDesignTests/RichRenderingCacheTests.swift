// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentDesign

@MainActor struct RichRenderingCacheTests {
  @Test func smallFirstLayoutAndIdentityContentKeys() throws {
    let source = "**A fictional answer**"
    let key = RichRenderingCache.key(source: source, identity: "cache-sample")
    #expect(key != RichRenderingCache.key(source: source + "!", identity: "cache-sample"))
    #expect(key != RichRenderingCache.key(source: source, identity: "another-sample"))
    let first = try #require(RichRenderingCache.initial(source: source, key: key))
    #expect(first.blocks.flatMap(\.runs).contains { $0.bold })
    #expect(RichRenderingCache.document(key: key) == first)
    let large = String(repeating: "sample ", count: 1000)
    #expect(
      RichRenderingCache.initial(
        source: large, key: RichRenderingCache.key(source: large, identity: "large")) == nil)
  }
  @Test func attributedRunsReuseAndStyleChangesSeparateEntries() {
    let runs = [RichDocument.Run(text: "cache-only-sample")]
    var builds = 0
    for _ in 0..<2 {
      _ = RichRenderingCache.attributed(.init(runs, em: 13.5, theme: "ocean")) {
        builds += 1
        return AttributedString("rendered")
      }
    }
    #expect(builds == 1)
    _ = RichRenderingCache.attributed(.init(runs, em: 20, theme: "ocean")) {
      builds += 1
      return AttributedString("larger")
    }
    #expect(builds == 2)
  }
  @Test func cancelledQueuedParseDoesNotReturnAStaleResult() async {
    let task = Task {
      await Task.yield()
      return try await RichDocumentParser.shared.parse("A superseded sample")
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled parse must not publish")
    } catch { #expect(error is CancellationError) }
    #expect(RichDocument.parse("A sample", cancelled: { true }).blocks.isEmpty)
  }
}
