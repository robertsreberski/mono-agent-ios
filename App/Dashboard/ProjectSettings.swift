// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ProjectEditorRequest: Identifiable {
  let id = UUID()
  let sourceID: String
  var projectID: String?
  var threadID: String?
}

struct ProjectSettings: View {
  let store: ConsoleStore
  let request: ProjectEditorRequest
  var saved: (WebProject) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var context = ""
  @State private var color = LabelColor.standard
  @State private var saving = false
  @State private var error: String?
  @State private var initialized = false
  @State private var active = true
  @State private var created: WebProject?
  private var project: WebProject? { store.projects.first { $0.id == request.projectID } }
  private var editing: Bool { request.projectID != nil }
  private var canSave: Bool {
    store.canOrganize && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && name.count <= 120 && context.count <= 4000
      && (!editing
        || project.map {
          $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || $0.context != context
            || ($0.color ?? "default") != color.rawValue
        } == true)
  }
  var body: some View {
    VStack(spacing: 0) {
      OrganizeSheetHeader(
        editing ? "Project settings" : "New project", saving: saving, canSave: canSave,
        cancel: { dismiss() }, save: { Task { await save() } })
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if editing && project == nil {
            Text("This project is no longer available.").webFont(.system)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Eyebrow("Name")
              TextField("Project name", text: $name).accessibilityIdentifier("project-name")
                .disabled(created != nil)
                .padding(12).background(
                  WebColor.surfaceSubtle.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
              Eyebrow("Color")
              LabelPalette(
                selection: $color, colors: [.standard, .blue, .purple, .amber, .rose],
                kind: "project"
              ).disabled(created != nil)
            }
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Eyebrow("Context")
                Spacer()
                Text("\(context.count) chars").webFont(.contextNote)
              }
              TextField(
                "Shared briefing for every conversation in this project", text: $context,
                axis: .vertical
              )
              .lineLimit(5...10).padding(12)
              .background(
                WebColor.surfaceSubtle.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)
              )
              .accessibilityLabel("Project context").accessibilityIdentifier("project-context")
              Text(
                "Prepended to every conversation in this project. Existing conversations pick it up on their next turn."
              )
              .webFont(.contextNote).foregroundStyle(WebColor.textMuted.color)
            }
            .disabled(created != nil)
            if editing, let project {
              VStack(spacing: 0) {
                OrganizeMenuRow("Archive project", systemImage: "archivebox", detail: "Keeps chats")
                { store.requestProjectConfirmation(id: project.id, archive: true) }
                OrganizeMenuRow(
                  "Delete project", systemImage: "trash", detail: "Chats move to agent",
                  destructive: true
                ) { store.requestProjectConfirmation(id: project.id) }
                .accessibilityIdentifier("delete-project")
              }.background(
                WebColor.surfaceSubtle.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
              Text(
                "Created \(createdLabel(project.createdAt)) · \(store.agents.first { $0.sourceId == request.sourceID }?.label ?? "agent")"
              )
              .webFont(.contextNote).foregroundStyle(WebColor.textMuted.color)
            }
          }
          if let error {
            Text(error).foregroundStyle(WebColor.danger.color).accessibilityIdentifier(
              "project-error")
          }
        }
        .webFont(.system).padding(17).disabled(saving)
      }
    }
    .presentationDragIndicator(.visible)
    .presentationDetents([.height(editing ? 680 : 540), .large])
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("project-settings")
    .onAppear {
      guard !initialized else { return }
      initialized = true
      name = project?.name ?? ""
      context = project?.context ?? ""
      color = LabelColor(serverValue: project?.color)
    }
    .onChange(of: store.selectedBucket) { dismiss() }
    .onChange(of: store.selectedThreadID) { dismiss() }
    .alert(
      "\(store.projectConfirmation?.archive == true ? "Archive" : "Delete") project",
      isPresented: Binding(
        get: { store.projectConfirmation != nil },
        set: { _ in }),
      presenting: store.projectConfirmation
    ) { request in
      Button("Cancel", role: .cancel) { store.cancelProjectConfirmation() }
      Button(request.archive ? "Archive project" : "Delete project", role: .destructive) {
        Task {
          saving = true
          defer { saving = false }
          do {
            try await store.confirmProjectAction(request.id)
            dismiss()
          } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
      }
    } message: {
      Text($0.message)
    }
    .onDisappear {
      active = false
      store.cancelProjectConfirmation()
    }
  }

  private func createdLabel(_ stamp: String) -> String {
    let parts = stamp.prefix(10).split(separator: "-")
    let months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month),
      let day = Int(parts[2])
    else { return stamp }
    return "\(day) \(months[month - 1])"
  }

  private func save() async {
    guard canSave, !saving else { return }
    saving = true
    error = nil
    defer { saving = false }
    do {
      let value: WebProject
      if let project {
        try await store.updateProject(
          id: project.id, name: name, color: color.rawValue, context: context)
        value = store.projects.first { $0.id == project.id } ?? project
      } else {
        if let created {
          value = created
        } else {
          value = try await store.createProject(
            sourceID: request.sourceID, name: name, color: color.rawValue, context: context)
          created = value
        }
        if let threadID = request.threadID {
          try await store.assignConversationProject(threadID: threadID, projectID: value.id)
        }
      }
      guard active else { return }
      saved(value)
      dismiss()
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}
