// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// Marks where the agent settings screen is in the UIKit hierarchy. `CoveredAccessibility`
/// never hides a view that contains one of these.
struct SettingsAccessibilityAnchor: UIViewRepresentable {
  final class Anchor: UIView {}
  func makeUIView(context: Context) -> Anchor {
    let view = Anchor()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    return view
  }
  func updateUIView(_ view: Anchor, context: Context) {}
}

/// Withdraws the covered context from VoiceOver (and XCUI) while agent settings covers it,
/// without unmounting it: composer, quote, upload, transcript follow and MCP state stay alive.
///
/// SwiftUI's `accessibilityHidden` does not reach platform-hosted scroll and text views, and a
/// hosting view vends those itself, so the flag must sit on a view that *contains* the covered
/// hosting view. From this marker (inside the covered stack's root content) it resolves the
/// enclosing navigation stack's view (its bar and toolbar included) and sets
/// `accessibilityElementsHidden` there — only after proving that view contains no settings
/// anchor, so the settings screen (an overlay outside the split view on iPad, a presented cover
/// on iPhone) always stays reachable. Every update re-resolves (rapid close/open, size-class
/// change); the flag is cleared when uncovered and when the marker goes away.
struct CoveredAccessibility: UIViewRepresentable {
  enum Scope {
    /// iPad: the covered column's navigation stack (bar included); the sidebar stays reachable.
    case stack
    /// iPhone: the whole presenting hierarchy behind the settings cover.
    case presenter
  }
  let covered: Bool
  var scope: Scope = .stack

  @MainActor final class Coordinator {
    weak var hidden: UIView?
    var revision = 0
    func release() {
      hidden?.accessibilityElementsHidden = false
      hidden = nil
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    let coordinator = context.coordinator
    coordinator.revision &+= 1
    let revision = coordinator.revision
    guard covered else {
      if coordinator.hidden != nil {
        coordinator.release()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
      }
      return
    }
    // Settings attaches in the same transaction; resolve once both are in the window.
    let scope = scope
    Task { @MainActor in
      for _ in 0..<40 {
        guard coordinator.revision == revision else { return }
        if let target = Self.coveredRoot(from: view, scope: scope) {
          if coordinator.hidden !== target { coordinator.release() }
          target.accessibilityElementsHidden = true
          coordinator.hidden = target
          UIAccessibility.post(notification: .screenChanged, argument: nil)
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
    coordinator.revision &+= 1
    coordinator.release()
  }

  /// The view to withdraw, or `nil` when no settings anchor is attached yet or the candidate
  /// would contain settings. `.stack`: the enclosing navigation stack's view (else the hosting
  /// controller's view). `.presenter`: the highest ancestor that contains no settings anchor.
  static func coveredRoot(from marker: UIView, scope: Scope) -> UIView? {
    guard let window = marker.window else { return nil }
    let anchors = descendants(of: window).filter { $0 is SettingsAccessibilityAnchor.Anchor }
    guard !anchors.isEmpty else { return nil }
    if scope == .presenter {
      var candidate = marker
      while let parent = candidate.superview,
        !anchors.contains(where: { $0.isDescendant(of: parent) })
      {
        candidate = parent
      }
      return candidate === marker ? nil : candidate
    }
    var hostView: UIView?
    var stackView: UIView?
    var view: UIView? = marker
    while let current = view {
      if current.next is UINavigationController {
        stackView = current
        break
      }
      if hostView == nil, current.next is UIViewController { hostView = current }
      view = current.superview
    }
    guard let target = stackView ?? hostView,
      !anchors.contains(where: { $0.isDescendant(of: target) })
    else { return nil }
    return target
  }

  private static func descendants(of root: UIView) -> [UIView] {
    var result: [UIView] = []
    var stack = [root]
    while let view = stack.popLast() {
      result.append(view)
      stack.append(contentsOf: view.subviews)
    }
    return result
  }
}
