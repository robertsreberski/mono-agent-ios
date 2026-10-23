// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import WebKit

@MainActor
final class McpAppWebView: WKWebView {
  let policy = McpAppPolicy()

  init(configuration: WKWebViewConfiguration) {
    super.init(frame: .zero, configuration: configuration)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use the isolated host factory") }

  override func layoutSubviews() {
    super.layoutSubviews()
    removeDragInteractions(in: self)
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    removeDragInteractions(in: subview)
  }

  private func removeDragInteractions(in view: UIView) {
    for interaction in view.interactions where interaction is UIDragInteraction {
      view.removeInteraction(interaction)
    }
    for child in view.subviews { removeDragInteractions(in: child) }
  }
}
