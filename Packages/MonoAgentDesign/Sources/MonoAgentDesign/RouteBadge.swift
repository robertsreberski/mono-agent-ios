// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// A read-only route signal, never confused with confirmation of a run.
public struct RouteBadge: View {
  private let model: String
  private let effort: String
  private let detail: String
  public init(model: String, effort: String, detail: String) {
    self.model = model
    self.effort = effort
    self.detail = detail
  }
  public var body: some View {
    // Web `.route-badge`: `model · effort` in soft 10 pt text, no fill.
    Text(
      [model, effort.isEmpty ? "—" : effort == "none" ? "off" : effort].joined(separator: " · ")
    )
    .webFont(.rowSubtitle).foregroundStyle(WebColor.textSoft.color).lineLimit(1)
    .accessibilityLabel(detail).help(detail).accessibilityIdentifier("route-badge")
  }
}
#if DEBUG
  #Preview("Route badge") {
    DesignPreviewMatrix {
      RouteBadge(
        model: "sample:large", effort: "high", detail: "Current settings, inherited agent defaults")
    }
  }
#endif
