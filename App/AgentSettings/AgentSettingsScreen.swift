// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// The settings presentation the dashboard header and DEBUG launch destinations drive. Settings
/// is not a route: it covers the current context and closing it leaves the operator there.
struct AgentSettingsPresentation: Equatable {
  var target: AgentSettingsTarget
}

/// The header entry: whether settings is open and how to toggle or retarget it.
struct AgentSettingsEntry {
  var isOpen = false
  var open: @MainActor (AgentSettingsSection?) -> Void = { _ in }
  var toggle: @MainActor () -> Void = {}
  /// An explicit destination choice (row, project, new conversation) closes settings, even
  /// when it reselects the destination already underneath. Agent switching does not.
  var close: @MainActor () -> Void = {}
}

extension EnvironmentValues {
  @Entry var agentSettingsEntry = AgentSettingsEntry()
  /// True while agent settings covers this destination; a covered transcript is not visible.
  @Entry var coveredBySettings = false
  /// Opens the console's web URL outside the app (Safari). DEBUG fixtures record instead.
  @Entry var openWebConsole = OpenWebConsoleAction { url in UIApplication.shared.open(url) }
}

struct OpenWebConsoleAction {
  let handler: @MainActor (URL) -> Void
  init(_ handler: @escaping @MainActor (URL) -> Void) { self.handler = handler }
  @MainActor func callAsFunction(_ url: URL) { handler(url) }
}

extension ConsoleStore {
  /// The dashboard's agent: the selected bucket, else the bootstrap's, else the first by pin.
  var dashboardAgentID: String? {
    selectedBucket?.sourceID ?? bootstrap?.threadsSourceId
      ?? DashboardModel.sortPinnedFirst(agents).first?.sourceId
  }
}

