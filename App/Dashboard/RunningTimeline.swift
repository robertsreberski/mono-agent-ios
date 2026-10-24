// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Settled content has no scheduled updates. Only the live leaf reads the event clock.
struct RunningTimeline<Content: View>: View {
  let running: Bool
  @ViewBuilder let content: (Date) -> Content

  var body: some View {
    if running {
      TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
    } else {
      content(.distantPast)
    }
  }
}
