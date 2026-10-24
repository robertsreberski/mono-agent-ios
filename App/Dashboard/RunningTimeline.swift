// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Settled content has no scheduled updates. Only the live leaf reads the event clock.
struct RunningTimeline<Content: View>: View {
  let running: Bool
  var offset: () -> TimeInterval = { 0 }
  #if DEBUG
    @Environment(\.fixtureReferenceDate) private var referenceDate
  #endif
  @ViewBuilder let content: (Date) -> Content

  var body: some View {
    if running {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        #if DEBUG
          content(referenceDate ?? context.date.addingTimeInterval(offset()))
        #else
          content(context.date.addingTimeInterval(offset()))
        #endif
      }
    } else {
      content(.distantPast)
    }
  }
}

#if DEBUG
  extension EnvironmentValues {
    @Entry var fixtureReferenceDate: Date?
  }
#endif