/// Web `AgentSettingsScreen`: one long page for the dashboard's agent. Header with the agent's
/// name and status, an offline notice, pin, New conversations and About. Solid web content;
/// the model picker is the only floating surface.
struct AgentSettingsScreen: View {
  enum Layout { case stacked, split }
  let store: ConsoleStore
  let sourceID: String?
  let target: AgentSettingsTarget
  let layout: Layout
  let close: () -> Void
  @Environment(\.consoleTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @AccessibilityFocusState private var focus: FocusTarget?
  @State private var shownTarget: AgentSettingsTarget?
  @State private var shownSource: String?

  enum FocusTarget: Hashable {
    case title
    case section(AgentSettingsSection)
  }

  private var agent: WebAgentSummary? { sourceID.flatMap { store.agent($0) } }

  var body: some View {
    Group {
      if let agent {
        page(agent)
      } else {
        missing
      }
    }
    .background(theme.palette.panel.color.ignoresSafeArea())
    .background(SettingsAccessibilityAnchor())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-settings-screen")
  }

  private var missing: some View {
    VStack(spacing: 16) {
      Text("This agent is no longer available.").webFont(.stateBody)
        .foregroundStyle(WebColor.textSoft.color)
      Button("Close", action: close).buttonStyle(SettingsButtonStyle())
        .accessibilityIdentifier("agent-settings-close")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func page(_ agent: WebAgentSummary) -> some View {
    VStack(spacing: 0) {
      header(agent)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0).id("settings-top")
            if agent.status == "offline" {
              Text(
                "\(agent.label) is offline. Changes that need the agent are paused. Using the agent config still works."
              )
              .webFont(.notice).foregroundStyle(WebColor.warning.color)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 10).padding(.horizontal, 12)
              .background(
                WebColor.warning.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                  WebColor.warning.color.opacity(0.28), lineWidth: 1)
              }
              .accessibilityIdentifier("settings-offline-notice")
            }
            AgentPinRow(store: store, agent: agent)
            section(
              .newConversations, title: "New conversations",
              summary:
                "The model and effort new conversations start with. Existing conversations keep theirs."
            ) {
              NewConversationsSection(store: store, agent: agent, wide: wide)
            }
            WebHairline().opacity(0.9)
            section(
              .providers, title: "Providers",
              summary: "Sign in, check access and read subscription limits."
            ) {
              ProvidersSection(store: store, agent: agent, compact: !wide)
            }
            WebHairline().opacity(0.9)
            about(agent)
          }
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { height in
            if height > 0 && shownTarget == nil { apply(agent: agent.sourceId, proxy: proxy) }
          }
          .frame(maxWidth: 640, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, layout == .split ? 32 : WebSpace.dashboardGutter)
          .padding(.top, layout == .split ? 26 : 18)
          .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        // Readiness for tests and screenshots, never a timer: hydrated and answered.
        .accessibilityIdentifier(ready ? "agent-settings-ready" : "agent-settings-loading")

        .onChange(of: target) { apply(agent: agent.sourceId, proxy: proxy) }
        .onChange(of: agent.sourceId) { apply(agent: agent.sourceId, proxy: proxy) }
      }
    }
    .onAppear { store.reconcileRunDefaultsDraft(sourceID: agent.sourceId) }
  }

  private var wide: Bool { layout == .split && !typeSize.isAccessibilitySize }

  private var ready: Bool {
    store.hydrated && (!store.isStarted || store.freshness == .fresh || store.errorMessage != nil)
  }

  /// Web: only opening or an explicit intent moves focus and scroll. Switching agent while open
  /// returns to the top without pulling focus out of the sidebar.
  private func apply(agent sourceID: String, proxy: ScrollViewProxy) {
    if shownSource != sourceID {
      let switching = shownSource != nil
      shownSource = sourceID
      if switching {
        proxy.scrollTo("settings-top", anchor: .top)
        shownTarget = target
        return
      }
    }
    guard shownTarget != target else { return }
    shownTarget = target
    if let section = target.section {
      proxy.scrollTo(section.rawValue, anchor: .top)
      focus = .section(section)
    } else {
      proxy.scrollTo("settings-top", anchor: .top)
      focus = .title
    }
  }

  // MARK: Header

  /// Web `.settings-header`: back (phone), the agent tile, eyebrow and name, status, ✕ (wide).
  private func header(_ agent: WebAgentSummary) -> some View {
    HStack(spacing: 12) {
      if layout == .stacked {
        Button("Back from agent settings", systemImage: "chevron.left", action: close)
          .labelStyle(.iconOnly).font(.system(size: 17, weight: .medium))
          .foregroundStyle(WebColor.textSoft.color)
          .frame(width: DesignMetrics.minimumHitTarget, height: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle()).buttonStyle(.plain)
          .accessibilityIdentifier("agent-settings-back")
      }
      if layout == .split && !typeSize.isAccessibilitySize {
        Text(DashboardModel.initials(agent.label))
          .font(.system(size: 11, weight: .bold)).tracking(0.2)
          .foregroundStyle(WebColor.text.color)
          .frame(width: 36, height: 36)
          .background(theme.palette.canvas.color, in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(WebColor.lineStrong.color)
          }
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 3) {
        Eyebrow("Agent settings")
        Text(agent.label).webFont(.agentName).foregroundStyle(WebColor.text.color)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Agent settings, \(agent.label)")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("agent-settings-title")
      .accessibilityFocused($focus, equals: .title)
      Spacer(minLength: 0)
      statusBadge(agent)
      if layout == .split {
        Button("Close agent settings", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly).font(.system(size: 15, weight: .regular))
          .foregroundStyle(WebColor.textSoft.color)
          .frame(width: DesignMetrics.minimumHitTarget, height: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle()).buttonStyle(.plain)
          .accessibilityIdentifier("agent-settings-close")
      }
    }
    .padding(.leading, layout == .stacked ? 6 : WebSpace.dashboardGutter)
    .padding(.trailing, layout == .split ? 10 : WebSpace.dashboardGutter)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
    .overlay(alignment: .bottom) {
      Rectangle().fill(WebColor.line.color).frame(height: 1).accessibilityHidden(true)
    }
  }

  /// Web `.chat-status`: a dot and the uppercase status word.
  private func statusBadge(_ agent: WebAgentSummary) -> some View {
    let color: Color =
      switch agent.status {
      case "online": theme.palette.accent.color
      case "offline": WebColor.danger.color
      default: WebColor.warning.color
      }
    return HStack(spacing: 5) {
      Image(systemName: "circle.fill").font(.system(size: 6, weight: .bold))
        .foregroundStyle(color)
      Text(agent.status)
        .font(.system(size: 10, weight: .semibold)).tracking(0.7).textCase(.uppercase)
        .foregroundStyle(agent.status == "online" ? WebColor.textMuted.color : color)
        .lineLimit(1)
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Agent status: \(agent.status)")
    .accessibilityIdentifier("agent-settings-status")
  }

  // MARK: Sections

  private func section<Content: View>(
    _ id: AgentSettingsSection, title: String, summary: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).webFont(.settingsTitle).foregroundStyle(WebColor.text.color)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($focus, equals: .section(id))
          .accessibilityIdentifier("settings-section-" + id.rawValue)
        Text(summary).webFont(.settingsSummary).foregroundStyle(WebColor.textMuted.color)
      }
      content()
    }
    .id(id.rawValue)
  }

  private func about(_ agent: WebAgentSummary) -> some View {
    let capabilities: [(Bool?, String)] = [
      (agent.supportsAttachments, "Attachments"),
      (agent.supportsManualCompaction, "Manual compaction"),
      (agent.cron?.read, "Automations"), (agent.supportsProviderAuth, "Provider sign-in"),
      (agent.supportsProviderUsage, "Usage limits"), (agent.restart?.supported, "Console restart"),
    ]
    let supported = capabilities.filter { $0.0 == true }.map(\.1)
    return VStack(alignment: .leading, spacing: 12) {
      Text("About").webFont(.settingsTitle).foregroundStyle(WebColor.text.color)
        .accessibilityAddTraits(.isHeader)
      SettingsBox {
        SettingsFactRow("Source", wide: wide, identifier: "settings-about-source") {
          Text(agent.sourceId).webFont(.settingsMono).foregroundStyle(WebColor.text.color)
        }
        SettingsFactRow("Supports", wide: wide, identifier: "settings-about-supports") {
          if supported.isEmpty {
            Text("—").webFont(.rowTitle).foregroundStyle(WebColor.textMuted.color)
          } else {
            WebFlowLayout(spacing: 4, lineSpacing: 4) {
              ForEach(supported, id: \.self) { SettingsChip($0) }
            }
          }
        }
      }
    }
  }
}

