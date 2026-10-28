// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import PhotosUI
import SwiftUI
import UIKit

/// The floating composer (web Composer.tsx): a Liquid Glass bar with attach, the multiline
/// field, model/effort and skills, and Send / Queue / Stop. Suggestions and submission status
/// sit above it on their own glass surface with a frosted reading veil.
struct ComposerBar: View {
  @Bindable var controller: ComposerController
  var jumpControl: TranscriptJumpControl? = nil
  @Environment(\.composerSampleAttachments) private var sampleAttachments
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  @FocusState private var focused: Bool
  /// Agent settings covers this conversation (iPad): the composer gives up keyboard focus.
  @Environment(\.coveredBySettings) private var covered
  @State private var showPhotos = false
  @State private var showFiles = false
  @State private var showCamera = false
  @State private var showSkills = false
  @State private var showSettings = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var browseRange: (start: Int, end: Int)?
  @State private var peerQuestion: PeerQuestionPresentation?

  private var store: ConsoleStore { controller.store }
  private var conversation: ConversationState? {
    controller.threadID.flatMap { store.conversations[$0] }
  }
  private var affordances: ComposerAffordances { controller.affordances }
  private var hasJobs: Bool { conversation?.jobItems.isEmpty == false }
  private var hasSuggestions: Bool {
    !controller.skillSuggestions.isEmpty || !controller.commandSuggestions.isEmpty
  }

  private var limits: UploadLimits? { store.bootstrap?.limits }
  private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

  @Environment(\.consoleTheme) private var theme

  /// Web `.thread-footer` dock: the job shelf first, then the composer, on a fade from the
  /// transcript into the panel; 8 pt gutters on phones, 24 on tablets, column ≤ 820.
  var body: some View {
    #if DEBUG
      let _ = PerformanceProbe.body("ComposerBar")
    #endif
    let regular = sizeClass == .regular
    VStack(spacing: 6) {
      if let state = conversation {
        ComposerJobDock(state: state, store: store) {
          peerQuestion = .init(question: $0)
        }
      }
      ComposerOverlay(
        controller: controller, onCommand: perform, onSkill: { controller.insertSkill($0) })
      composerRoot
    }
    .padding(.horizontal, regular ? WebSpace.dockGutterRegular : WebSpace.dockGutter)
    .padding(.bottom, regular ? 12 : 0)
    .frame(maxWidth: WebMetrics.composerWidth + 2 * WebSpace.dockGutterRegular)
    .frame(maxWidth: .infinity)
    .photosPicker(
      isPresented: $showPhotos, selection: $photoItems,
      maxSelectionCount: max(1, (limits?.maxFilesPerTurn ?? 10) - store.stagedAttachments.count),
      matching: .images
    )
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      photoItems = []
      Task { await stagePhotos(items) }
    }
    .fileImporter(
      isPresented: $showFiles,
      allowedContentTypes: AttachmentAdapter.importTypes(limits?.accept ?? []),
      allowsMultipleSelection: true
    ) { result in
      Task { await stageFiles(result) }
    }
    .fullScreenCover(isPresented: $showCamera) {
      CameraCapture { image in
        Task { await stageCamera(image) }
      }
      .ignoresSafeArea()
    }
    .sheet(isPresented: $showSkills) {
      SkillBrowserSheet(
        agentLabel: controller.agent?.label, registry: controller.skillRegistry,
        onRefresh: { await store.loadSkills(sourceID: controller.sourceID) }
      ) { name in
        controller.insertSkill(name, browseRange: browseRange ?? controller.caret)
      }
    }
    .sheet(isPresented: $showSettings) {
      RunSettingsSheet(controller: controller)
    }
    .sheet(item: $peerQuestion) { presentation in
      // No console route answers a peer: the reply is drafted for the operator to send.
      PeerQuestionAnswerSheet(question: presentation.question) { reply in
        controller.insertBlock(reply)
      }
    }
    .onChange(of: store.cronReplyNavigation, initial: true) { _, request in
      applyCronReplyFocus(request)
    }
    .onChange(of: controller.focusRequest) { focused = true }
    .onChange(of: covered, initial: true) { _, isCovered in
      controller.coveredBySettings = isCovered
      // Resign without touching the text, quote or staged files.
      if isCovered {
        focused = false
      } else {
        applyCronReplyFocus(store.cronReplyNavigation)
      }
    }
    .task(id: SkillLoadKey(source: controller.sourceID, live: store.connection == .live)) {
      // Load once the console is live; an offline attempt is retried when it reconnects.
      guard store.connection == .live, store.skillRegistries[controller.sourceID]?.canInsert != true
      else { return }
      await store.loadSkills(sourceID: controller.sourceID)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
    // Jump to latest is drawn above the dock by the conversation (`TranscriptJumpOverlay`),
    // never inside it, so the dock's geometry never depends on it. The dock publishes where
    // it is and whether its first surface is full-width material: that material supplies
    // the circle's lower part instead of stacking two glasses on the shelf.
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: {
      jumpControl?.dockFrame = $0
    }
    .onChange(of: hasJobs || !hasSuggestions, initial: true) { _, shares in
      jumpControl?.sharesDockMaterial = shares
    }
    .onDisappear { jumpControl?.dockFrame = nil }
  }

