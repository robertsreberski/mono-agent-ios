// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

public struct ReplyFileCard: View {
  public enum Phase: Equatable, Sendable {
    case available, loading, ready, unavailable, expired, tooLarge, error
  }
  let name: String
  let mediaType: String
  let sizeBytes: Int
  let phase: Phase
  let status: String?
  let action: () -> Void
  @Environment(\.consoleTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(
    name: String, mediaType: String, sizeBytes: Int, phase: Phase = .available,
    status: String? = nil, action: @escaping () -> Void
  ) {
    self.name = name
    self.mediaType = mediaType
    self.sizeBytes = sizeBytes
    self.phase = phase
    self.status = status
    self.action = action
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !typeSize.isAccessibilitySize {
        HStack(spacing: 10) {
          icon
          copy
          button.fixedSize()
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 10) {
            icon
            copy
          }
          button
        }
      }
      if let status, !status.isEmpty {
        Text(status).webFont(.replyMeta)
          .fontWeight(phase == .unavailable ? .semibold : .regular)
          .foregroundStyle(
            phase == .unavailable || phase == .tooLarge
              ? WebColor.danger.color : WebColor.textMuted.color
          )
          .padding(.leading, typeSize.isAccessibilitySize ? 0 : 40)
          .accessibilityIdentifier("reply-file-status")
      }
    }
    .padding(.vertical, 8).padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    .background(WebColor.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 11))
    .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(WebColor.lineStrong.color) }
    .webShadow(.small)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("File attachment: " + name)
  }
  private var icon: some View {
    Image(systemName: mediaType == "application/pdf" ? "doc.richtext" : "doc")
      .font(.system(size: 16)).frame(width: 30, height: 30)
      .foregroundStyle(theme.palette.accent.color)
      .background(theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)
  }
  private var copy: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name).webFont(.replyName).foregroundStyle(WebColor.text.color)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
      Text(mediaType + " · " + Self.formatBytes(sizeBytes))
        .webFont(.replyMeta).foregroundStyle(WebColor.textMuted.color)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private var button: some View {
    if phase != .unavailable && phase != .tooLarge {
      Button(action: action) {
        Text(phase == .loading ? "Downloading…" : phase == .ready ? "Open" : "Download")
          .webFont(.replyAction).padding(.horizontal, 10).frame(minHeight: 34)
          .foregroundStyle(theme.palette.accent.color)
          .background(theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.palette.accent.color.opacity(0.24))
          }
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(phase == .loading)
        .accessibilityLabel((phase == .ready ? "Open " : "Download ") + name)
        .accessibilityIdentifier("reply-file-action")
    }
  }
  public static func formatBytes(_ size: Int) -> String {
    if size < 1024 { return "\(max(0, size)) B" }
    if size < 1024 * 1024 { return "\(Int((Double(size) / 1024).rounded())) KiB" }
    return String(format: "%.1f MiB", Double(size) / (1024 * 1024))
  }
}

public struct ReplyFailureCard: View {
  let code: String
  let message: String
  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(code).webFont(.replyFailureCode)
      Text(message).webFont(.replyFailure).textSelection(.enabled)
    }.foregroundStyle(WebColor.danger.color)
      .padding(.vertical, 10).padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WebColor.dangerSoft.color, in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9).strokeBorder(WebColor.danger.color.opacity(0.25))
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("reply-failure")
  }
}

#if DEBUG
  #Preview("Reply files") {
    DesignPreviewMatrix {
      VStack {
        ReplyFileCard(name: "report.pdf", mediaType: "application/pdf", sizeBytes: 4096) {}
        ReplyFileCard(
          name: "archive.zip", mediaType: "application/zip", sizeBytes: 1024,
          phase: .unavailable, status: "This file is no longer available."
        ) {}
        ReplyFailureCard(
          code: "artifact_not_found", message: "The requested artifact was not found.")
      }.padding()
    }
  }
#endif
