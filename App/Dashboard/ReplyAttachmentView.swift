// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import QuickLook
import SwiftUI
import UIKit

struct ReplyAttachmentView: View {
  let source: TranscriptFileSource
  init(part: ReplyAttachmentPart, message: WebMessage, store: ConsoleStore) {
    self.source = .reply(part)
    self.message = message
    self.store = store
  }
  init(upload: WebAttachment, message: WebMessage, store: ConsoleStore) {
    self.source = .upload(upload)
    self.message = message
    self.store = store
  }
  let message: WebMessage
  let store: ConsoleStore
  @State private var generation = 0
  @State private var lease: ReplyFileLease?
  @State private var failure: ReplyDownloadFailure?
  @State private var loading = false
  @State private var task: Task<Void, Never>?
  @State private var preview: URL?
  @State private var actions = false
  @State private var presentation: FilePresentation?

  var body: some View {
    content

      .accessibilityIdentifier("reply-file-" + source.id)
      .confirmationDialog(source.name, isPresented: $actions, titleVisibility: .visible) {
        if let lease {
          Button("Preview") { preview = lease.url }
          Button("Share") { presentation = .init(url: lease.url, kind: .share) }
          Button("Save to Files") { presentation = .init(url: lease.url, kind: .save) }
        }
        Button("Cancel", role: .cancel) {}
      }
      .quickLookPreview($preview)
      .sheet(item: $presentation) { item in
        if item.kind == .share {
          FileShareSheet(url: item.url)
        } else {
          FileSaveSheet(url: item.url)
        }
      }
      .onDisappear {
        task?.cancel()
        task = nil
        if let lease { Task { await store.releaseReplyFile(lease) } }
        lease = nil
        loading = false
      }
  }
  @ViewBuilder private var content: some View {
    if case .upload = source {
      Button {
        if lease != nil { actions = true } else { download() }
      } label: {
        AttachmentChip(
          name: source.name, detail: loading ? "Downloading…" : failure?.message ?? "",
          isImage: source.isImage)
      }.buttonStyle(.plain).frame(minHeight: 44)
        .disabled(loading || failure == .unavailable)
        .accessibilityLabel((lease == nil ? "Download " : "Open ") + source.name)
    } else {
      ReplyFileCard(
        name: source.name, mediaType: source.mediaType, sizeBytes: source.sizeBytes, phase: phase,
        status: loading
          ? "Refreshing download access…"
          : failure?.message ?? (phase == .tooLarge ? ReplyDownloadFailure.tooLarge.message : nil)
      ) { if lease != nil { actions = true } else { download() } }
    }
  }
  private var phase: ReplyFileCard.Phase {
    if loading { return .loading }
    if lease != nil { return .ready }
    switch failure {
    case .unavailable, .integrity: return .unavailable
    case .tooLarge: return .tooLarge
    case .expired: return .expired
    case .interrupted, .cacheFull: return .error
    case nil: return source.sizeBytes > ReplyFileCache.maximumFileBytes ? .tooLarge : .available
    }
  }
  private func download() {
    guard !loading else { return }
    loading = true
    failure = nil
    let generation = generation
    task = Task {
      defer { if self.generation == generation { loading = false } }
      do {
        let value = try await source.download(message: message, store: store)
        guard !Task.isCancelled, self.generation == generation else {
          await store.releaseReplyFile(value)
          return
        }
        lease = value
        actions = true
      } catch is CancellationError {
        // Leaving a row is not a failed file.
      } catch {
        if self.generation == generation {
          failure = (error as? ReplyDownloadFailure) ?? ReplyDownloadFailure(error)
        }
      }
    }
  }
}

struct FilePresentation: Identifiable {
  enum Kind { case share, save }
  let id = UUID()
  let url: URL
  let kind: Kind
}
struct FileShareSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct FileSaveSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    UIDocumentPickerViewController(forExporting: [url], asCopy: true)
  }
  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// Value-only adapter shared by reply parts and durable sent uploads. URLs are never used here.
enum TranscriptFileSource: Equatable {
  case reply(ReplyAttachmentPart)
  case upload(WebAttachment)
  var id: String {
    switch self {
    case .reply(let part): part.id
    case .upload(let file): file.id
    }
  }
  var key: String {
    switch self {
    case .reply: "reply:" + id
    case .upload: "upload:" + id
    }
  }
  var name: String {
    switch self {
    case .reply(let part): part.name
    case .upload(let file): file.name
    }
  }
  var mediaType: String {
    switch self {
    case .reply(let part): part.mediaType
    case .upload(let file): file.contentType
    }
  }
  var sizeBytes: Int {
    switch self {
    case .reply(let part): part.sizeBytes
    case .upload(let file): file.sizeBytes
    }
  }
  var isImage: Bool {
    switch self {
    case .reply(let part): part.isReplyImage
    case .upload(let file): file.isUploadedImage
    }
  }
  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.reply(let a), .reply(let b)): a.hasSameFile(as: b)
    case (.upload(let a), .upload(let b)): a.hasSameFile(as: b)
    default: false
    }
  }
  @MainActor func download(message: WebMessage, store: ConsoleStore) async throws -> ReplyFileLease
  {
    switch self {
    case .reply:
      try await store.downloadReplyAttachment(
        threadID: message.threadId, messageID: message.id, partID: id)
    case .upload:
      try await store.downloadMessageAttachment(
        threadID: message.threadId, messageID: message.id, attachmentID: id)
    }
  }
}