  private func applyCronReplyFocus(_ request: CronReplyNavigation?) {
    guard let request, request.threadID == controller.threadID, !covered else { return }
    focused = true
    store.consumeCronReplyFocus(request.id)
  }

  // MARK: Leading

  private var attachMenu: some View {
    Menu {
      if store.canUpload {
        Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
          .accessibilityIdentifier("attach-photos")
        Button("Files", systemImage: "folder") { showFiles = true }
          .accessibilityIdentifier("attach-files")
        if cameraAvailable {
          Button("Camera", systemImage: "camera") { showCamera = true }
            .accessibilityIdentifier("attach-camera")
        }
        #if DEBUG
          if sampleAttachments {
            Button("Sample files (synthetic)", systemImage: "doc.badge.plus") {
              Task { await stageSamples() }
            }
            .accessibilityIdentifier("attach-samples")
          }
        #endif
      } else {
        Text(attachUnavailableReason)
      }
      Divider()
      Button("Browse Skills", systemImage: "book.closed") { openSkills() }
    } label: {
      composerTool("Attach", systemImage: "paperclip")
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("Attach files or browse skills")
    .accessibilityIdentifier("composer-attach")
  }

  private var attachUnavailableReason: String {
    if controller.agent?.supportsAttachments == false {
      return "\(controller.agent?.label ?? "This agent") does not accept attachments"
    }
    return "Attachments are unavailable while offline"
  }

  // MARK: Composer root (web `.composer-root`)

  /// Radius 14 on phones / 16 on tablets; focus adds an accent edge and the 3 px accent glow.
  /// It floats above the transcript: one untinted Liquid Glass surface (GLASS-RULES.md), a
  /// light-mode line-strong stroke for the web edge, and the opaque web fill under Reduce
  /// Transparency. Everything inside uses glass inks, never a solid web surface.
  private var composerRoot: some View {
    let regular = sizeClass == .regular
    let shape = RoundedRectangle(
      cornerRadius: regular ? WebRadius.composerRegular : WebRadius.composer, style: .continuous)
    let fill = focused ? WebColor.surfaceRaised : WebColor.surfaceSubtle
    return VStack(alignment: .leading, spacing: 0) {
      if let quote = controller.quote {
        QuotePreview(QuoteFormatting.preview(quote)) { controller.quote = nil }
          .accessibilityIdentifier("quote-preview")
          .padding(.bottom, 6)
      }
      ComposerAttachments(controller: controller).padding(.bottom, 6)
      field
      toolbar
      if regular {
        Text("⌘↩ to send · / commands · $ skills")
          .webFont(.composerHint).foregroundStyle(WebGlass.textMuted.color)
          .lineLimit(1)
          .padding(.horizontal, 2)
          .accessibilityHidden(true)
      }
    }
    .padding(.top, regular ? 10 : 8)
    .padding(.horizontal, regular ? 10 : 8)
    .padding(.bottom, regular ? 8 : 6)
    .webGlassContent()
    .floatingGlass(in: shape, opaqueFill: fill.color, opaqueStroke: WebColor.lineStrong.color)
    .overlay(
      shape.strokeBorder(
        focused
          ? theme.palette.accent.color
          : WebColor.lineStrong.color(lightOpacity: 1, darkOpacity: 0), lineWidth: 1)
    )
    .background { if focused { shape.inset(by: -3).fill(theme.palette.accentGlow) } }
  }

  private var field: some View {
    TextField(
      "Message", text: $controller.text, selection: $controller.selection,
      prompt: Text(affordances.placeholder).foregroundStyle(WebGlass.textMuted.color),
      axis: .vertical
    )
    .lineLimit(1...8)
    .webFont(.composerInput)
    .foregroundStyle(WebColor.text.color)
    .padding(.vertical, 7)
    .padding(.horizontal, 5)
    .frame(minHeight: 37, alignment: .leading)
    .focused($focused)
    .accessibilityLabel("Message")
    .accessibilityIdentifier("composer-field")
    .onKeyPress(.upArrow) { moveHighlight(-1) }
    .onKeyPress(.downArrow) { moveHighlight(1) }
    .onKeyPress(.escape) {
      guard let trigger = controller.trigger else { return .ignored }
      controller.dismissedTrigger = trigger
      return .handled
    }
    .onKeyPress(.return, phases: .down) { press in
      // Return inserts a newline (web submitMode="ctrlEnter"); with suggestions open it
      // accepts the highlighted one. ⌘Return is the Send button's shortcut.
      guard !press.modifiers.contains(.command), acceptHighlighted() else { return .ignored }
      return .handled
    }
    .onKeyPress(.tab) { acceptHighlighted() ? .handled : .ignored }
  }

  /// Web `.composer-toolbar`: attach and skills on the left; context, model/effort, send and
  /// (while running) stop on the right. At accessibility sizes the right group wraps below.
  @ViewBuilder private var toolbar: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          tools
          Spacer(minLength: 0)
          actions
        }
        HStack(spacing: 4) {
          if let state = conversation {
            ComposerContextControl(state: state, store: store, fixed: false)
          }
          ModelSelectorMenu(controller: controller)
        }
      }
    } else {
      HStack(spacing: 10) {
        tools
        HStack(spacing: 4) {
          if let state = conversation { ComposerContextControl(state: state, store: store) }
          ModelSelectorMenu(controller: controller)
            .frame(maxWidth: .infinity, alignment: .leading)
          actions
        }
      }
      .frame(minHeight: 34)
    }
  }

  private var tools: some View {
    HStack(spacing: 5) {
      attachMenu
      Button {
        openSkills()
      } label: {
        composerTool("Browse skills", systemImage: "book")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Browse skills")
      .accessibilityIdentifier("composer-skills")
    }
  }

  /// A 32 pt composer tool glyph (`.composer-tool`) in a 44 pt hit target.
  private func composerTool(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .labelStyle(.iconOnly)
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(WebColor.textSoft.color)
      .frame(width: WebMetrics.quietControl, height: WebMetrics.quietControl)
      .frame(minWidth: 36, minHeight: DesignMetrics.minimumHitTarget)
      .contentShape(Rectangle())
  }

  private func openSkills() {
    browseRange = controller.caret
    showSkills = true
  }

  // MARK: Actions

  /// Web `.composer-send` (34 pt soft-accent square) and `.composer-stop` (surface-hover).
  /// Send and stop coexist while a reply runs; stop never replaces send.
  private var actions: some View {
    let palette = theme.palette
    let tile = RoundedRectangle(cornerRadius: WebRadius.tile, style: .continuous)
    return HStack(spacing: 6) {
      Button {
        Task { await controller.send() }
      } label: {
        Image(systemName: "paperplane")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(WebGlass.accentText(palette).color)
          .frame(width: WebMetrics.send, height: WebMetrics.send)
          .background(palette.accentInk, in: tile)
          .opacity(affordances.primaryEnabled ? 1 : 0.45)
          .frame(minWidth: 40, minHeight: DesignMetrics.minimumHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!affordances.primaryEnabled)
      .keyboardShortcut(.return, modifiers: .command)
      .accessibilityLabel(primaryTitle)
      .accessibilityHint(affordances.unavailableReason ?? "")
      .accessibilityIdentifier(affordances.primary == .queue ? "composer-queue" : "composer-send")
      if affordances.showsStop {
        Button {
          Task { await controller.stop() }
        } label: {
          Image(systemName: "stop.fill")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(WebColor.text.color)
            .frame(width: WebMetrics.send, height: WebMetrics.send)
            .background(WebGlass.selectedFill.color, in: tile)
            .opacity(controller.stopping ? 0.45 : 1)
            .frame(minWidth: 40, minHeight: DesignMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.stopping)
        .keyboardShortcut(".", modifiers: .command)
        .accessibilityLabel(controller.stopping ? "Stopping response" : "Stop response")
        .accessibilityIdentifier("composer-stop")
      }
    }
  }

  private var primaryTitle: String {
    affordances.primary == .queue ? "Send as live input" : "Send message"
  }

  // MARK: Suggestions keyboard

  private var suggestionCount: Int {
    controller.skillSuggestions.count + controller.commandSuggestions.count
  }
  private func moveHighlight(_ delta: Int) -> KeyPress.Result {
    guard suggestionCount > 0 else { return .ignored }
    controller.highlightedSuggestion =
      (controller.highlightedSuggestion + delta + suggestionCount) % suggestionCount
    return .handled
  }
  private func acceptHighlighted() -> Bool {
    let skills = controller.skillSuggestions
    let commands = controller.commandSuggestions
    let index = controller.highlightedSuggestion
    if skills.indices.contains(index) {
      controller.insertSkill(skills[index].name)
      return true
    }
    if commands.indices.contains(index) {
      perform(controller.run(commands[index]))
      return true
    }
    return false
  }

  private func perform(_ command: ComposerCommand) {
    switch command {
    case .settings: showSettings = true
    case .stop: Task { await controller.stop() }
    case .new: controller.requestNewConversation()
    }
  }

  // MARK: Attachment sources

  private func stagePhotos(_ items: [PhotosPickerItem]) async {
    var files: [UploadFile] = []
    var previews: [String: UIImage] = [:]
    let accept = limits?.accept ?? []
    for (index, item) in items.enumerated() {
      guard let data = try? await item.loadTransferable(type: Data.self) else {
        controller.uploadError = "A photo could not be read from the library."
        continue
      }
      let type = item.supportedContentTypes.first
      var name = "photo-\(index + 1)." + (type?.preferredFilenameExtension ?? "jpg")
      var bytes = data
      // HEIC and other library formats are converted when the console only accepts JPEG/PNG.
      if let mime = type?.preferredMIMEType, !AttachmentAdapter.accepts(mime, accept),
        AttachmentAdapter.accepts("image/jpeg", accept), let image = UIImage(data: data),
        let jpeg = image.jpegData(compressionQuality: 0.9)
      {
        bytes = jpeg
        name = "photo-\(index + 1).jpg"
      }
      if let file = try? AttachmentAdapter.stage(data: bytes, name: name) {
        files.append(file)
        previews[name] = UIImage(data: bytes)?.preparingThumbnail(of: CGSize(width: 96, height: 96))
      }
    }
    guard !files.isEmpty else { return }
    await controller.stage(files, previews: previews)
  }

  private func stageFiles(_ result: Result<[URL], any Error>) async {
    guard case .success(let urls) = result else {
      controller.uploadError = "The selected files could not be opened."
      return
    }
    var files: [UploadFile] = []
    for url in urls {
      do {
        files.append(try AttachmentAdapter.stage(copyOf: url))
      } catch {
        controller.uploadError = "\(url.lastPathComponent) could not be read."
      }
    }
    guard !files.isEmpty else { return }
    await controller.stage(files)
  }

  private func stageCamera(_ image: UIImage) async {
    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
    let name = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
    guard let file = try? AttachmentAdapter.stage(data: data, name: name) else { return }
    await controller.stage(
      [file], previews: [name: image.preparingThumbnail(of: CGSize(width: 96, height: 96)) ?? image]
    )
  }

  #if DEBUG
    /// DEBUG fixture source only: two synthetic files through the same Store upload path.
    private func stageSamples() async {
      let text = Data("Fictional field notes for the sample release.\n".utf8)
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
      let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        UIColor.white.setFill()
        context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
      }
      guard let png = image.pngData(),
        let note = try? AttachmentAdapter.stage(data: text, name: "field-notes.txt"),
        let photo = try? AttachmentAdapter.stage(data: png, name: "sample-photo.png")
      else { return }
      await controller.stage([note, photo], previews: ["sample-photo.png": image])
    }
  #endif
}

private struct SkillLoadKey: Hashable {
  let source: String
  let live: Bool
}

/// Staged chips and uploading rows (web `ComposerAttachments`).
struct ComposerAttachments: View {
  let controller: ComposerController
  var body: some View {
    let store = controller.store
    if !store.stagedAttachments.isEmpty || !store.uploadProgress.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: DesignSpacing.sm) {
          ForEach(store.stagedAttachments, id: \.id) { attachment in
            AttachmentChip(
              name: attachment.name, detail: AttachmentAdapter.byteCount(attachment.sizeBytes),
              isImage: attachment.kind == "image" || attachment.contentType.hasPrefix("image/"),
              thumbnail: controller.previews[attachment.id].map(Image.init(uiImage:))
            ) {
              Task { await controller.remove(attachment) }
            }
            .accessibilityIdentifier("attachment-" + attachment.name)
          }
          ForEach(store.uploadProgress) { item in
            AttachmentChip(
              name: item.name, detail: AttachmentAdapter.byteCount(item.sizeBytes),
              isImage: item.contentType.hasPrefix("image/"),
              thumbnail: controller.previews["name:" + item.name].map(Image.init(uiImage:)),
              phase: .uploading(item.fraction))
          }
        }
      }
      .scrollIndicators(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("composer-attachments")
    }
  }
}

