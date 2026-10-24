// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI
import WebKit

extension EnvironmentValues {
  @Entry var mcpHostPool: McpHostPool?
  @Entry var mcpViewport = CGSize.zero
}

struct McpAppPartView: View {
  let part: McpAppPart
  let message: WebMessage
  let store: ConsoleStore
  @Environment(\.mcpHostPool) private var pool
  var body: some View {
    if let pool {
      McpMountedPart(part: part, message: message, store: store, pool: pool)
        .id(McpPartIdentity(part: part, message: message, store: store))
    }
  }
}

private struct McpMountedPart: View {
  let store: ConsoleStore
  let pool: McpHostPool
  @State private var model: McpPartController
  @Environment(\.consoleTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.locale) private var locale
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.mcpViewport) private var viewport
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var webScale: CGFloat = 1
  #if DEBUG
    @Environment(\.mcpDiagnostics) private var diagnostics
  #endif
  init(part: McpAppPart, message: WebMessage, store: ConsoleStore, pool: McpHostPool) {
    self.store = store
    self.pool = pool
    _model = State(
      initialValue: McpPartController(part: part, message: message, store: store, pool: pool))
  }
  private var label: String { model.part.title ?? model.part.toolName }
  private var action: String {
    switch model.phase {
    case .hidden: "Show"
    case .loading, .ready: "Hide"
    case .closed, .error, .unavailable: "Reopen"
    }
  }
  private var error: Bool { [.closed, .error, .unavailable].contains(model.phase) }
  private var environment: McpHostEnvironment {
    var context = McpHostEnvironment()
    context.theme = colorScheme == .dark ? "dark" : "light"
    context.width = width
    context.locale = locale.identifier(.bcp47)
    return context
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        McpSparkle().stroke(theme.palette.accent.color, lineWidth: 1.4).frame(width: 16, height: 16)
          .foregroundStyle(theme.palette.accent.color)
          .frame(width: 30, height: 30).background(
            theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 8)
          )
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(label).webFont(.replyName).foregroundStyle(WebColor.text.color).lineLimit(1)
            .accessibilityLabel(label)
          Text(model.part.description ?? "\(model.part.serverName) · \(model.part.toolName)")
            .webFont(.replyMeta).foregroundStyle(WebColor.textMuted.color).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Button {
          if action == "Hide" { model.hide() } else { model.open() }
        } label: {
          Text(action).webFont(.replyAction).padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(theme.palette.accent.color)
            .background(theme.palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8).stroke(theme.palette.accent.color.opacity(0.24)))
        }
        .buttonStyle(.plain).accessibilityLabel(action + " " + label)
        .accessibilityIdentifier("mcp-action-" + model.part.id)
        .disabled(pool.consent.request != nil)
      }.padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 55)
      Text(
        model.bridge?.retryRequiresConsent == true
          ? "App access expired. Reopen for fresh access and confirmation." : model.status
      )
      .webFont(.banner)
      .foregroundStyle(
        error
          ? WebColor.danger.color
          : model.phase == .ready ? theme.palette.accent.color : WebColor.textMuted.color
      )
      .padding(.vertical, 5).padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(error ? WebColor.dangerSoft.color : WebColor.surfaceSubtle.color)
      .overlay(alignment: .top) { Rectangle().fill(WebColor.line.color).frame(height: 1) }
      .accessibilityLabel("App status: " + model.status).accessibilityIdentifier(
        "mcp-status-" + model.part.id)
      if let bridge = model.bridge, let host = bridge.host, bridge.state != .closed {
        McpWebContent(host: host, label: label, scale: webScale)
          .frame(
            height: McpPartController.displayHeight(
              bridge.height, viewport: viewport.height, compact: sizeClass != .regular)
          )
          .overlay(alignment: .top) { Rectangle().fill(WebColor.line.color).frame(height: 1) }
          .accessibilityIdentifier("mcp-web-" + model.part.id)
      }
      #if DEBUG
        if let diagnostics, diagnostics.interactive {
          Text("Native tool POSTs: \(diagnostics.toolPosts) · Link POSTs: \(diagnostics.linkPosts)")
            .webFont(.banner).foregroundStyle(WebColor.textMuted.color).padding(5)
            .accessibilityIdentifier("mcp-native-counters")
        }
      #endif
    }
    .background(WebColor.surfaceRaised.color)
    .clipShape(RoundedRectangle(cornerRadius: 11))
    .overlay(RoundedRectangle(cornerRadius: 11).stroke(WebColor.lineStrong.color))
    .webShadow(.small).padding(.vertical, 12)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Interactive app: " + label)
    .accessibilityIdentifier("mcp-part-" + model.part.id)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .padding(
      .horizontal,
      sizeClass == .regular
        && min(viewport.width, WebMetrics.column) - 2 * WebSpace.transcriptGutterRegular >= 816
        ? -WebSpace.transcriptGutterRegular : 0
    )
    .onScrollVisibilityChange(threshold: 0.01) { model.visibility($0) }
    .onDisappear {
      model.visibility(false)
      model.hide()
    }
    .onChange(of: colorScheme) { _, _ in model.updateEnvironment(environment) }
    .onChange(of: locale) { _, _ in model.updateEnvironment(environment) }
    .onChange(of: width) { _, _ in model.updateEnvironment(environment) }
    .onChange(of: store.effectiveDataMode) { _, mode in model.setLean(mode == .lean) }
    .onChange(of: store.connection) { _, connection in
      if connection == .offline {
        model.stop(.unavailable, text: "This MCP App is unavailable while offline.")
      }
    }
    .task { model.updateEnvironment(environment) }
  }
}

private struct McpWebContent: UIViewRepresentable {
  let host: McpAppHost
  let label: String
  let scale: CGFloat
  func makeUIView(context: Context) -> McpAppWebView {
    host.webView.accessibilityLabel = label + " interactive app"
    host.webView.pageZoom = scale
    return host.webView
  }
  func updateUIView(_ view: McpAppWebView, context: Context) {
    view.accessibilityLabel = label + " interactive app"
    view.pageZoom = scale
  }
}

private struct McpSparkle: Shape {
  func path(in rect: CGRect) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * rect.width / 24, y: rect.minY + y * rect.height / 24)
    }
    var path = Path()
    path.move(to: point(12, 2))
    path.addCurve(to: point(2, 12), control1: point(11, 9), control2: point(9, 11))
    path.addCurve(to: point(12, 22), control1: point(9, 13), control2: point(11, 15))
    path.addCurve(to: point(22, 12), control1: point(13, 15), control2: point(15, 13))
    path.addCurve(to: point(12, 2), control1: point(15, 11), control2: point(13, 9))
    path.closeSubpath()
    return path
  }
}
