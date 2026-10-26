// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import MonoAgentDesign
import SwiftUI
import Testing

@testable import MonoAgent

/// Jump to latest overlays the dock without reserving space: below the dock's top edge only its
/// visible circle is interactive, and above the edge it reaches the 44 pt minimum target.
struct JumpHitShapeTests {
  private let target = DesignMetrics.minimumHitTarget
  private let diameter = WebMetrics.tile
  private var dockEdge: CGFloat { TranscriptJumpButton.reach + TranscriptJumpButton.aboveDock }
  private var path: Path {
    JumpHitShape(diameter: diameter, dockEdge: dockEdge)
      .path(in: CGRect(x: 0, y: 0, width: target, height: target))
  }

  @Test func mountKeepsTheDesignedStraddle() {
    #expect(TranscriptJumpButton.reach + diameter == target)
    // The circle's upper 16 pt are above the dock edge and its lower 20 pt overlap the dock.
    let circleTop = TranscriptJumpButton.mountOffset + TranscriptJumpButton.reach
    #expect(circleTop == -16)
    #expect(circleTop + diameter == 20)
    #expect(TranscriptJumpButton.mountOffset == -24)
  }

  @Test func coversTheVisibleCircle() {
    let centre = CGPoint(x: target / 2, y: target - diameter / 2)
    #expect(path.contains(centre))
    // Its lowest point overlaps the dock row: still the jump (the visible circle).
    #expect(path.contains(CGPoint(x: target / 2, y: target - 1)))
    #expect(path.contains(CGPoint(x: target / 2 - diameter / 2 + 1, y: centre.y)))
    #expect(path.contains(CGPoint(x: target / 2 + diameter / 2 - 1, y: centre.y)))
  }

  @Test func reachesFullWidthOnlyAboveTheDockEdge() {
    for x in [CGFloat(0.5), target / 2, target - 0.5] {
      #expect(path.contains(CGPoint(x: x, y: 0.5)))
      #expect(path.contains(CGPoint(x: x, y: dockEdge - 0.5)))
    }
    #expect(path.boundingRect.width == target)
    #expect(path.boundingRect.height == target)
  }

  @Test func leavesTheDockBesideTheCircleToItsRows() {
    // Below the edge and outside the circle: the dock row under the corners keeps the tap.
    for point in [
      CGPoint(x: 1, y: dockEdge + 1), CGPoint(x: target - 1, y: dockEdge + 1),
      CGPoint(x: 1, y: target - 1), CGPoint(x: target - 1, y: target - 1),
      CGPoint(x: 4, y: target - 6), CGPoint(x: target - 4, y: target - 6),
    ] {
      #expect(!path.contains(point), "\(point) is beside the circle, inside the dock")
    }
  }
}