/// Suggestions and the submission status above the glass bar. Both float over the transcript
/// and carry text: one glass surface each with the frosted sheet veil (GLASS-RULES.md).
struct ComposerOverlay: View {
  let controller: ComposerController
  let onCommand: (ComposerCommand) -> Void
  let onSkill: (String) -> Void

  var body: some View {
    let skills = controller.skillSuggestions
    let commands = controller.commandSuggestions
    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
      if !skills.isEmpty || !commands.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.name) { index, skill in
              Button {
                onSkill(skill.name)
              } label: {
                SuggestionRow(
                  skill.reference ?? "$" + skill.name, subtitle: skill.description,
                  badge: SkillDiscovery.statusLabel(skill),
                  highlighted: index == controller.highlightedSuggestion)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("skill-suggestion-" + skill.name)
            }
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
              Button {
                onCommand(controller.run(command))
              } label: {
                SuggestionRow(
                  command.label, subtitle: command.detail, systemImage: command.systemImage,
                  highlighted: skills.count + index == controller.highlightedSuggestion)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("command-suggestion-" + command.rawValue)
            }
          }
        }
        .frame(maxHeight: 310)
        .fixedSize(horizontal: false, vertical: true)
        // Web `.composer-trigger-popover` geometry: radius 12, padding 5, at most 320 pt wide,
        // anchored 9 pt in from the composer's leading edge. Glass + veil replace the raised
        // fill and shadow-lg; light mode keeps the line-strong edge as a stroke.
        .padding(5)
        .webGlassContent()
        .background(
          WebGlass.sheetVeil.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .floatingGlass(
          in: RoundedRectangle(cornerRadius: 12, style: .continuous),
          opaqueFill: WebColor.surfaceRaised.color, opaqueStroke: WebColor.lineStrong.color
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
              WebColor.lineStrong.color(lightOpacity: 1, darkOpacity: 0), lineWidth: 1)
        )
        .frame(maxWidth: 320)
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
          "\(skills.count + commands.count) suggestion\(skills.count + commands.count == 1 ? "" : "s")"
        )
        .accessibilityIdentifier("composer-suggestions")
      }
      ComposerStatusLine(controller: controller)
    }
  }
}

