// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import SwiftUI

struct DashboardRowValue: Equatable {
  let target: AppRoute
  let identifier: String
  let content: ConversationRowContent
  let selected: Bool
  var running = false
  var wakeStatus: String?
}

/// Stable lazy child; unchanged values do not rebuild row content on unrelated Store writes.
struct DashboardRow: View, Equatable {
  let value: DashboardRowValue
  let select: (AppRoute) -> Void
  @Environment(\.consoleTheme) private var theme
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
  var body: some View {
    #if DEBUG
      let _ = PerformanceProbe.body("DashboardRow")
    #endif
    Button {
      select(value.target)
    } label: {
      if value.running {
        let shape = RoundedRectangle(cornerRadius: WebRadius.medium, style: .continuous)
        ConversationRow(value.content).padding(.horizontal, -1)
          .background(theme.palette.accent.mixed(7, with: WebColor.surfaceRaised).color, in: shape)
          .overlay {
            shape.strokeBorder(
              theme.palette.accent.mixed(value.selected ? 45 : 26, with: WebColor.line).color,
              lineWidth: 1)
          }
      } else {
        let shape = RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
          ConversationRow(value.content)
          if let status = value.wakeStatus {
            WakeScheduleStatus(status).padding(.leading, 38).padding(.bottom, 6)
          }
        }
        .background {
          if value.selected {
            shape.fill(WebColor.surfaceRaised.color).webShadow(.small)
              .overlay(shape.strokeBorder(WebColor.line.color, lineWidth: 1))
          }
        }
      }
    }
    .buttonStyle(WebRowButtonStyle())
    .accessibilityAddTraits(value.selected ? .isSelected : [])
    .accessibilityIdentifier(value.identifier)
  }
}

/// Lazy layouts need globally unique identity even when the same thread occurs in two sections.
struct DashboardListID<ID: Hashable>: Hashable {
  let scope: String
  let value: ID
}
struct DashboardListItem<Value, ID: Hashable>: Identifiable {
  let id: DashboardListID<ID>
  let value: Value
}

/// The actual ForEach input shared by running and list sections, with section-scoped IDs.
enum DashboardListProjection {
  static func rows<Value, ID: Hashable>(
    _ values: [Value], id: KeyPath<Value, ID>, scope: String
  ) -> [DashboardListItem<Value, ID>] {
    values.map {
      DashboardListItem(id: DashboardListID(scope: scope, value: $0[keyPath: id]), value: $0)
    }
  }
}
