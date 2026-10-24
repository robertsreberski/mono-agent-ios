// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

// Glass vocabulary (see README):
// - System navigation bars, toolbars, tab bars and sheets adopt Liquid Glass on their own.
// - `floatingGlass` and `.floating` buttons are only for controls that float above content.
// - Content (transcripts, forms, dense lists, banners) stays on opaque surfaces.
// - Never apply glass inside glass. Group neighbouring floating glass in a
//   `GlassEffectContainer` so the shapes blend instead of stacking.
// - Reduce Transparency (system, or `prefersOpaqueSurfaces`) swaps in opaque surfaces;
//   Increase Contrast adds a visible outline; Reduce Motion disables interactive glass.

/// Where a control lives relative to content.
public enum DesignControlPlacement: Sendable {
  /// Inside readable content (an empty state, a card). Opaque bordered styles.
  case inline
  /// A control surface floating above content (bottom action bar, composer). Glass.
  case floating
}

public enum DesignButtonProminence: Sendable {
  case primary
  case secondary
}

/// Whether the current environment asks for opaque replacements of glass.
struct SurfacePolicy {
  let reduceTransparency: Bool
  let prefersOpaque: Bool
  var usesGlass: Bool { !(reduceTransparency || prefersOpaque) }
}

extension View {
  /// The single sanctioned custom glass entry point, with accessibility fallbacks.
  ///
  /// `opaqueFill` is the Reduce Transparency replacement (defaults to `tint`, then the opaque
  /// control surface), so web-styled controls keep their web fill when glass is off.
  /// `opaqueStroke` outlines only that opaque replacement (glass draws its own edge).
  public func floatingGlass<S: Shape>(
    in shape: S, tint: Color? = nil, interactive: Bool = false, opaqueFill: Color? = nil,
    opaqueStroke: Color? = nil
  ) -> some View {
    modifier(
      FloatingGlassModifier(
        shape: shape, tint: tint, interactive: interactive, opaqueFill: opaqueFill,
        opaqueStroke: opaqueStroke))
  }

  /// Applies the themed button treatment for a prominence and placement.
  public func designButtonStyle(
    _ prominence: DesignButtonProminence = .primary,
    placement: DesignControlPlacement = .inline
  ) -> some View {
    modifier(DesignButtonModifier(prominence: prominence, placement: placement))
  }

  /// An opaque, readable content card. Use for content, never glass.
  public func contentSurface(padding: CGFloat = DesignSpacing.lg) -> some View {
    modifier(ContentSurfaceModifier(padding: padding))
  }
}

struct FloatingGlassModifier<S: Shape>: ViewModifier {
  let shape: S
  let tint: Color?
  let interactive: Bool
  var opaqueFill: Color? = nil
  var opaqueStroke: Color? = nil
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.prefersOpaqueSurfaces) private var prefersOpaque
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let policy = SurfacePolicy(reduceTransparency: reduceTransparency, prefersOpaque: prefersOpaque)
    let increased = contrast == .increased
    if policy.usesGlass {
      content
        .glassEffect(
          Glass.regular.tint(tint).interactive(interactive && !reduceMotion), in: shape
        )
        .overlay {
          if increased { shape.stroke(Color.primary.opacity(0.6), lineWidth: 1) }
        }
    } else {
      content
        .background {
          shape.fill(opaqueFill ?? tint ?? DesignColor.opaqueControlSurface.color)
            .shadow(color: .black.opacity(opaqueFill == nil ? 0.12 : 0), radius: 6, y: 2)
        }
        .overlay {
          if increased || opaqueFill == nil {
            shape.stroke(
              increased ? Color.primary.opacity(0.6) : DesignColor.separator,
              lineWidth: increased ? 1 : 0.5)
          } else if let opaqueStroke {
            shape.stroke(opaqueStroke, lineWidth: 1)
          }
        }
    }
  }
}

struct DesignButtonModifier: ViewModifier {
  let prominence: DesignButtonProminence
  let placement: DesignControlPlacement
  @Environment(\.consoleTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.prefersOpaqueSurfaces) private var prefersOpaque

  func body(content: Content) -> some View {
    let palette = theme.palette
    let glass =
      placement == .floating
      && SurfacePolicy(reduceTransparency: reduceTransparency, prefersOpaque: prefersOpaque)
        .usesGlass
    // Dark accents are light: filled controls always pair them with `onAccent`, never white.
    switch (prominence, glass) {
    case (.primary, true):
      content.buttonStyle(.glassProminent)
        .tint(palette.accent.color).foregroundStyle(palette.onAccent.color)
    case (.primary, false):
      content.buttonStyle(.borderedProminent)
        .tint(palette.accent.color).foregroundStyle(palette.onAccent.color)
    case (.secondary, true):
      // Primary labels stay legible over any backdrop; an accent label on glass does not.
      content.buttonStyle(.glass).foregroundStyle(.primary)
    case (.secondary, false) where placement == .floating:
      // `.bordered` fills are translucent; a floating fallback must hide content beneath.
      // A capsule of a square circle button is a circle, so this matches either shape.
      content.buttonStyle(.bordered).tint(palette.accent.color)
        .background(DesignColor.opaqueControlSurface.color, in: Capsule())
    case (.secondary, false):
      content.buttonStyle(.bordered).tint(palette.accent.color)
    }
  }
}

struct ContentSurfaceModifier: ViewModifier {
  let padding: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DesignColor.contentSurface, in: shape)
      .overlay {
        if contrast == .increased { shape.stroke(Color.primary.opacity(0.5), lineWidth: 1) }
      }
  }
}

#if DEBUG
  /// Renders preview content once per theme, in the ambient colour scheme.
  struct DesignPreviewMatrix<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.xl) {
          ForEach(ConsoleTheme.allCases) { theme in
            VStack(alignment: .leading, spacing: DesignSpacing.sm) {
              Text(theme.displayName).designFont(.caption).foregroundStyle(.secondary)
              content()
            }
            .consoleTheme(theme)
          }
        }
        .padding()
      }
      .background(ConsoleTheme.evergreen.palette.canvas.color)
    }
  }

  private struct ButtonSamples: View {
    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        HStack {
          Button("Connect") {}.designButtonStyle(.primary)
          Button("Edit") {}.designButtonStyle(.secondary)
        }
        GlassEffectContainer(spacing: DesignSpacing.sm) {
          HStack {
            Button("Retry") {}.designButtonStyle(.primary, placement: .floating)
            Button("Details") {}.designButtonStyle(.secondary, placement: .floating)
          }
        }
      }
      .controlSize(.large)
    }
  }

  #Preview("Buttons — themes, light") { DesignPreviewMatrix { ButtonSamples() } }

  #Preview("Buttons — themes, dark") {
    DesignPreviewMatrix { ButtonSamples() }.preferredColorScheme(.dark)
  }

  #Preview("Buttons — opaque fallback") {
    DesignPreviewMatrix { ButtonSamples() }.prefersOpaqueSurfaces()
  }
#endif