/// Web `AgentPinRow`: independent of everything else on the page; pending shows the request.
struct AgentPinRow: View {
  let store: ConsoleStore
  let agent: WebAgentSummary
  @Environment(\.consoleTheme) private var theme
  var body: some View {
    let state = store.agentSettingsState(agent.sourceId)
    SettingsBox {
      Toggle(
        isOn: Binding(
          get: { state.requestedPin ?? (agent.pinned == true) },
          set: { store.setAgentPinned(sourceID: agent.sourceId, pinned: $0) })
      ) {
        HStack(spacing: 12) {
          Image(systemName: "star").font(.system(size: 16)).foregroundStyle(
            WebColor.textSoft.color
          )
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("Pin \(agent.label) first").webFont(.rowTitle)
              .foregroundStyle(WebColor.text.color)
            Text("Pinned agents sort first on the agent strip.").webFont(.settingsNote)
              .foregroundStyle(WebColor.textMuted.color)
            if let error = state.pinError {
              Text(error).webFont(.settingsNote).foregroundStyle(WebColor.danger.color)
                .accessibilityIdentifier("agent-settings-pin-error")
            }
          }
        }
      }
      .tint(theme.palette.accent.color)
      .disabled(state.pinPending || !store.canWriteAgentSettings)
      .padding(.vertical, 10).padding(.horizontal, 14)
      .frame(minHeight: 48)
      .accessibilityIdentifier("agent-settings-pin")
    }
  }
}

