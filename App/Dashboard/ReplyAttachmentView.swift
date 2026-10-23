// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import QuickLook
import SwiftUI
import UIKit

struct ReplyAttachmentView: View {
  let part: ReplyAttachmentPart
  let message: WebMessage
  let store: ConsoleStore
  @State private var lease: ReplyFileLease?
  @State private var failure: ReplyDownloadFailure?
  @State private var loading = false
  @State private var task: Task<Void, Never>?
  @State private var preview: URL?
  @State private var actions = false
  @State private var presentation: FilePresentation?

  var body: some View {
    ReplyFileCard(
      name: part.name, mediaType: part.mediaType, sizeBytes: part.sizeBytes, phase: phase,
      status: loading
        ? "Refreshing download access…"
        : failure?.message ?? (phase == .tooLarge ? ReplyDownloadFailure.tooLarge.message : nil)
    ) { if lease != nil { actions = true } else { download() } }
    .accessibilityIdentifier("reply-file-" + part.id)
    .confirmationDialog(part.name, isPresented: $actions, titleVisibility: .visible) {
      if let lease {
        Button("Preview") { preview = lease.url }
        Button("Share") { presentation = .init(url: lease.url, kind: .share) }
        Button("Save to Files") { presentation = .init(url: lease.url, kind: .save) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .quickLookPreview($preview)
    .sheet(item: $presentation) { item in
      if item.kind == .share { FileShareSheet(url: item.url) } else { FileSaveSheet(url: item.url) }
    }
    .onDisappear {
      task?.cancel()
      task = nil
      if let lease { Task { await store.releaseReplyFile(lease) } }
      lease = nil
      loading = false
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
    case nil: return part.sizeBytes > ReplyFileCache.maximumFileBytes ? .tooLarge : .available
    }
  }
  private func download() {
    guard !loading else { return }
    loading = true
    failure = nil
    task = Task {
      defer { loading = false }
      do {
        let value = try await store.downloadReplyAttachment(
          threadID: message.threadId, messageID: message.id, partID: part.id)
        guard !Task.isCancelled else {
          await store.releaseReplyFile(value)
          return
        }
        lease = value
        actions = true
      } catch is CancellationError {
        // Leaving a row is not a failed file.
      } catch { failure = (error as? ReplyDownloadFailure) ?? ReplyDownloadFailure(error) }
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
