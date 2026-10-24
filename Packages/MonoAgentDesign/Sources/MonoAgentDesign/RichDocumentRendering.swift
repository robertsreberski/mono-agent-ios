// SPDX-License-Identifier: GPL-3.0-only
import Observation

/// Leading + trailing throttle owned by the view lifetime, not the changing source key.
/// An in-flight parse may publish if newer than the displayed document; new tokens only
/// replace the pending request. Continuous publications therefore cannot cancel every result.
@MainActor @Observable final class RichDocumentRendering {
  private(set) var document: RichDocument?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pending: Request?
  @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
  private struct Request {
    let source: String
    let key: String
    let streaming: Bool
  }
  func submit(source: String, key: String, streaming: Bool) {
    pending = Request(source: source, key: key, streaming: streaming)
    wake?.yield(())
  }
  func run(
    source: String, key: String, streaming: Bool,
    parse: @MainActor (String) async throws -> RichDocument = {
      try await RichDocumentParser.shared.parse($0)
    },
    pause: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async {
    generation += 1
    let lifetime = generation
    let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    wake = channel.continuation
    defer {
      if generation == lifetime { wake = nil }
      channel.continuation.finish()
    }
    submit(source: source, key: key, streaming: streaming)
    do {
      for await _ in channel.stream {
        try Task.checkCancellation()
        guard generation == lifetime else { return }
        guard let request = pending else { continue }
        pending = nil
        let parsed: RichDocument
        if let cached = RichRenderingCache.document(key: request.key) {
          parsed = cached
        } else {
          parsed = try await parse(request.source)
        }
        try Task.checkCancellation()
        guard generation == lifetime else { return }
        RichRenderingCache.insert(parsed, key: request.key, bytes: request.source.utf8.count)
        document = parsed
        // Throttle after publication, with a fixed maximum wait independent of new tokens.
        if request.streaming { try await pause(.milliseconds(83)) }
      }
    } catch {
      // Lifetime cancellation must not publish into a disappeared row.
    }
  }
}
