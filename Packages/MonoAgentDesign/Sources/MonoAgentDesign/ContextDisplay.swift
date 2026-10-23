// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

public struct ContextDisplayContent: Sendable, Equatable {
  public struct Row: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) {
      self.label = label
      self.value = value
    }
  }
  public var badge: String
  public var figure: String
  public var status: String
  public var percent: Double?
  public var note: String?
  public var rows: [Row]
  public init(
    badge: String, figure: String, status: String, percent: Double? = nil, note: String? = nil,
    rows: [Row] = []
  ) {
    self.badge = badge
    self.figure = figure
    self.status = status
    self.percent = percent
    self.note = note
    self.rows = rows
  }
}

/// Value-only context/cost disclosure. May be placed in a header, toolbar popover or composer.
/// Unknown values arrive as words, never as an invented zero-width progress measurement.
public struct ContextDisplay: View {
  private let content: ContextDisplayContent
  @Binding private var expanded: Bool
  public init(_ content: ContextDisplayContent, expanded: Binding<Bool>) {
    self.content = content
    _expanded = expanded
  }
  public var body: some View {
    ContentDisclosure("context-display", expanded: $expanded) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Text(content.figure).designFont(.headline).textSelection(.enabled)
        Text(content.status).designFont(.caption).foregroundStyle(.secondary)
        if let percent = content.percent, percent.isFinite {
          ProgressView(value: min(100, max(0, percent)), total: 100)
            .accessibilityLabel("Context window used")
            .accessibilityValue(content.figure + ", " + content.badge)
        }
        if let note = content.note {
          Text(note).designFont(.supporting).foregroundStyle(.secondary)
        }
        ForEach(content.rows) { row in
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
              Text(row.label)
              Spacer()
              Text(row.value).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
              Text(row.label)
              Text(row.value).monospacedDigit()
            }
          }.designFont(.supporting).accessibilityElement(children: .combine)
        }
      }.padding(.top, DesignSpacing.sm)
    } label: {
      Label("Context · " + content.badge, systemImage: "chart.pie")
        .designFont(.supporting)
        .accessibilityLabel("Context usage: " + content.figure + ". " + content.status)
    }
  }
}
#if DEBUG
  #Preview("Context and cost") {
    DesignPreviewMatrix {
      ContextDisplay(
        .init(
          badge: "42%", figure: "84k / 200k tokens", status: "Current", percent: 42,
          rows: [
            .init("Input", "24k"), .init("Cached", "60k"), .init("Output", "1.2k"),
            .init("Estimated cost", "Unknown · Known cost $0.12"),
          ]), expanded: .constant(true)
      )
      .contentSurface()
    }
  }
#endif
