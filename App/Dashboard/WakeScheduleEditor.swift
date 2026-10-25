// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct WakeEditorRequest: Identifiable {
  let id: UUID
  let threadID: String
}
struct WakeScheduleEditor: View {
  let store: ConsoleStore
  let request: WakeEditorRequest
  @Environment(\.dismiss) private var dismiss
  @Environment(\.consoleTheme) private var theme
  private var state: WakeEditorState? {
    store.wakeEditor.flatMap { $0.id == request.id ? $0 : nil }
  }
  private var thread: WebThread? { store.conversations[request.threadID]?.thread }
  private var archived: Bool { thread?.archivedAt != nil }
  private var supportsCompact: Bool {
    store.agents.first { $0.sourceId == thread?.sourceId }?.supportsManualCompaction == true
  }
  private var draft: WakeDraft { state?.draft ?? WakeDraft() }
  private var issues: WakeIssues { WakeScheduleModel.validate(draft) }
  private func binding<Value>(_ key: WritableKeyPath<WakeDraft, Value>) -> Binding<Value> {
    Binding(
      get: { draft[keyPath: key] },
      set: { value in
        var next = draft
        next[keyPath: key] = value
        store.editWakeDraft(request.id, draft: next)
      })
  }
  var body: some View {
    VStack(spacing: 0) {
      OrganizeSheetHeader(
        "Scheduled wake-up", saving: state?.busy == .save,
        canSave: state?.loaded == true && state?.busy == nil && state?.dirty == true
          && !issues.hasIssues && !archived && store.canOrganize,
        cancel: { dismiss() }, save: { store.mutateWakeEditor(request.id, action: .save) })
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            alerts.id("wake-alerts")
            summary
            if state?.loaded == true {
              VStack(alignment: .leading, spacing: 22) {
                whenFields
                zoneFields
                Toggle("Compact conversation first", isOn: binding(\.compactFirst))
                  .disabled(!supportsCompact && !draft.compactFirst).accessibilityIdentifier(
                    "wake-compact-first")
                Text(
                  supportsCompact
                    ? "Compact before the scheduled request. The wake-up still runs if compaction fails or is skipped."
                    : "This agent does not support manual compaction. The wake-up will still run without it."
                )
                .webFont(.sheetSubtitle).foregroundStyle(WebGlass.textMuted.color)
                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Eyebrow("Message")
                    Spacer()
                    Text("Optional").foregroundStyle(WebGlass.textMuted.color)
                  }
                  TextField(
                    "What should the agent pick up when it wakes?", text: binding(\.message),
                    prompt: Text("What should the agent pick up when it wakes?")
                      .foregroundStyle(WebGlass.textMuted.color), axis: .vertical
                  )
                  .lineLimit(3...5).padding(12).groupingFill().accessibilityIdentifier(
                    "wake-message")
                  Text("Sent to the agent as your message when this conversation wakes.").webFont(
                    .sheetSubtitle
                  ).foregroundStyle(WebGlass.textMuted.color)
                  let bytes = WakeScheduleModel.utf8Bytes(draft.message)
                  if bytes >= WakeScheduleModel.messageCounterFrom {
                    Text("\(bytes) / 1000 bytes").webFont(.sheetSubtitle)
                  }
                  issue(issues.message)
                }
              }.disabled(state?.busy != nil || !store.canOrganize)
              if state?.schedule != nil {
                OrganizeMenuRow("Delete schedule", systemImage: "trash", destructive: true) {
                  store.requestWakeDeletion(request.id)
                }
                .disabled(state?.busy != nil || !store.canOrganize).groupingFill()
                .accessibilityIdentifier("delete-wake")
              }
            }
          }.padding(17).webFont(.system)
        }.scrollDismissesKeyboard(.interactively)
          .accessibilityElement(children: .contain).accessibilityIdentifier("wake-scroll")
          .onChange(of: state?.failure) { _, failure in
            if failure != nil { withAnimation { proxy.scrollTo("wake-alerts", anchor: .top) } }
          }
          .onChange(of: state?.changedElsewhere) { _, changed in
            if changed == true { withAnimation { proxy.scrollTo("wake-alerts", anchor: .top) } }
          }
      }
    }
    .foregroundStyle(WebColor.text.color)
    .webSheetVeil()
    .tint(theme.palette.accent.color)
    .presentationDragIndicator(.visible).presentationDetents([.large])
    .presentationContentInteraction(.scrolls)
    .accessibilityElement(children: .contain).accessibilityIdentifier("wake-editor")
    .task(id: thread?.wakeSchedule?.revision) { await store.refreshWakeEditor(request.id) }
    .onChange(of: store.wakeEditor?.id) { _, id in if id != request.id { dismiss() } }
    .onChange(of: store.selectedThreadID) { dismiss() }
    .onDisappear { store.closeWakeEditor(request.id) }
    .alert(
      "Delete this schedule?",
      isPresented: Binding(get: { state?.deletionConfirmation != nil }, set: { _ in }),
      presenting: state?.deletionConfirmation
    ) { confirmation in
      Button("Keep schedule", role: .cancel) { store.cancelWakeDeletion(request.id) }
      Button("Delete", role: .destructive) {
        store.confirmWakeDeletion(request.id, confirmation: confirmation)
      }
    } message: { _ in
      Text("This removes future wake-ups; an already-started wake-up will continue.")
    }
  }
  @ViewBuilder private var alerts: some View {
    if let failure = state?.failure {
      VStack(alignment: .leading, spacing: 8) {
        Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(
          WebColor.danger.color)
        if let detail = failure.detail { Text(detail).webFont(.sheetSubtitle) }
        Button(failure.conflict ? "Load latest" : "Try again") {
          Task { await store.refreshWakeEditor(request.id, explicit: failure.conflict) }
        }
        .foregroundStyle(WebGlass.accentText(theme.palette).color)
        .designButtonStyle(.secondary, placement: .floating).disabled(state?.busy != nil)
        .accessibilityIdentifier("wake-reload")
      }.accessibilityElement(children: .contain).accessibilityIdentifier("wake-error")
    } else if state?.changedElsewhere == true {
      VStack(alignment: .leading, spacing: 8) {
        Text("Changed elsewhere while you were editing.")
        Text("Load the latest version before saving. This replaces your unsaved changes.").webFont(
          .sheetSubtitle)
        Button("Load latest") { Task { await store.refreshWakeEditor(request.id, explicit: true) } }
          .foregroundStyle(WebGlass.accentText(theme.palette).color)
          .designButtonStyle(.secondary, placement: .floating).disabled(state?.busy != nil)
      }
    }
  }
  private var expired: Bool {
    state?.schedule.map { $0.state == "paused" && WakeScheduleModel.onceHasElapsed($0.definition) }
      ?? false
  }
  private var note: String? {
    guard let state else { return nil }
    if archived {
      return "This conversation is archived. Restore it to save or resume this schedule."
    }
    guard let saved = state.schedule else { return nil }
    if state.dirty {
      return saved.state == "active"
        ? "Save to apply these changes." : "Save turns this schedule on."
    }
    if saved.state == "paused" {
      return expired
        ? "Paused, and its time has passed. Pick a future date to schedule it again."
        : "No wake-ups until you resume it."
    }
    if saved.state == "completed" {
      return "No further wake-ups. Pick a new date and time to schedule it again."
    }
    return saved.nextFireAt == nil
      ? "Waiting to run when the agent and conversation are available." : nil
  }
  private var next: String? {
    guard let state, !state.dirty, let saved = state.schedule, saved.state == "active",
      let iso = saved.nextFireAt
    else { return nil }
    let next = WakeScheduleModel.nextFire(iso, scheduleZone: saved.definition.timezone)
    return "Next: \(next.scheduled) (\(saved.definition.timezone))"
      + (next.local.map { " · \($0) your time" } ?? "")
  }
  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      let saved = state?.schedule
      let dirty = state?.dirty == true
      let label =
        state?.loaded != true
        ? (state?.failure == nil ? "Loading…" : "Unavailable")
        : saved == nil
          ? "New schedule" : dirty ? "Unsaved changes" : (saved?.state.capitalized ?? "")
      WakeSummaryView(
        state: label, sentence: WakeScheduleModel.describe(draft) ?? "Finish the schedule below.",
        next: next, note: note,
        outcome: !dirty ? saved?.lastOutcome.map(WakeScheduleModel.outcome) : nil)
      if let saved, saved.state != "completed", !expired {
        let action: WakeAction = saved.state == "active" ? .pause : .resume
        Button(
          state?.busy == action
            ? (action == .pause ? "Pausing…" : "Resuming…")
            : action == .pause ? "Pause schedule" : "Resume schedule"
        ) {
          store.mutateWakeEditor(request.id, action: action)
        }.foregroundStyle(WebGlass.accentText(theme.palette).color)
          .designButtonStyle(.secondary, placement: .floating).disabled(
            dirty || state?.busy != nil || (action == .resume && archived) || !store.canOrganize
          )
          .accessibilityIdentifier("wake-toggle")
      }
    }.padding(.bottom, 16).overlay(alignment: .bottom) {
      WebHairline()
    }
  }
  @ViewBuilder private var whenFields: some View {
    Picker("Schedule type", selection: binding(\.kind)) {
      Text("Once").tag("once")
      Text("Weekly").tag("weekly")
    }
    .pickerStyle(.segmented).accessibilityIdentifier("wake-kind")
    if draft.kind == "once" {
      HStack {
        wallPicker("Date", value: binding(\.date), date: true, id: "wake-date")
        wallPicker("Time", value: binding(\.time), date: false, id: "wake-time")
      }
      issue(issues.when)
      if state?.dirty == true && WakeScheduleModel.onceLooksPast(draft) {
        Text("This time has already passed in \(draft.timezone). Pick a future date or time.")
          .foregroundStyle(WebColor.warning.color)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Eyebrow("Days")
        ViewThatFits(in: .horizontal) {
          dayButtons
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 54))]) { days }
        }
        issue(issues.days)
      }
      VStack(alignment: .leading, spacing: 8) {
        Eyebrow("Times")
        ForEach(draft.times.indices, id: \.self) { index in
          HStack {
            wallPicker(
              "Time \(index + 1)",
              value: Binding(
                get: { draft.times.indices.contains(index) ? draft.times[index] : "" },
                set: { value in
                  var next = draft
                  guard next.times.indices.contains(index) else { return }
                  next.times[index] = value
                  store.editWakeDraft(request.id, draft: next)
                }), date: false, id: "wake-time-\(index)")
            if draft.times.count > 1 {
              Button("Remove time \(index + 1)", systemImage: "minus.circle") {
                var next = draft
                next.times.remove(at: index)
                store.editWakeDraft(request.id, draft: next)
              }
              .labelStyle(.iconOnly).foregroundStyle(WebGlass.accentText(theme.palette).color)
              .designButtonStyle(.secondary, placement: .floating)
              .accessibilityIdentifier(
                "wake-remove-time-\(index)")
            }
          }
        }
        if draft.times.count < WakeScheduleModel.maxTimes {
          Button("Add time", systemImage: "plus") {
            var next = draft
            next.times.append(WakeScheduleModel.nextTimeSlot(next.times))
            store.editWakeDraft(request.id, draft: next)
          }
          .foregroundStyle(WebGlass.accentText(theme.palette).color)
          .designButtonStyle(.secondary, placement: .floating).accessibilityIdentifier(
            "wake-add-time")
        }
        issue(issues.times)
      }
    }
  }
  private var dayButtons: some View { HStack(spacing: 4) { days } }
  private var days: some View {
    ForEach(WakeScheduleModel.weekOrder(), id: \.self) { day in
      Button {
        var next = draft
        if next.days.contains(day) {
          next.days.removeAll { $0 == day }
        } else {
          next.days.append(day)
        }
        store.editWakeDraft(request.id, draft: next)
      } label: {
        // The whole 44 pt chip is the hit target, not only the glyphs.
        Text(WakeScheduleModel.shortDays[day])
          .fontWeight(draft.days.contains(day) ? .semibold : .regular)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain)
        .foregroundStyle(WebColor.text.color)
        .background(
          draft.days.contains(day) ? theme.palette.accentInk : WebGlass.groupFill.color,
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(
            draft.days.contains(day) ? theme.palette.accent.color : WebGlass.hairline.color)
        }
        .overlay(alignment: .bottom) {
          if draft.days.contains(day) {
            Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).offset(y: -1)
              .accessibilityHidden(true)
          }
        }.tint(
          draft.days.contains(day) ? theme.palette.accent.color : WebGlass.textMuted.color
        )
        .accessibilityLabel(WakeScheduleModel.weekdays[day]).accessibilityValue(
          draft.days.contains(day) ? "Selected" : "Not selected"
        )
        .accessibilityAddTraits(draft.days.contains(day) ? .isSelected : [])
        .accessibilityIdentifier(
          "wake-day-\(day)")
    }
  }
  private var zoneFields: some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow("Timezone")
      TextField(
        "Europe/Berlin", text: binding(\.timezone),
        prompt: Text("Europe/Berlin").foregroundStyle(WebGlass.textMuted.color)
      ).textInputAutocapitalization(.never)
        .autocorrectionDisabled().padding(12).groupingFill().accessibilityIdentifier("wake-zone")
      Button("Use device timezone (\(TimeZone.current.identifier))") {
        binding(\.timezone).wrappedValue = TimeZone.current.identifier
      }.foregroundStyle(WebGlass.accentText(theme.palette).color)
        .designButtonStyle(.secondary, placement: .floating)
      Text("Times stay in this timezone, including daylight saving changes.").webFont(
        .sheetSubtitle
      ).foregroundStyle(WebGlass.textMuted.color)
      issue(issues.timezone)
    }
  }
  private func wallPicker(_ title: String, value: Binding<String>, date: Bool, id: String)
    -> some View
  {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = date ? "yyyy-MM-dd" : "HH:mm"
    let selected = Binding<Date>(
      get: { f.date(from: value.wrappedValue) ?? f.date(from: date ? "2000-01-01" : "09:00")! },
      set: { value.wrappedValue = f.string(from: $0) })
    return VStack(alignment: .leading, spacing: 8) {
      Eyebrow(title)
      DatePicker(title, selection: selected, displayedComponents: date ? .date : .hourAndMinute)
        .labelsHidden()
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!).accessibilityIdentifier(id)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func issue(_ text: String?) -> some View {
    if let text { Text(text).webFont(.sheetSubtitle).foregroundStyle(WebColor.danger.color) }
  }
}
extension View {
  fileprivate func groupingFill() -> some View {
    webGlassGroup(cornerRadius: 8, outlined: false)
  }
}
