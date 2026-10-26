// SPDX-License-Identifier: GPL-3.0-only
import Testing
import UIKit

@testable import MonoAgent

/// The covered-context resolver never withdraws a view that contains the settings screen.
@MainActor struct CoveredAccessibilityTests {
  /// window ▸ split ▸ [column navigation stack ▸ content ▸ marker] + overlay ▸ settings anchor.
  private func layout(anchorInsideStack: Bool = false, anchor: Bool = true) throws
    -> (UIWindow, UINavigationController, UIView, UIView)
  {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
      "the hosted test bundle has a window scene")
    let window = UIWindow(windowScene: scene)
    let split = UIView()
    window.addSubview(split)
    let navigation = UINavigationController(rootViewController: UIViewController())
    split.addSubview(navigation.view)
    let content = UIView()
    navigation.view.addSubview(content)
    let marker = UIView()
    content.addSubview(marker)
    let overlay = UIView()
    window.addSubview(overlay)
    if anchor {
      (anchorInsideStack ? content : overlay).addSubview(SettingsAccessibilityAnchor.Anchor())
    }
    return (window, navigation, split, marker)
  }

  @Test func stackScopeWithdrawsTheCoveredNavigationStackOnly() throws {
    let (window, navigation, _, marker) = try layout()
    let target = CoveredAccessibility.coveredRoot(from: marker, scope: .stack)
    #expect(target === navigation.view)
    let anchors = window.subviews.flatMap(\.subviews).filter {
      $0 is SettingsAccessibilityAnchor.Anchor
    }
    #expect(anchors.allSatisfy { !$0.isDescendant(of: target!) })
  }

  @Test func neverWithdrawsAViewContainingSettings() throws {
    let (_, _, _, marker) = try layout(anchorInsideStack: true)
    #expect(CoveredAccessibility.coveredRoot(from: marker, scope: .stack) == nil)
    #expect(CoveredAccessibility.coveredRoot(from: marker, scope: .presenter) == nil)
  }

  @Test func waitsForSettingsInsteadOfGuessing() throws {
    let (_, _, _, marker) = try layout(anchor: false)
    #expect(CoveredAccessibility.coveredRoot(from: marker, scope: .stack) == nil)
    #expect(CoveredAccessibility.coveredRoot(from: marker, scope: .presenter) == nil)
    #expect(CoveredAccessibility.coveredRoot(from: UIView(), scope: .stack) == nil, "detached")
  }

  @Test func presenterScopeWithdrawsEverythingBehindTheCover() throws {
    let (_, _, split, marker) = try layout()
    #expect(CoveredAccessibility.coveredRoot(from: marker, scope: .presenter) === split)
  }

  @Test func releasingTheCoordinatorClearsTheFlag() {
    let coordinator = CoveredAccessibility.Coordinator()
    let view = UIView()
    view.accessibilityElementsHidden = true
    coordinator.hidden = view
    CoveredAccessibility.dismantleUIView(UIView(), coordinator: coordinator)
    #expect(!view.accessibilityElementsHidden && coordinator.hidden == nil)
  }
}