/// Pending, confirmed, uncertain and failed submission states, plus upload/stop errors and
/// compaction. Each has a symbol and words, never colour alone; Retry is explicit.
struct ComposerStatusLine: View {
  let controller: ComposerController
  var body: some View {
    let phase = controller.phase
    let messages = lines
    if phase != .idle || !messages.isEmpty {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        if let label = ComposerRules.label(phase) {
          HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
            StatusIndicator(kind(phase), label: label)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if phase.allowsRetry {
              Button("Retry") { Task { await controller.retry() } }
                .designButtonStyle(.primary)
                .controlSize(.small)
                .accessibilityHint("Sends the same message again with the same submission ID")
                .accessibilityIdentifier("composer-retry")
              Button("Dismiss", systemImage: "xmark") { controller.dismissStatus() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("composer-status")
        }
        ForEach(messages, id: \.self) { message in
          StatusIndicator(.failed, label: message).fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(DesignSpacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .webGlassContent()
      .background(
        WebGlass.sheetVeil.color,
        in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
      )
      .floatingGlass(
        in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous),
        opaqueFill: DesignColor.contentSurface)
    }
  }

  private var lines: [String] {
    [
      controller.uploadError, controller.stopError,
      controller.compacting ? "Compacting context — you can send when it finishes." : nil,
    ].compactMap { $0 }
  }

  private func kind(_ phase: ComposerPhase) -> StatusKind {
    switch phase {
    case .sending: .connecting
    case .confirmed: .online
    case .uncertain: .stale
    case .failed: .failed
    case .idle: .disconnected
    }
  }
}

/// System camera capture. Hidden when unavailable (e.g. the Simulator); the system asks for
/// camera permission on first use, using the Info.plist usage description.
struct CameraCapture: UIViewControllerRepresentable {
  let onImage: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }
  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate
  {
    let parent: CameraCapture
    init(_ parent: CameraCapture) { self.parent = parent }
    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
      parent.dismiss()
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
  }
}

extension EnvironmentValues {
  /// DEBUG fixture scenarios offer a synthetic attachment source; always false in Release.
  @Entry var composerSampleAttachments = false
}