// MARK: Web settings primitives (content layer)

/// Web `.settings-group`: raised surface, line edge, 12 pt corners; rows separated by lines.
struct SettingsBox<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 {
            Rectangle().fill(WebColor.line.color).frame(height: 1).accessibilityHidden(true)
          }
          row
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .webLayeredSurface(
      RoundedRectangle(cornerRadius: 12), fill: WebColor.surfaceRaised.color,
      stroke: WebColor.line.color, shadow: .small)
  }
}

/// Web `.settings-kv` / `.settings-agent-fact-row`: a 118 pt label column on wide layouts,
/// stacked on phones and at accessibility sizes.
struct SettingsFactRow<Value: View, Trailing: View>: View {
  let label: String
  let wide: Bool
  /// Identifies the combined label + value element (trailing actions stay separate).
  let identifier: String?
  @ViewBuilder let value: Value
  @ViewBuilder let trailing: Trailing
  init(
    _ label: String, wide: Bool, identifier: String? = nil, @ViewBuilder value: () -> Value,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) {
    self.label = label
    self.wide = wide
    self.identifier = identifier
    self.value = value()
    self.trailing = trailing()
  }
  var body: some View {
    let title = Text(label).webFont(.settingsLabel).foregroundStyle(WebColor.textSoft.color)
    HStack(alignment: .center, spacing: 12) {
      Group {
        if wide {
          HStack(alignment: .center, spacing: 12) {
            title.frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { value }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            title
            VStack(alignment: .leading, spacing: 2) { value }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(identifier ?? "")
      trailing
    }
    .padding(.vertical, 10).padding(.horizontal, 14)
    .frame(minHeight: 48)
  }
}

/// Web `.settings-chip`.
struct SettingsChip: View {
  enum Tone { case neutral, warning, accent }
  let text: String
  let tone: Tone
  @Environment(\.consoleTheme) private var theme
  init(_ text: String, tone: Tone = .neutral) {
    self.text = text
    self.tone = tone
  }
  var body: some View {
    let foreground: Color =
      switch tone {
      case .neutral: WebColor.textMuted.color
      case .warning: WebColor.warning.color
      case .accent: theme.palette.accent.color
      }
    let background: Color =
      switch tone {
      case .neutral: WebColor.surfaceSubtle.color
      case .warning: WebColor.warning.color.opacity(0.13)
      case .accent: theme.palette.accentSoft.color
      }
    Text(text).webFont(.chip).foregroundStyle(foreground)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(background, in: Capsule())
      .lineLimit(1)
  }
}

/// Web `.settings-button` variants, in the content layer (never glass).
struct SettingsButtonStyle: ButtonStyle {
  enum Kind { case standard, primary, ghost }
  var kind: Kind = .standard
  @Environment(\.consoleTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    let foreground: Color =
      switch kind {
      case .primary: theme.palette.onAccent.color
      default: configuration.isPressed ? WebColor.text.color : WebColor.textSoft.color
      }
    let fill: Color =
      switch kind {
      case .primary: theme.palette.accentStrong.color
      case .standard: configuration.isPressed ? WebColor.surfaceHover.color : WebColor.surface.color
      case .ghost: configuration.isPressed ? WebColor.surfaceHover.color : .clear
      }
    configuration.label
      .webFont(.settingsButton).foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 12).frame(minHeight: 32)
      .background(fill, in: shape)
      .overlay {
        if kind == .standard { shape.strokeBorder(WebColor.lineStrong.color, lineWidth: 1) }
      }
      .opacity(enabled ? 1 : 0.45)
      .frame(minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
  }
}
