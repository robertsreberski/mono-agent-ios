// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct TagEditorRequest: Identifiable {
  let id = UUID()
  let sourceID: String
  var tagID: String?
  var threadID: String?
}

struct TagSettings: View {
  let store: ConsoleStore
  let request: TagEditorRequest
  @Environment(\.dismiss) private var dismiss
  @State private var name: String = ""
  @State private var color = LabelColor.standard
  @State private var saving = false
  @State private var initialized = false
  @State private var active = true
  @State private var error: String?
  @State private var createdID: String?
  private var tag: WebTag? { store.tags.first { $0.id == request.tagID } }
  private var editing: Bool { request.tagID != nil }
  private var valid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
      && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
      && (!editing
        || tag.map {
          $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
            || $0.color != color.rawValue
        } == true)
  }
  var body: some View {
    VStack(spacing: 0) {
      OrganizeSheetHeader(
        editing ? "Tag settings" : "New tag", saving: saving, canSave: valid && store.canOrganize,
        cancel: { dismiss() }, save: { Task { await save() } })
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if editing && tag == nil {
            Text("This tag is no longer available.")
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Eyebrow("Name")
              TextField("Tag name", text: $name).accessibilityIdentifier("tag-name")
                .padding(12).background(
                  WebColor.surfaceSubtle.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }.disabled(createdID != nil)
            VStack(alignment: .leading, spacing: 8) {
              Eyebrow("Color")
              LabelPalette(selection: $color, colors: LabelColor.allCases, kind: "tag")
            }.disabled(createdID != nil)
            if let tag {
              OrganizeMenuRow(
                "Delete tag", systemImage: "trash", detail: "Keeps chats", destructive: true
              ) { store.requestTagDeletion(id: tag.id) }
              .background(
                WebColor.surfaceSubtle.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)
              )
              .accessibilityIdentifier("delete-tag")
            }
          }
          if let error {
            Text(error).foregroundStyle(WebColor.danger.color).accessibilityIdentifier("tag-error")
          }
        }.webFont(.system).padding(17).disabled(saving)
      }
    }
    .presentationDragIndicator(.visible)
    .presentationDetents([.height(editing ? 360 : 300), .large])
    .accessibilityElement(children: .contain).accessibilityIdentifier("tag-settings")
    .onAppear {
      guard !initialized else { return }
      initialized = true
      name = tag?.name ?? ""
      color = LabelColor(serverValue: tag?.color)
    }
    .onChange(of: store.selectedBucket) { dismiss() }
    .onChange(of: store.selectedThreadID) { dismiss() }
    .onDisappear {
      active = false
      store.cancelTagDeletion()
    }
    .alert(
      "Delete tag",
      isPresented: Binding(get: { store.tagDeletionConfirmation != nil }, set: { _ in }),
      presenting: store.tagDeletionConfirmation
    ) { request in
      Button("Cancel", role: .cancel) { store.cancelTagDeletion() }
      Button("Delete tag", role: .destructive) {
        Task {
          saving = true
          defer { saving = false }
          do {
            try await store.confirmTagDeletion(request.id)
            dismiss()
          } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
      }
    } message: {
      Text($0.message)
    }
  }

  private func save() async {
    guard valid, !saving else { return }
    saving = true
    error = nil
    defer { saving = false }
    do {
      if let tag {
        try await store.updateTag(id: tag.id, name: name, color: color.rawValue)
      } else {
        let id: String
        if let createdID {
          id = createdID
        } else {
          id = try await store.createTag(
            sourceID: request.sourceID, name: name, color: color.rawValue
          ).id
          createdID = id
        }
        guard active else { return }
        if let threadID = request.threadID {
          let existing =
            store.conversations[threadID]?.thread.tagIds
            ?? store.buckets.values.flatMap(\.threads).first { $0.id == threadID }?.tagIds ?? []
          try await store.setConversationTags(threadID: threadID, tagIDs: existing + [id])
        }
      }
      if active { dismiss() }
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}
