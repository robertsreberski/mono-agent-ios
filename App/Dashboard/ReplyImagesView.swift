// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI

@MainActor @Observable final class ReplyMessageGallery {
  struct Loaded {
    let part: TranscriptFileSource
    let image: UIImage
    let lease: ReplyFileLease
  }
  var loaded: [String: Loaded] = [:]
  var loading: Set<String> = []
  var failures: [String: String] = [:]
  var openID: String?
  private var generation = 0
  private var tasks: [String: Task<Void, Never>] = [:]
  func request(_ part: TranscriptFileSource, message: WebMessage, store: ConsoleStore) {
    guard tasks[part.key] == nil else { return }
    let generation = generation
    tasks[part.key] = Task {
      await load(part, message: message, store: store)
      if self.generation == generation { tasks[part.key] = nil }
    }
  }

  func load(_ part: TranscriptFileSource, message: WebMessage, store: ConsoleStore) async {
    guard !loading.contains(part.key) else { return }
    if let existing = loaded[part.key] {
      if existing.part == part { return }
      loaded[part.key] = nil
      await store.releaseReplyFile(existing.lease)
    }
    let generation = generation
    loading.insert(part.key)
    failures[part.key] = nil
    defer { if self.generation == generation { loading.remove(part.key) } }
    var held: ReplyFileLease?
    do {
      let lease = try await part.download(message: message, store: store)
      held = lease
      let image = try await store.decodeReplyImage(lease)
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      loaded[part.key] = Loaded(part: part, image: UIImage(cgImage: image), lease: lease)
    } catch {
      if let held { await store.releaseReplyFile(held) }
      if !(error is CancellationError), self.generation == generation {
        failures[part.key] =
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
    let files =
      message.parts.compactMap { part -> TranscriptFileSource? in
        if case .attachment(let value) = part { return .reply(value) }
        return nil
      } + message.attachments.map(TranscriptFileSource.upload)
    return files.compactMap { part in
      guard let value = loaded[part.key], value.part == part else { return nil }
      return ReplyGalleryImage(
        id: part.key, name: part.name, image: value.image, url: value.lease.url)
    }
  }
}

struct ReplyImagesView: View {
  let parts: [TranscriptFileSource]
  init(
    parts: [ReplyAttachmentPart], message: WebMessage, store: ConsoleStore,
    gallery: ReplyMessageGallery
  ) {
    self.parts = parts.map(TranscriptFileSource.reply)
    self.message = message
    self.store = store
    self.gallery = gallery
  }
  init(
    uploads: [WebAttachment], message: WebMessage, store: ConsoleStore, gallery: ReplyMessageGallery
  ) {
    self.parts = uploads.map(TranscriptFileSource.upload)
    self.message = message
    self.store = store
    self.gallery = gallery
  }
  let message: WebMessage
  let store: ConsoleStore
  let gallery: ReplyMessageGallery
  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 6) {
        ForEach(parts, id: \.key) { part in
          VStack(alignment: .leading, spacing: 4) {
            if let error = gallery.failures[part.key] {
              Text(error).webFont(.replyMeta).foregroundStyle(WebColor.textMuted.color)
              if case .reply(let value) = part {
                ReplyAttachmentView(part: value, message: message, store: store)
              } else if case .upload(let value) = part {
                ReplyAttachmentView(upload: value, message: message, store: store)
              }
            } else {
              ReplyImageTile(
                name: part.name, size: ReplyFileCard.formatBytes(part.sizeBytes),
                image: gallery.loaded[part.key]?.image,
                phase: gallery.loading.contains(part.key) || store.effectiveDataMode != .lean
                  ? .loading : .load
              ) {
                if gallery.loaded[part.key] != nil {
                  gallery.openID = part.key
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
            .onChange(of: part) {
              if store.effectiveDataMode != .lean {
                gallery.request(part, message: message, store: store)
              }
            }
        }
      }
    }.accessibilityIdentifier("reply-image-row")
  }
}
