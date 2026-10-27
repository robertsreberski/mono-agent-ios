// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct ConversationTags: View {
  let store: ConsoleStore
  let thread: WebThread
  @State private var editor: TagEditorRequest?
  private var tags: [WebTag] { store.tags.filter { $0.sourceId == thread.sourceId } }
  private var selected: [WebTag] { tags.filter { thread.tagIds.contains($0.id) } }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(selected, id: \.id) { tag in
        TagBadge(tag.name, color: LabelColor(serverValue: tag.color))
          .padding(.horizontal, 8).frame(minHeight: 20)
          .background(WebGlass.selectedFill.color, in: Capsule())
          .fixedSize()
      }
      Menu {
        if tags.isEmpty { Text("No tags yet") }
        ForEach(tags, id: \.id) { tag in
          Toggle(
            tag.name,
            isOn: Binding(
              get: { thread.tagIds.contains(tag.id) },
              set: { included in
                let ids =
                  included
                  ? thread.tagIds + [tag.id] : thread.tagIds.filter { $0 != tag.id }
                Task { try? await store.setConversationTags(threadID: thread.id, tagIDs: ids) }
              }
            )
          )
          .accessibilityLabel(
            "\(thread.tagIds.contains(tag.id) ? "Remove" : "Add") \(tag.name)"
          )
          .accessibilityIdentifier("tag-menu-\(tag.id)")
        }
        Divider()
        Button("New tag…", systemImage: "plus") {
          editor = .init(sourceID: thread.sourceId, threadID: thread.id)
        }
        .accessibilityIdentifier("new-tag")
        if !tags.isEmpty {
          Menu {
            ForEach(tags, id: \.id) { tag in
              Button {
                editor = .init(sourceID: thread.sourceId, tagID: tag.id)
              } label: {
                Label("Edit \(tag.name)", systemImage: "pencil")
              }
              .accessibilityLabel("Edit \(tag.name)")
              .accessibilityIdentifier("tag-menu-\(tag.id)")
            }
          } label: {
            Label("Edit tags", systemImage: "slider.horizontal.3")
          }
          .accessibilityIdentifier("edit-tags")
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "tag").font(.system(size: 12))
          if selected.isEmpty { Text("Add tag").webFont(.breadcrumb) }
        }
        .frame(minWidth: 28, minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(WebGlass.textMuted.color)
      .disabled(!store.canOrganize || store.pendingConversationActions[thread.id] != nil)
      .accessibilityLabel("Conversation tags")
      .accessibilityValue(
        selected.isEmpty ? "No tags" : selected.map(\.name).joined(separator: ", ")
      )
      .accessibilityIdentifier("conversation-tags")
    }
    .fixedSize(horizontal: true, vertical: false)
    .sheet(item: $editor) { TagSettings(store: store, request: $0) }
    .onChange(of: store.selectedThreadID) { editor = nil }
  }
}
