// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import MonoAgentDesign
  import SwiftUI

  /// DEBUG-only design catalog scenarios (`--scenario design-catalog…`). Release builds
  /// contain neither these names nor the catalog view (`Tools/check-release-fixtures`).
  enum DesignCatalogScenario: String, CaseIterable, Sendable {
    case catalog = "design-catalog"
    case evergreen = "design-catalog-evergreen"
    case ocean = "design-catalog-ocean"
    case plum = "design-catalog-plum"
    case terracotta = "design-catalog-terracotta"
    case accessibility = "design-catalog-accessibility"
    case reduceTransparency = "design-catalog-reduce-transparency"

    var theme: ConsoleTheme {
      switch self {
      case .catalog, .evergreen, .accessibility: .evergreen
      case .ocean: .ocean
      case .plum, .reduceTransparency: .plum
      case .terracotta: .terracotta
      }
    }

    var largeText: Bool { self == .accessibility }
    var opaqueSurfaces: Bool { self == .reduceTransparency }
  }

  /// Every design component in the chosen theme, with toolbar controls for theme, text
  /// size and the Reduce Transparency fallback. All text is synthetic sample content.
  struct DesignCatalogView: View {
    let scenario: DesignCatalogScenario
    @State private var theme: ConsoleTheme
    @State private var largeText: Bool
    @State private var opaque: Bool

    init(scenario: DesignCatalogScenario) {
      self.scenario = scenario
      _theme = State(initialValue: scenario.theme)
      _largeText = State(initialValue: scenario.largeText)
      _opaque = State(initialValue: scenario.opaqueSurfaces)
    }

    var body: some View {
      NavigationStack {
        DesignCatalogContent(
          identifier: scenario.rawValue, theme: theme, largeText: largeText, opaque: opaque
        )
        .navigationTitle("Design catalog")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Menu("Catalog options", systemImage: "slider.horizontal.3") {
              Picker("Theme", selection: $theme) {
                ForEach(ConsoleTheme.allCases) { Text($0.displayName).tag($0) }
              }
              Toggle("Accessibility text size", isOn: $largeText)
              Toggle("Reduce Transparency fallback", isOn: $opaque)
            }
          }
        }
      }
      .consoleTheme(theme)
      .prefersOpaqueSurfaces(opaque)
      .dynamicTypeSize(
        largeText ? .accessibility3 ... .accessibility3 : .xSmall ... .accessibility5)
    }
  }

  private struct DesignCatalogContent: View {
    let identifier: String
    let theme: ConsoleTheme
    let largeText: Bool
    let opaque: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.xl) {
          header
          catalogSection("Themes") { ThemeRows() }
          catalogSection("Web tokens") { WebTokenSpecimens() }
          catalogSection("Buttons") { ButtonSpecimens() }
          catalogSection("Status") { StatusSpecimens() }
          catalogSection("Unread markers") { UnreadSpecimens() }
          catalogSection("Banners") { BannerSpecimens() }
          catalogSection("Agent tiles") { AgentTileSpecimens() }
          catalogSection("Tags and projects") { ChipSpecimens() }
          catalogSection("Organize forms") {
            OrganizeSheetHeader("New project", saving: false, canSave: true, cancel: {}, save: {})
            LabelPalette(
              selection: .constant(.blue), colors: [.standard, .blue, .purple, .amber, .rose],
              kind: "project")
          }
          catalogSection("Organize menus") {
            OrganizeMenuRow("Move to project", systemImage: "folder", detail: "Garden planner") {}
            OrganizeMenuRow("Permanently delete", systemImage: "trash", destructive: true) {}
          }
          catalogSection("Conversation rows") { RowSpecimens() }
          catalogSection("Section headers") {
            VStack(alignment: .leading, spacing: DesignSpacing.md) {
              Section("Long organize menus") {
                OrganizeMenuScroll(maximumHeight: 220) {
                  ForEach(1...30, id: \.self) { value in
                    OrganizeMenuRow("Label \(value)", systemImage: "tag") {}
                  }
                }
              }
              Section("Wake schedules") {
                WakeSummaryView(
                  state: "Active", sentence: "Every weekday at 09:00",
                  next: "Next: Mon 12 May, 09:00 (UTC)", outcome: "Last wake-up ran.")
                WakeScheduleStatus("Weekly · paused · compact first")
              }
              SectionHeader("Saved consoles")
              SectionHeader("Agents", detail: "3 active · synthetic") { UnreadMarker(count: 4) }
            }
            .contentSurface()
          }
          catalogSection("Restart proposals") {
            RestartProposalCard(.init(agentLabel: "Atlas"), request: {}, confirm: {}, cancel: {})
          }
          catalogSection("Reply images") {
            ScrollView(.horizontal) {
              HStack(spacing: 6) {
                ReplyImageTile(name: "Sample picture", size: "128 KiB", image: nil, phase: .load) {}
                ReplyImageTile(name: "Sample picture", size: "128 KiB", image: nil) {}
              }
            }
          }
          catalogSection("Reply files") {
            ReplyFileCard(name: "report.pdf", mediaType: "application/pdf", sizeBytes: 4096) {}
            ReplyFileCard(
              name: "archive.zip", mediaType: "application/zip", sizeBytes: 1024,
              phase: .unavailable, status: "This file is no longer available."
            ) {}
            ReplyFailureCard(
              code: "artifact_not_found", message: "The requested artifact was not found.")
          }
          catalogSection("Settings") {
            SettingsGroup("Console") {
              TextField("Display name", text: .constant("Sample console")).settingsField()
              Text("Connect only to a console you trust.").webFont(.notice)
            }
          }
          catalogSection("States") { StateSpecimens() }
          catalogSection("Rich documents") {
            RichTextDocumentView(
              source:
                "## Release notes\n- [x] **Bold** and `code`\n\n| Item | Status |\n| --- | --- |\n| Sample | Complete |"
            )
          }
          catalogSection("Content disclosure") {
            ContentDisclosure("catalog-details", expanded: .constant(true)) {
              Text("Native detail content").designFont(.body)
            } label: {
              Label("Details", systemImage: "terminal").designFont(.headline)
            }
          }
          catalogSection("Context and cost") {
            ContextDisplay(
              .init(
                badge: "—", figure: "Context size not reported", status: "Not reported",
                rows: [.init("Estimated cost", "Unknown")]), expanded: .constant(true))
          }
          catalogSection("Route badge") {
            RouteBadge(
              model: "sample:large", effort: "high",
              detail: "Current settings · inherited agent defaults")
          }
          catalogSection("Answer surfaces") {
            VStack(alignment: .leading, spacing: 14) {
              MessageQuote("A fictional passage from the sample plan.")
              ChoiceRow(
                "Reserve now", detail: "Keep a sample packet", selected: true, multiple: false)
              TextField("Custom reply", text: .constant("")).webInput()
              Button("Submit answer") {}.buttonStyle(WebSubmitButtonStyle())
              Button("Tell me more") {}.buttonStyle(WebReplyButtonStyle())
            }.webFormCard()
          }
          catalogSection("Sheet parts") {
            VStack(spacing: 0) {
              WebSheetHeader("Run settings", subtitle: "Choose the next turn's route") {}
              WebSearchField("Search models", text: .constant(""))
              WebModelRow("Sample Large", detail: "sample:large", selected: true)
              Button("High") {}.buttonStyle(WebEffortButtonStyle(selected: true))
            }.background(WebColor.surfaceRaised.color)
          }
          catalogSection("Job rows and outcomes") { JobSpecimens() }
          catalogSection("Activity disclosure") {
            ActivityDisclosure(
              "Read ×2", summary: "sample.md, outline.md", detail: "42ms", expanded: .constant(true)
            ) {
              CodeDocumentView(source: "Synthetic output", language: "Output")
            }
          }
          catalogSection("Composer parts") {
            VStack(alignment: .leading, spacing: DesignSpacing.sm) {
              QuotePreview(
                "The sample is ready. Two checks passed; one fictional file needs attention."
              ) {}
              HStack {
                AttachmentChip(name: "field-notes.txt", detail: "1 KB", isImage: false) {}
                AttachmentChip(
                  name: "sample-photo.png", detail: "", isImage: true, phase: .uploading(0.6))
              }
              AttachmentChip(name: "too-large.pdf", detail: "", isImage: false, phase: .failed) {}
              SuggestionRow(
                "$release-notes", subtitle: "Draft release notes from the sample changelog",
                badge: "On demand", highlighted: true)
              SuggestionRow(
                "Run settings", subtitle: "Choose the model and reasoning effort",
                systemImage: "slider.horizontal.3")
              ChoiceRow("Today", detail: "Publish this afternoon", selected: true, multiple: false)
              ChoiceRow("Images", detail: "Check image sizes", selected: false, multiple: true)
            }
            .contentSurface()
          }
          catalogSection("Composer bar shell") {
            Text("Pinned below: layout-only glass shell. Content scrolls beneath it.")
              .designFont(.supporting).foregroundStyle(.secondary)
          }
        }
        .padding(DesignSpacing.lg)
        .frame(maxWidth: DesignMetrics.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(theme.palette.canvas.color)
      .safeAreaBar(edge: .bottom) { composer }
      .scrollEdgeEffectStyle(.hard, for: .bottom)
      .accessibilityIdentifier("scenario-ready")
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        Label("Synthetic design catalog", systemImage: "swatchpalette")
          .designFont(.caption).foregroundStyle(.secondary)
        Text(
          [
            theme.displayName, scheme == .dark ? "Dark" : "Light",
            largeText ? "Accessibility text (AX3)" : "Standard text",
            opaque ? "Reduce Transparency fallback" : "Liquid Glass",
          ].joined(separator: " · ")
        )
        .designFont(.supporting)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(identifier)
    }

    private var composer: some View {
      ComposerBarShell {
        Button("Attach", systemImage: "plus") {}
          .labelStyle(.iconOnly)
          .designButtonStyle(.secondary, placement: .floating)
          .buttonBorderShape(.circle)
          .controlSize(.large)
      } field: {
        TextField("Message", text: $draft, axis: .vertical)
          .lineLimit(1...4)
      } trailing: {
        Button("Send", systemImage: "arrow.up") {}
          .labelStyle(.iconOnly)
          .designButtonStyle(.primary, placement: .floating)
          .buttonBorderShape(.circle)
          .controlSize(.large)
      }
    }

    private func catalogSection(
      _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        SectionHeader(title)
        content()
      }
    }
  }

  private struct JobSpecimens: View {
    @State private var expanded = true
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          ForEach(JobGlyphMark.allCases, id: \.self) { mark in
            JobGlyph(
              mark, tone: mark == .half ? .running : mark == .question ? .question : .neutral)
          }
        }
        JobRowDisclosure(
          "catalog-job", accessibilityLabel: "Sample job, Running", expanded: $expanded
        ) {
          JobGlyph(.half, tone: .running)
        } title: {
          Text("Run the sample suite")
        } meta: {
          WebFlowLayout {
            Text("Running").foregroundStyle(WebJobTone.running.text)
            JobMetaToken { Text("Bash") }
            JobMetaToken { Text("4m 12s") }
          }
        } content: {
          JobOutputBox("Sample suite completed: 12 checks")
          JobErrorBox("The sample process exited.", code: "exit_nonzero")
          Button("Refresh") {}.buttonStyle(WebSmallButtonStyle())
        }
        Button("History") {}.buttonStyle(JobHistoryToggleStyle(open: false, count: 3))
        ActivityBand(meta: "2 steps · 1.2s", running: false, expanded: .constant(true)) {
          ActivityDisclosure(
            "Read ×2", summary: "sample.md, outline.md", expanded: .constant(false)
          ) {
            Text("Sample output")
          }
        }
      }
    }
  }

  /// The web console's surface/text/line roles, type scale and floating tile/pill controls.
  private struct WebTokenSpecimens: View {
    @Environment(\.consoleTheme) private var theme
    private let roles: [(String, AdaptiveColor)] = [
      ("surface", WebColor.surface), ("raised", WebColor.surfaceRaised),
      ("subtle", WebColor.surfaceSubtle), ("hover", WebColor.surfaceHover),
      ("line", WebColor.line), ("line-strong", WebColor.lineStrong),
      ("text-soft", WebColor.textSoft), ("text-muted", WebColor.textMuted),
      ("progress", WebColor.jobProgress), ("delegation", WebColor.delegation),
    ]
    var body: some View {
      VStack(alignment: .leading, spacing: WebSpace.sectionHeadBottom) {
        FlowLayout {
          ForEach(roles, id: \.0) { role in
            VStack(spacing: 2) {
              RoundedRectangle(cornerRadius: WebRadius.small).fill(role.1.color)
                .frame(width: 44, height: 28)
                .overlay(
                  RoundedRectangle(cornerRadius: WebRadius.small).stroke(WebColor.line.color))
              Text(role.0).webFont(.rowTime).foregroundStyle(WebColor.textMuted.color)
            }
            .accessibilityElement(children: .combine)
          }
        }
        Eyebrow("Eyebrow · 10 / 700")
        Text("Atlas").webFont(.agentName).foregroundStyle(WebColor.text.color)
        Text("Row title 12 / 650").webFont(.rowTitle).foregroundStyle(WebColor.text.color)
        Text("Row subtitle 10").webFont(.rowSubtitle).foregroundStyle(WebColor.textMuted.color)
        Text("Prose 13.5 / 1.62 keeps the web's reading rhythm across two lines of text.")
          .webFont(.prose).foregroundStyle(WebColor.text.color)
        HStack(spacing: WebSpace.tileGap) {
          Button("Consoles", systemImage: "slider.horizontal.3") {}.buttonStyle(
            WebTileButtonStyle())
          Button("New", systemImage: "plus") {}.buttonStyle(WebTileButtonStyle(.accent))
          Spacer()
          Button {
          } label: {
            Label("Archived", systemImage: "archivebox")
          }
          .buttonStyle(WebQuietPillStyle())
        }
      }
      .padding(WebSpace.dashboardGutter)
      .background(theme.palette.panel.color, in: RoundedRectangle(cornerRadius: WebRadius.medium))
    }
  }

  /// The same specimens in all four themes, so every screenshot shows each palette.
  private struct ThemeRows: View {
    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        ForEach(ConsoleTheme.allCases) { theme in
          FlowLayout {
            HStack(spacing: DesignSpacing.xs) {
              swatch(theme.palette.accent.light)
              swatch(theme.palette.accent.dark)
              Text(theme.displayName).designFont(.headline)
            }
            .accessibilityElement(children: .combine)
            Button("Connect") {}.designButtonStyle(.primary).controlSize(.small)
            StatusChip(.online)
            UnreadMarker(count: 3)
          }
          .contentSurface(padding: DesignSpacing.md)
          .consoleTheme(theme)
        }
      }
    }

    private func swatch(_ colour: RGBColor) -> some View {
      Circle().fill(colour.color).frame(width: 18, height: 18)
        .overlay(Circle().stroke(DesignColor.separator))
        .accessibilityHidden(true)
    }
  }

  private struct ButtonSpecimens: View {
    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Text("Inline (on content)").designFont(.caption).foregroundStyle(.secondary)
        FlowLayout {
          Button("Connect") {}.designButtonStyle(.primary)
          Button("Edit") {}.designButtonStyle(.secondary)
          Button("Remove", role: .destructive) {}.designButtonStyle(.secondary)
          Button("Disabled") {}.designButtonStyle(.primary).disabled(true)
        }
        Text("Floating (glass above content)").designFont(.caption).foregroundStyle(.secondary)
        GlassBackdrop {
          GlassEffectContainer(spacing: DesignSpacing.sm) {
            FlowLayout {
              Button("Retry") {}.designButtonStyle(.primary, placement: .floating)
              Button("Details") {}.designButtonStyle(.secondary, placement: .floating)
              StatusChip(.connecting, label: "Reconnecting", placement: .floating)
            }
          }
        }
      }
      .controlSize(.large)
    }
  }

  /// Sample content beneath floating glass so refraction is visible in screenshots. The
  /// controls float over colour blocks, not over the readable lines above them.
  private struct GlassBackdrop<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.consoleTheme) private var theme

    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        Text("Synthetic transcript content scrolls beneath floating controls.")
          .designFont(.supporting)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        ZStack(alignment: .leading) {
          HStack(spacing: DesignSpacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, colour in
              RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                .fill(colour.opacity(0.55))
                .frame(height: 28)
            }
          }
          .accessibilityHidden(true)
          content().padding(.horizontal, DesignSpacing.sm)
        }
      }
      .padding(DesignSpacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        LinearGradient(
          colors: [theme.palette.accentSoft.color, DesignColor.contentSurface],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }
      .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    private var blocks: [Color] {
      [
        theme.palette.accent.color, DesignColor.warning.color, theme.palette.accentSoft.color,
        DesignColor.success.color, DesignColor.danger.color,
      ]
    }
  }

  private struct StatusSpecimens: View {
    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        FlowLayout { ForEach(StatusKind.allCases, id: \.self) { StatusChip($0) } }
        FlowLayout { ForEach(StatusKind.allCases, id: \.self) { StatusIndicator($0) } }
          .contentSurface(padding: DesignSpacing.md)
      }
    }
  }

  private struct UnreadSpecimens: View {
    var body: some View {
      FlowLayout {
        specimen("Unread") { UnreadMarker() }
        specimen("Count") { UnreadMarker(count: 7) }
        specimen("Capped") { UnreadMarker(count: 250) }
      }
      .contentSurface(padding: DesignSpacing.md)
    }

    private func specimen(_ title: String, marker: () -> UnreadMarker) -> some View {
      HStack(spacing: DesignSpacing.sm) {
        marker()
        Text(title).designFont(.supporting).foregroundStyle(.secondary)
      }
    }
  }

  private struct AgentTileSpecimens: View {
    var body: some View {
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: DesignSpacing.md) {
          AgentTile(
            initials: "AR", caption: "Atlas", selected: true, pinned: true, badge: .running(2))
          AgentTile(initials: "HO", caption: "Harbor", presence: .degraded, badge: .unread(3))
          AgentTile(initials: "QW", caption: "Quill")
          AgentTile(initials: "DH", caption: "Dormant", presence: .offline)
        }
        .padding(.horizontal, DesignSpacing.sm)
      }
      .contentSurface(padding: DesignSpacing.md)
    }
  }

  private struct ChipSpecimens: View {
    var body: some View {
      FlowLayout {
        ProjectChip("Field notes", color: .blue)
        ForEach(LabelColor.allCases, id: \.self) { TagChip($0.rawValue, color: $0) }
        ActivityIndicator(.running)
        ActivityIndicator(.lastKnown)
      }
      .contentSurface(padding: DesignSpacing.md)
    }
  }

  private struct RowSpecimens: View {
    private let rows: [ConversationRowContent] = [
      .init(
        leading: .symbol("bubble.left", label: "Conversation", tone: .neutral),
        title: "Weekly field notes", time: "40m", unread: true,
        preview: "Drafted the synthetic summary.", project: .init("Field notes", color: .blue),
        tags: [.init("Research", color: .teal), .init("Draft")]),
      .init(
        leading: .monogram("AR", label: "Atlas Research"), title: "Launch checklist",
        time: "2m", activity: .running, preview: "Working · 4 tool calls · $0.42",
        previewPending: true),
      .init(
        leading: .symbol("exclamationmark.triangle.fill", label: "Needs attention", tone: .danger),
        title: "Nightly import", time: "3h", activity: .lastKnown, preview: "Failed"),
      .init(
        leading: .folder(.amber), title: "Website refresh", preview: "2 chats · updated 2m",
        detail: "1 running"),
    ]

    var body: some View {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider() }
          ConversationRow(row)
        }
      }
      .contentSurface(padding: DesignSpacing.md)
    }
  }

  private struct BannerSpecimens: View {
    var body: some View {
      VStack(spacing: DesignSpacing.sm) {
        ConnectionBanner(
          .insecureHTTP, title: "Insecure HTTP",
          message: "Traffic can be read or changed on the network.")
        ConnectionBanner(
          .offline, title: "Offline", message: "Showing saved synthetic data.",
          actionTitle: "Retry", action: {})
        ConnectionBanner(
          .storage, title: "Storage warning", message: "Changes are in memory only.")
        ConnectionBanner(
          .problem, title: "Conversation list could not be refreshed.",
          message: "Showing the last synthetic list.", actionTitle: "Retry", action: {})
        ConnectionBanner(.notice, title: "Connect only to a console you trust")
      }
    }
  }

  private struct StateSpecimens: View {
    var body: some View {
      VStack(spacing: DesignSpacing.sm) {
        EmptyStateView(
          "No consoles yet", systemImage: "network",
          message: "Add the root URL of your web console to begin.",
          actionTitle: "Add console", action: {}
        )
        .contentSurface()
        ErrorStateView(
          "Connection failed", message: "Could not reach console.example.ts.net.",
          retryTitle: "Retry", retry: {}
        )
        .contentSurface()
        LoadingStateView("Checking console…").contentSurface()
      }
    }
  }

  /// Minimal wrapping layout for catalog specimens; items are centred within each line.
  private struct FlowLayout: Layout {
    var spacing: CGFloat = DesignSpacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      let layout = arrange(bounds.width, subviews)
      for (index, frame) in layout.frames.enumerated() {
        subviews[index].place(
          at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
          proposal: ProposedViewSize(frame.size))
      }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (
      frames: [CGRect], size: CGSize
    ) {
      var lines: [[(index: Int, size: CGSize)]] = [[]]
      var x: CGFloat = 0
      for (index, subview) in subviews.enumerated() {
        let size = subview.sizeThatFits(.init(width: width, height: nil))
        if x > 0, x + size.width > width {
          lines.append([])
          x = 0
        }
        lines[lines.count - 1].append((index, size))
        x += size.width + spacing
      }
      var frames = [CGRect](repeating: .zero, count: subviews.count)
      var y: CGFloat = 0
      var widest: CGFloat = 0
      for line in lines where !line.isEmpty {
        let height = line.map(\.size.height).max() ?? 0
        var x: CGFloat = 0
        for item in line {
          frames[item.index] = CGRect(
            origin: CGPoint(x: x, y: y + (height - item.size.height) / 2), size: item.size)
          x += item.size.width + spacing
        }
        widest = max(widest, min(x - spacing, width))
        y += height + spacing
      }
      return (frames, CGSize(width: widest, height: max(0, y - spacing)))
    }
  }

  #Preview("Catalog — evergreen") { DesignCatalogView(scenario: .evergreen) }
  #Preview("Catalog — ocean, dark") {
    DesignCatalogView(scenario: .ocean).preferredColorScheme(.dark)
  }
  #Preview("Catalog — accessibility size") { DesignCatalogView(scenario: .accessibility) }
  #Preview("Catalog — Reduce Transparency") {
    DesignCatalogView(scenario: .reduceTransparency)
  }
#endif
