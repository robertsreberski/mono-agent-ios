// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI

@MainActor @Observable final class ReplyMessageGallery {
  struct Loaded {
    let part: ReplyAttachmentPart
    let image: UIImage
    let lease: ReplyFileLease
  }
  var loaded: [String: Loaded] = [:]
  var loading: Set<String> = []
  var failures: [String: String] = [:]
  var openID: String?
  private var generation = 0
  private var tasks: [String: Task<Void, Never>] = [:]
  func request(_ part: ReplyAttachmentPart, message: WebMessage, store: ConsoleStore) {
    guard tasks[part.id] == nil else { return }
    let generation = generation
    tasks[part.id] = Task {
      await load(part, message: message, store: store)
      if self.generation == generation { tasks[part.id] = nil }
    }
  }

  func load(_ part: ReplyAttachmentPart, message: WebMessage, store: ConsoleStore) async {
    guard !loading.contains(part.id) else { return }
    if let existing = loaded[part.id] {
      if existing.part.hasSameFile(as: part) { return }
      loaded[part.id] = nil
      await store.releaseReplyFile(existing.lease)
    }
    let generation = generation
    loading.insert(part.id)
    failures[part.id] = nil
    defer { if self.generation == generation { loading.remove(part.id) } }
    var held: ReplyFileLease?
    do {
      let lease = try await store.downloadReplyAttachment(
        threadID: message.threadId, messageID: message.id, partID: part.id)
      held = lease
      let image = try await store.decodeReplyImage(lease)
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      loaded[part.id] = Loaded(part: part, image: UIImage(cgImage: image), lease: lease)
    } catch {
      if let held { await store.releaseReplyFile(held) }
      if !(error is CancellationError) {
        failures[part.id] =
          (error as? ReplyDownloadFailure)?.message ?? "This image could not be displayed."
      }
    }
  }
  func clear(store: ConsoleStore) {
    generation += 1
    for task in tasks.values { task.cancel() }
    tasks = [:]
    loading = []
    let leases = loaded.values.map(\.lease)
    loaded = [:]
    failures = [:]
    Task { for lease in leases { await store.releaseReplyFile(lease) } }
  }
  func images(in message: WebMessage) -> [ReplyGalleryImage] {
    message.parts.compactMap { part in
      guard case .attachment(let part) = part, let value = loaded[part.id],
        value.part.hasSameFile(as: part)
      else { return nil }
      return ReplyGalleryImage(
        id: part.id, name: part.name, image: value.image, url: value.lease.url)
    }
  }
}

struct ReplyImagesView: View {
  let parts: [ReplyAttachmentPart]
  let message: WebMessage
  let store: ConsoleStore
  let gallery: ReplyMessageGallery
  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 6) {
        ForEach(parts, id: \.id) { part in
          VStack(alignment: .leading, spacing: 4) {
            if let error = gallery.failures[part.id] {
              Text(error).webFont(.replyMeta).foregroundStyle(WebColor.textMuted.color)
              ReplyAttachmentView(part: part, message: message, store: store)
            } else {
              ReplyImageTile(
                name: part.name, size: ReplyFileCard.formatBytes(part.sizeBytes),
                image: gallery.loaded[part.id]?.image,
                phase: gallery.loading.contains(part.id) || store.effectiveDataMode != .lean
                  ? .loading : .load
              ) {
                if gallery.loaded[part.id] != nil {
                  gallery.openID = part.id
                } else {
                  Task { await gallery.load(part, message: message, store: store) }
                }
              }.accessibilityIdentifier("reply-image-" + part.id)
            }
          }.frame(width: 190 * 4 / 3)
            .onAppear {
              if store.effectiveDataMode != .lean {
                gallery.request(part, message: message, store: store)
              }
            }
            .onChange(of: ReplyImageIdentity(part: part)) {
              if store.effectiveDataMode != .lean {
                gallery.request(part, message: message, store: store)
              }
            }
        }
      }
    }.accessibilityIdentifier("reply-image-row")
  }
}

private struct ReplyImageIdentity: Equatable {
  let part: ReplyAttachmentPart
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.part.hasSameFile(as: rhs.part) }
}
