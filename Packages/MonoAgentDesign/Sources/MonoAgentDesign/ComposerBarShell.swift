// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Layout-only chrome for a floating composer: leading accessories, a field slot and
/// trailing actions grouped in one `GlassEffectContainer`. It owns no text, drafts,
/// uploads or submission logic; the composer feature supplies those.
///
/// Place it with `.safeAreaBar(edge: .bottom)` so content scrolls beneath the glass with
/// the system scroll-edge effect keeping the bar legible.
/// Style accessory buttons with `.designButtonStyle(_, placement: .floating)`; do not
/// put additional glass inside the field slot.
public struct ComposerBarShell<Leading: View, Field: View, Trailing: View>: View {
  private let leading: Leading
  private let field: Field
  private let trailing: Trailing

  public init(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder field: () -> Field,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.leading = leading()
    self.field = field()
    self.trailing = trailing()
  }

  public var body: some View {
    GlassEffectContainer(spacing: DesignSpacing.sm) {
      HStack(alignment: .bottom, spacing: DesignSpacing.sm) {
        leading
        field
          .padding(.horizontal, DesignSpacing.lg)
          .padding(.vertical, DesignSpacing.sm + DesignSpacing.xxs)
          .frame(
            maxWidth: .infinity, minHeight: DesignMetrics.minimumHitTarget, alignment: .leading
          )
          .floatingGlass(in: RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous))
        trailing
      }
    }
    .padding(.horizontal, DesignSpacing.md)
    .padding(.vertical, DesignSpacing.sm)
    // Keep the bar on the readable column on iPad and in landscape.
    .frame(maxWidth: DesignMetrics.readableWidth + 2 * DesignSpacing.md)
    .frame(maxWidth: .infinity)
  }
}

#if DEBUG
  private struct ComposerPreview: View {
    @State private var text = ""
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          ForEach(0..<12) { index in
            Text("Content row \(index + 1) scrolls beneath the composer.").contentSurface()
          }
        }
        .padding()
      }
      .safeAreaBar(edge: .bottom) {
        ComposerBarShell {
          Button("Attach", systemImage: "plus") {}
            .labelStyle(.iconOnly)
            .designButtonStyle(.secondary, placement: .floating)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        } field: {
          TextField("Message", text: $text, axis: .vertical)
        } trailing: {
          Button("Send", systemImage: "arrow.up") {}
            .labelStyle(.iconOnly)
            .designButtonStyle(.primary, placement: .floating)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
      }
    }
  }

  #Preview("Composer shell — evergreen") { ComposerPreview().consoleTheme(.evergreen) }

  #Preview("Composer shell — plum, dark") {
    ComposerPreview().consoleTheme(.plum).preferredColorScheme(.dark)
  }

  #Preview("Composer shell — opaque fallback") {
    ComposerPreview().consoleTheme(.ocean).prefersOpaqueSurfaces()
  }
#endif
