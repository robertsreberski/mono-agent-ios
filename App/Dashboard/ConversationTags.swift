// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ConversationTags: View {
  let store: ConsoleStore
  let thread: WebThread
  @State private var open = false
  @State private var editing = false
  @State private var editor: TagEditorRequest?
  @State private var pendingEditor: TagEditorRequest?
  private var tags: [WebTag] { store.tags.filter { $0.sourceId == thread.sourceId } }
  var body: some View {
    HStack(spacing: 6) {
      ForEach(tags.filter { thread.tagIds.contains($0.id) }, id: \.id) { tag in
        TagBadge(tag.name, color: LabelColor(serverValue: tag.color))
          .padding(.horizontal, 8).frame(minHeight: 20)
          .background(WebGlass.selectedFill.color, in: Capsule())
      }
      Button {
        editing = false
        open = true
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "tag").font(.system(size: 12))
          if thread.tagIds.isEmpty { Text("Add tag").webFont(.breadcrumb) }
        }.frame(minWidth: 28, minHeight: 32).contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(WebGlass.textMuted.color)
      .accessibilityLabel("Conversation tags")
      .accessibilityValue(
        thread.tagIds.isEmpty
          ? "No tags"
          : tags.filter { thread.tagIds.contains($0.id) }.map(\.name).joined(separator: ", ")
      )
      .accessibilityIdentifier("conversation-tags")
      .popover(isPresented: $open, arrowEdge: .top) {
        OrganizeMenuScroll {
          if editing {
            OrganizeMenuRow("Edit tags", systemImage: "chevron.left") { editing = false }
          }
          if tags.isEmpty {
            Text("No tags yet").webFont(.system).foregroundStyle(WebGlass.textMuted.color).padding(
              12)
          }
          ForEach(tags, id: \.id) { tag in
            Button {
              if editing {
                pendingEditor = .init(sourceID: thread.sourceId, tagID: tag.id)
              } else {
                let ids =
                  thread.tagIds.contains(tag.id)
                  ? thread.tagIds.filter { $0 != tag.id } : thread.tagIds + [tag.id]
                Task { try? await store.setConversationTags(threadID: thread.id, tagIDs: ids) }
              }
              open = false
            } label: {
              HStack(spacing: 10) {
                TagBadge(tag.name, color: LabelColor(serverValue: tag.color))
                Spacer()
                if !editing && thread.tagIds.contains(tag.id) {
                  Image(systemName: "checkmark").font(.system(size: 14))
                }
              }.padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              editing
                ? "Edit \(tag.name)"
                : "\(thread.tagIds.contains(tag.id) ? "Remove" : "Add") \(tag.name)"
            )
            .accessibilityIdentifier("tag-menu-\(tag.id)")
          }
          if !editing {
            WebHairline().padding(.vertical, 4)
            OrganizeMenuRow("New tag…", systemImage: "plus") {
              pendingEditor = .init(sourceID: thread.sourceId, threadID: thread.id)
              open = false
            }.accessibilityIdentifier("new-tag")
            if !tags.isEmpty {
              OrganizeMenuRow("Edit tags", systemImage: "slider.horizontal.3") { editing = true }
                .accessibilityIdentifier("edit-tags")
            }
          }
        }
        .accessibilityIdentifier("tag-picker-scroll")
        .disabled(!store.canOrganize || store.pendingConversationActions[thread.id] != nil)
        .padding(4).frame(width: 280)
        .webSheetVeil()
        .presentationCompactAdaptation(.popover)
        .task { await store.refreshOrganizeLabels(sourceID: thread.sourceId) }
        .onDisappear {
          if let pendingEditor {
            editor = pendingEditor
            self.pendingEditor = nil
          }
        }
      }
    }
    .sheet(item: $editor) { TagSettings(store: store, request: $0) }
    .onChange(of: store.selectedThreadID) {
      open = false
      editor = nil
      pendingEditor = nil
    }
  }
}
