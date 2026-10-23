// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Geometry in the scroll view's coordinate system, including safe-area content insets.
public struct TranscriptScrollMetrics: Sendable, Equatable {
  public var contentHeight: Double
  public var viewportHeight: Double
  public var contentOffset: Double
  public var topInset: Double
  public var bottomInset: Double
  public init(
    contentHeight: Double, viewportHeight: Double, contentOffset: Double,
    topInset: Double = 0, bottomInset: Double = 0
  ) {
    self.contentHeight = contentHeight
    self.viewportHeight = viewportHeight
    self.contentOffset = contentOffset
    self.topInset = topInset
    self.bottomInset = bottomInset
  }
  public var contentFits: Bool { contentHeight + topInset + bottomInset <= viewportHeight + 1 }
  public var distanceFromBottom: Double {
    max(0, contentHeight + bottomInset - contentOffset - viewportHeight)
  }
  public var isAtBottom: Bool { contentFits || distanceFromBottom <= 80 }
}

/// Content that fits always follows. Otherwise only user gestures change follow intent;
/// disclosure/layout writes never pause it.
public struct TranscriptFollowPolicy: Sendable, Equatable {
  public private(set) var following = true
  public private(set) var atBottom = true
  public var paging = false
  public init() {}
  public mutating func update(_ metrics: TranscriptScrollMetrics, userDriven: Bool) {
    atBottom = metrics.isAtBottom
    if metrics.contentFits {
      following = true
    } else if userDriven && !paging {
      following = atBottom
    }
  }
  public var shouldShowJump: Bool { !following && !atBottom && !paging }
  public var shouldFollowWrite: Bool { following && !paging }
  public func shouldScrollAfterWrite(_ metrics: TranscriptScrollMetrics) -> Bool {
    shouldFollowWrite && !metrics.contentFits && metrics.distanceFromBottom > 1
  }
  public mutating func beginPaging() {
    following = false
    paging = true
  }
  public mutating func jump() { following = true }
}
