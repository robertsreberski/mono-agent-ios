// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import UniformTypeIdentifiers

/// Prepares picked files for `ConsoleStore.stageUploads` (web `attachment-adapter.ts`).
///
/// Picked bytes are copied into a private temporary folder so the upload reads a stable file
/// with a known size; the copy is deleted once staging finishes or fails. Nothing here is
/// persisted, and staged uploads are never restored after relaunch (Store README).
enum AttachmentAdapter {
  static var folder: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerUploads", isDirectory: true)
  }

  static func contentType(forName name: String, fallback: UTType? = nil) -> String {
    let ext = (name as NSString).pathExtension
    return UTType(filenameExtension: ext)?.preferredMIMEType ?? fallback?.preferredMIMEType
      ?? "application/octet-stream"
  }

  /// Copies a security-scoped or transferable file into the private upload folder.
  static func stage(copyOf source: URL, name: String? = nil) throws -> UploadFile {
    let accessing = source.startAccessingSecurityScopedResource()
    defer { if accessing { source.stopAccessingSecurityScopedResource() } }
    let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = sanitized(name ?? source.lastPathComponent)
    let destination = directory.appendingPathComponent(fileName)
    try FileManager.default.copyItem(at: source, to: destination)
    return try file(at: destination, name: fileName)
  }

  /// Writes in-memory bytes (camera capture, photo library data) to the private upload folder.
  static func stage(data: Data, name: String) throws -> UploadFile {
    let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = sanitized(name)
    let destination = directory.appendingPathComponent(fileName)
    try data.write(to: destination, options: [.atomic, .completeFileProtection])
    return try file(at: destination, name: fileName)
  }

  static func file(at url: URL, name: String) throws -> UploadFile {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return UploadFile(
      url: url, name: name, contentType: contentType(forName: name), sizeBytes: size)
  }

  static func discard(_ files: [UploadFile]) {
    for file in files {
      try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }
  }

  static func sanitized(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(
      in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(120))
  }

  static func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  /// The server limits from bootstrap, intersected with the client hard caps in Kit.
  static func effective(_ limits: UploadLimits) -> UploadLimits {
    UploadLimits(
      maxFileBytes: min(20 * 1024 * 1024, limits.maxFileBytes),
      maxFilesPerTurn: min(10, limits.maxFilesPerTurn),
      maxTurnBytes: min(64 * 1024 * 1024, limits.maxTurnBytes), accept: limits.accept)
  }

  /// Why a pick cannot be staged, in the operator's terms; `nil` when it fits the limits.
  static func problem(
    _ files: [UploadFile], limits: UploadLimits, existing: [WebAttachment], uploading: Int = 0
  ) -> String? {
    let limits = effective(limits)
    if existing.count + uploading + files.count > limits.maxFilesPerTurn {
      return "Up to \(limits.maxFilesPerTurn) files per message."
    }
    for file in files {
      if file.sizeBytes > limits.maxFileBytes {
        return
          "\(file.name) is \(byteCount(file.sizeBytes)); the limit is \(byteCount(limits.maxFileBytes)) per file."
      }
      if !accepts(file.contentType, limits.accept) {
        return "\(file.name) is not an accepted file type (\(file.contentType))."
      }
    }
    let total = (existing.map(\.sizeBytes) + files.map(\.sizeBytes)).reduce(0, +)
    if total > limits.maxTurnBytes {
      return
        "These files total \(byteCount(total)); the limit is \(byteCount(limits.maxTurnBytes)) per message."
    }
    return nil
  }

  static func accepts(_ contentType: String, _ accept: [String]) -> Bool {
    accept.contains {
      $0 == contentType || $0 == "*/*"
        || ($0.hasSuffix("/*") && contentType.hasPrefix($0.dropLast()))
    }
  }

  /// The importer's allowed types from the server's accept list.
  static func importTypes(_ accept: [String]) -> [UTType] {
    let types = accept.compactMap { value -> UTType? in
      if value == "*/*" { return .item }
      if value.hasSuffix("/*") {
        switch value {
        case "image/*": return .image
        case "text/*": return .text
        case "audio/*": return .audio
        case "video/*": return .movie
        default: return .item
        }
      }
      return UTType(mimeType: value)
    }
    return types.isEmpty ? [.item] : types
  }

  static func message(for error: any Error) -> String {
    switch error {
    case UploadValidationError.type: "That file type is not accepted by this console."
    case UploadValidationError.size: "A file is larger than the console allows."
    case UploadValidationError.count: "Too many files for one message."
    case UploadValidationError.turnSize: "These files are larger than one message allows."
    case UploadValidationError.changedFile: "A file changed while it was uploading. Try again."
    case is CancellationError: "Upload cancelled."
    default: "Upload failed. Check the connection and try again."
    }
  }
}
