// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import PhotosUI
import SwiftUI
import UIKit

/// The floating composer (web Composer.tsx): a Liquid Glass bar with attach, the multiline
/// field, model/effort and skills, and Send / Queue / Stop. Suggestions and submission status
/// sit above it on an opaque surface, because they are content, not controls.
struct ComposerBar: View {
  @Bindable var controller: ComposerController
  @Environment(\.composerSampleAttachments) private var sampleAttachments
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  @FocusState private var focused: Bool
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
  private var limits: UploadLimits? { store.bootstrap?.limits }
  private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

  var body: some View {
    VStack(spacing: DesignSpacing.xs) {
      if let state = conversation {
        ComposerJobDock(state: state, store: store) { peerQuestion = .init(question: $0) }
      }
      ComposerOverlay(
        controller: controller, onCommand: perform,
        onSkill: { controller.insertSkill($0) })
      ComposerBarShell {
        attachMenu
      } field: {
        field
      } trailing: {
        trailing
      }
    }
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
    .onChange(of: controller.focusRequest) { focused = true }
    .task(id: SkillLoadKey(source: controller.sourceID, live: store.connection == .live)) {
      // Load once the console is live; an offline attempt is retried when it reconnects.
      guard store.connection == .live, store.skillRegistries[controller.sourceID]?.canInsert != true
      else { return }
      await store.loadSkills(sourceID: controller.sourceID)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
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
      Label("Attach", systemImage: "plus")
    }
    .labelStyle(.iconOnly)
    .designButtonStyle(.secondary, placement: .floating)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .accessibilityLabel("Attach files or browse skills")
    .accessibilityIdentifier("composer-attach")
  }

  private var attachUnavailableReason: String {
    if controller.agent?.supportsAttachments == false {
      return "\(controller.agent?.label ?? "This agent") does not accept attachments"
    }
    return "Attachments are unavailable while offline"
  }

  // MARK: Field

  private var field: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      if let quote = controller.quote {
        QuotePreview(QuoteFormatting.preview(quote)) { controller.quote = nil }
          .accessibilityIdentifier("quote-preview")
      }
      ComposerAttachments(controller: controller)
      TextField(
        "Message", text: $controller.text, selection: $controller.selection,
        prompt: Text(affordances.placeholder), axis: .vertical
      )
      .lineLimit(1...8)
      .designFont(.body)
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

      // The keyboard hint only appears when it fits beside the controls (web hides it on
      // phones); the model summary falls back to its icon before it truncates.
      ViewThatFits(in: .horizontal) {
        toolRow(compactModel: false, hint: sizeClass == .regular)
        toolRow(compactModel: false, hint: false)
        // Phones: keep the model name readable and give context its own line.
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          toolRow(compactModel: false, hint: false, context: false)
          if let state = conversation { ComposerContextControl(state: state, store: store) }
        }
        toolRow(compactModel: true, hint: false)
        // Accessibility sizes: context moves to its own line and may wrap.
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          toolRow(compactModel: true, hint: false, context: false)
          if let state = conversation {
            ComposerContextControl(state: state, store: store, fixed: false)
          }
        }
      }
    }
  }

  private func toolRow(compactModel: Bool, hint: Bool, context: Bool = true) -> some View {
    HStack(spacing: DesignSpacing.sm) {
      ModelSelectorMenu(controller: controller, compact: compactModel)
      if context, let state = conversation {
        ComposerContextControl(state: state, store: store)
      }
      Button {
        openSkills()
      } label: {
        Image(systemName: "book.closed")
          .frame(
            minWidth: DesignMetrics.minimumHitTarget, minHeight: DesignMetrics.minimumHitTarget
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Browse skills")
      .accessibilityIdentifier("composer-skills")
      Spacer(minLength: 0)
      if hint {
        Text("⌘↩ to send · / commands · $ skills")
          .designFont(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
          .accessibilityHidden(true)
      }
    }
  }

  private func openSkills() {
    browseRange = controller.caret
    showSkills = true
  }

  // MARK: Trailing

  private var trailing: some View {
    // At accessibility sizes the two round buttons stack, leaving the field its width.
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: DesignSpacing.sm))
      : AnyLayout(HStackLayout(spacing: DesignSpacing.sm))
    return layout {
      if affordances.showsStop {
        Button("Stop response", systemImage: "stop.fill") { Task { await controller.stop() } }
          .labelStyle(.iconOnly)
          .designButtonStyle(.secondary, placement: .floating)
          .buttonBorderShape(.circle)
          .controlSize(.large)
          .disabled(controller.stopping)
          .keyboardShortcut(".", modifiers: .command)
          .accessibilityLabel(controller.stopping ? "Stopping response" : "Stop response")
          .accessibilityIdentifier("composer-stop")
      }
      Button(primaryTitle, systemImage: primaryImage) { Task { await controller.send() } }
        .labelStyle(.iconOnly)
        .designButtonStyle(.primary, placement: .floating)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!affordances.primaryEnabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(primaryTitle)
        .accessibilityHint(affordances.unavailableReason ?? "")
        .accessibilityIdentifier(affordances.primary == .queue ? "composer-queue" : "composer-send")
    }
  }

  private var primaryTitle: String {
    affordances.primary == .queue ? "Send as live input" : "Send message"
  }
  private var primaryImage: String {
    affordances.primary == .queue ? "text.append" : "arrow.up"
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

/// Suggestions and the submission status above the glass bar, on an opaque surface.
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
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .contentSurface(padding: DesignSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
          "\(skills.count + commands.count) suggestion\(skills.count + commands.count == 1 ? "" : "s")"
        )
        .accessibilityIdentifier("composer-suggestions")
      }
      ComposerStatusLine(controller: controller)
    }
    .padding(.horizontal, DesignSpacing.md)
    .frame(maxWidth: DesignMetrics.readableWidth + 2 * DesignSpacing.md)
    .frame(maxWidth: .infinity)
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
      .contentSurface(padding: DesignSpacing.sm)
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
