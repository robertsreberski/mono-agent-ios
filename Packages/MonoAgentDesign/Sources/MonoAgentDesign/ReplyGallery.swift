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

/// Value-driven lightbox. Paging, a native zoom scroll view and native ShareLink use local bytes only.
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
      TabView(selection: $selected) {
        ForEach(images) { item in
          ZoomableReplyImage(image: item.image)
            .accessibilityLabel(item.name).tag(item.id)
        }
      }.tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("reply-lightbox-pages")
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

private struct ZoomableReplyImage: UIViewRepresentable {
  let image: UIImage
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.delegate = context.coordinator
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 5
    scroll.showsVerticalScrollIndicator = false
    scroll.showsHorizontalScrollIndicator = false
    let view = context.coordinator.image
    view.contentMode = .scaleAspectFit
    view.isAccessibilityElement = true
    view.accessibilityTraits = .image
    scroll.addSubview(view)
    return scroll
  }
  func updateUIView(_ scroll: UIScrollView, context: Context) {
    let view = context.coordinator.image
    if view.image !== image {
      scroll.setZoomScale(1, animated: false)
      view.image = image
    }
    view.frame = scroll.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }
  final class Coordinator: NSObject, UIScrollViewDelegate {
    let image = UIImageView()
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
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
