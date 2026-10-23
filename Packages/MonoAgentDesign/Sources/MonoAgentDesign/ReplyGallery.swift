// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

public struct ReplyImageTile: View {
  public enum Phase { case loading, load, error, expired }
  let name: String
  let size: String
  let image: UIImage?
  let phase: Phase
  let action: () -> Void
  public init(
    name: String, size: String, image: UIImage?, phase: Phase = .loading,
    action: @escaping () -> Void
  ) {
    self.name = name
    self.size = size
    self.image = image
    self.phase = phase
    self.action = action
  }
  public var body: some View {
    Button(action: action) {
      ZStack {
        WebColor.surfaceSubtle.color
        if let image {
          Image(uiImage: image).resizable().scaledToFill()
        } else if phase == .loading {
          ProgressView().accessibilityLabel("Loading " + name)
        } else {
          VStack(spacing: 4) {
            Text(
              phase == .load ? "Load" : phase == .expired ? "Image expired" : "Image unavailable"
            )
            .webFont(.restartCopy)
            Text(phase == .load ? size : "Tap to retry").webFont(.askContext)
          }.foregroundStyle(WebColor.textMuted.color)
        }
      }.frame(width: 190 * 4 / 3, height: 190).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(WebColor.line.color) }
    }.buttonStyle(.plain).disabled(image == nil && phase == .loading)
      .accessibilityLabel((image == nil ? phase == .load ? "Load " : "Loading " : "View ") + name)
  }
}

public struct ReplyGalleryImage: Identifiable {
  public let id: String
  public let name: String
  public let image: UIImage
  public let url: URL
  public init(id: String, name: String, image: UIImage, url: URL) {
    self.id = id
    self.name = name
    self.image = image
    self.url = url
  }
}

/// Value-driven lightbox. Swipe paging, bounded native magnification and ShareLink use local bytes only.
public struct ReplyLightbox: View {
  let images: [ReplyGalleryImage]
  @Binding var selected: String
  let close: () -> Void
  public init(images: [ReplyGalleryImage], selected: Binding<String>, close: @escaping () -> Void) {
    self.images = images
    _selected = selected
    self.close = close
  }
  private var current: ReplyGalleryImage? { images.first { $0.id == selected } }
  private var index: Int { images.firstIndex { $0.id == selected } ?? 0 }
  public var body: some View {
    VStack(spacing: 12) {
      if let current {
        ZoomableReplyImage(image: current.image, name: current.name, step: step)
          .id(current.id)
      }
      HStack(spacing: 6) {
        if images.count > 1 {
          control("Previous image", "chevron.left") { step(-1) }
        }
        Text(current?.name ?? "Image").webFont(.replyFailure).lineLimit(1)
        if images.count > 1 {
          Text("\(index + 1) / \(images.count)").webFont(.contextTrigger)
          control("Next image", "chevron.right") { step(1) }
        }
        if let current {
          ShareLink(item: current.url) {
            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
          }.accessibilityLabel("Share " + current.name)
        }
        control("Close image", "xmark", action: close)
      }.foregroundStyle(WebColor.text.color).padding(.horizontal, 8).padding(.vertical, 6)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 11), opaqueFill: WebColor.surface.color)
    }.padding(12).background(
      Color(red: 7 / 255, green: 10 / 255, blue: 8 / 255).opacity(0.94).ignoresSafeArea()
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reply-lightbox")
    .accessibilityAction(.escape, close)
  }
  private func step(_ delta: Int) {
    guard !images.isEmpty else { return }
    selected = images[(index + delta + images.count) % images.count].id
  }
  private func control(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View
  {
    Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
      .buttonStyle(.plain).accessibilityLabel(label)
  }
}

private struct ZoomableReplyImage: View {
  let image: UIImage
  let name: String
  let step: (Int) -> Void
  @State private var scale: CGFloat = 1
  @State private var baseline: CGFloat = 1
  @State private var offset = CGSize.zero
  @State private var dragStart = CGSize.zero
  var body: some View {
    GeometryReader { geometry in
      Image(uiImage: image).resizable().scaledToFit()
        .frame(width: geometry.size.width, height: geometry.size.height)
        .scaleEffect(scale).offset(offset)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped().contentShape(Rectangle())
        .gesture(
          MagnifyGesture().onChanged { value in
            scale = min(5, max(1, baseline * value.magnification))
            if scale == 1 {
              offset = .zero
              dragStart = .zero
            }
          }.onEnded { _ in baseline = scale }
        )
        .simultaneousGesture(
          DragGesture().onChanged { value in
            guard scale > 1 else { return }
            let x = geometry.size.width * (scale - 1) / 2
            let y = geometry.size.height * (scale - 1) / 2
            offset = CGSize(
              width: min(x, max(-x, dragStart.width + value.translation.width)),
              height: min(y, max(-y, dragStart.height + value.translation.height)))
          }.onEnded { value in
            if scale <= 1.01, abs(value.translation.width) > 50,
              abs(value.translation.width) > abs(value.translation.height)
            {
              step(value.translation.width < 0 ? 1 : -1)
            } else {
              dragStart = offset
            }
          }
        )
        .onTapGesture(count: 2) {
          scale = 1
          baseline = 1
          offset = .zero
          dragStart = .zero
        }
        .accessibilityElement().accessibilityLabel(name)
        .accessibilityValue("Zoom \(Int(scale * 100)) percent")
        .accessibilityIdentifier("reply-image-zoom")
        .accessibilityAdjustableAction { direction in
          scale = direction == .increment ? min(5, scale + 0.5) : max(1, scale - 0.5)
          baseline = scale
          if scale == 1 {
            offset = .zero
            dragStart = .zero
          }
        }
    }
  }
}

#if DEBUG
  #Preview("Image states") {
    DesignPreviewMatrix {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ReplyImageTile(name: "Sample image", size: "128 KiB", image: nil, phase: .load) {}
          ReplyImageTile(name: "Sample image", size: "128 KiB", image: nil) {}
          ReplyImageTile(name: "Sample image", size: "128 KiB", image: nil, phase: .expired) {}
        }
      }
    }
  }
#endif
