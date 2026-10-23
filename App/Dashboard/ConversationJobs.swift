// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import Observation
import SwiftUI

/// Disclosure preferences survive a job moving between current work and History.
@MainActor @Observable final class JobDisclosureState {
  private var keys: Set<String> = []
  func contains(_ key: String) -> Bool { keys.contains(key) }
  func binding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { self.keys.contains(key) },
      set: { open in
        if open { self.keys.insert(key) } else { self.keys.remove(key) }
      })
  }
}

/// Conversation-owned job shelf. Its clock changes only at a question deadline, never per tick.
struct ConversationJobStack: View {
  let state: ConversationState
  let store: ConsoleStore
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  @State private var expanded = false
  @State private var history = false
  @State private var disclosures = JobDisclosureState()
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    let items = JobShelf.items(messages: state.messages)
    let deadlines = items.flatMap(\.jobs).compactMap { job -> Date? in
      guard job.peerQuestion?.state == "awaiting_answer" else { return nil }
      return JobPresentation.date(job.peerQuestion?.expiresAt)?.addingTimeInterval(
        -store.serverClockOffset)
    }.filter { $0 > Date() }
    if !items.isEmpty {
      if deadlines.isEmpty {
        shelf(items, now: Date().addingTimeInterval(store.serverClockOffset))
      } else {
        TimelineView(.explicit([Date()] + deadlines)) { context in
          shelf(items, now: context.date.addingTimeInterval(store.serverClockOffset))
        }
      }
    }
  }
  /// Web `.process-job-stack`: the toggle (minH 42, P0/9/0/10 on phones), then a body under a
  /// 1 px line (P0/6/6) listing current rows with 37 pt-inset separators and the History pill.
  private func shelf(_ items: [JobShelfItem], now: Date) -> some View {
    let current = items.filter { $0.bucket(now: now).current }
    let finished = items.filter { !$0.bucket(now: now).current }
    let compact = sizeClass != .regular
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: compact ? 8 : 10) {
          JobShelfSummary(items: items, current: current, expanded: expanded, now: now)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WebColor.textMuted.color)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .padding(.leading, compact ? 10 : 11).padding(.trailing, compact ? 9 : 10)
        .frame(minHeight: DesignMetrics.minimumHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") details")
      .accessibilityIdentifier("job-stack")
      if expanded {
        Rectangle().fill(WebColor.line.color).frame(height: 1).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          rows(current, now: now)
          if !finished.isEmpty || state.nextCursor != nil {
            VStack(alignment: .leading, spacing: 0) {
              Button("History") { history.toggle() }
                .buttonStyle(JobHistoryToggleStyle(open: history, count: finished.count))
                .accessibilityLabel("History, \(finished.count) finished")
                .accessibilityValue(history ? "Expanded" : "Collapsed")
            }
            .padding(.top, current.isEmpty ? 2 : 4).padding(.bottom, 2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
              if !current.isEmpty {
                Rectangle().fill(WebColor.line.color).frame(height: 1).padding(.horizontal, 4)
              }
            }
            if history {
              rows(finished, now: now)
              if state.nextCursor != nil {
                Text("Older jobs are in earlier messages.")
                  .webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
                  .padding(.top, 4).padding(.horizontal, 10).padding(.bottom, 6)
              }
            }
          }
        }
        .padding(.top, 3)
        .padding(.horizontal, 6).padding(.bottom, 6)
      }
    }
  }
  /// Rows separated by a 1 px line from the title column (37 / 40 pt) to 8 / 10 pt from the edge;
  /// no line touches an open row.
  @ViewBuilder private func rows(_ items: [JobShelfItem], now: Date) -> some View {
    let compact = sizeClass != .regular
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      let previousOpen = index > 0 && open(items[index - 1])
      group(item, now: now)
        .overlay(alignment: .top) {
          if index > 0 && !previousOpen && !open(item) {
            Rectangle().fill(WebColor.line.color).frame(height: 1)
              .padding(.leading, compact ? 37 : 40).padding(.trailing, compact ? 8 : 10)
              .accessibilityHidden(true)
          }
        }
    }
  }
  private func open(_ item: JobShelfItem) -> Bool {
    item.family != nil
      ? disclosures.contains(state.thread.id + ":group:" + item.id)
      : disclosures.contains(state.thread.id + ":card:" + item.newest.jobId)
  }
  @ViewBuilder private func group(_ item: JobShelfItem, now: Date) -> some View {
    if item.family != nil {
      ProcessJobGroupView(
        item: item, messages: state.messages, threadID: state.thread.id, store: store, now: now,
        disclosures: disclosures, onAnswerPeerQuestion: onAnswerPeerQuestion)
    } else {
      ProcessJobCardView(
        job: item.newest, threadID: state.thread.id, store: store, now: now,
        disclosures: disclosures, onAnswerPeerQuestion: onAnswerPeerQuestion)
    }
  }
}

/// The web `.process-job-stack-toggle` content. Closed: the current jobs inline (glyph + agent
/// id in the delegation colour, or the command tool), "+n" for what does not fit, then a count
/// chip per finished bucket. Open: a chip for every bucket. Spoken as "Background jobs, …".
struct JobShelfSummary: View {
  let items: [JobShelfItem]
  let current: [JobShelfItem]
  let expanded: Bool
  let now: Date
  var body: some View {
    let counts = JobShelf.counts(items, now: now)
    let chips = JobShelfBucket.allCases.filter { bucket in
      (counts[bucket] ?? 0) > 0 && (expanded || !bucket.current)
    }
    HStack(spacing: 10) {
      if !expanded && !current.isEmpty {
        ViewThatFits(in: .horizontal) {
          ForEach((1...current.count).reversed(), id: \.self) { shown in entries(shown) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 5) {
        ForEach(chips, id: \.self) { bucket in
          JobCountChip(bucket: bucket, count: counts[bucket] ?? 0)
        }
      }
      .fixedSize()
      if expanded || current.isEmpty { Spacer(minLength: 0) }
    }
    .padding(.leading, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Background jobs, " + JobShelf.summary(items, now: now))
  }
  private func entries(_ shown: Int) -> some View {
    HStack(spacing: 5) {
      ForEach(Array(current.prefix(shown).enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Text("·").font(.system(size: 12, weight: .bold)).foregroundStyle(WebColor.textMuted.color)
            .padding(.leading, 2)
        }
        let face = JobFace(item.lead(now: now), now: now)
        HStack(spacing: 5) {
          JobGlyph(face.mark, tone: face.tone, size: 16)
          Text(item.instanceID ?? item.lead(now: now).tool)
            .webFont(.jobEntry)
            .fontWeight(item.family != nil ? .bold : .semibold)
            .foregroundStyle(
              item.family != nil ? WebColor.delegation.color : WebColor.textSoft.color
            )
            .lineLimit(1)
        }
      }
      if current.count > shown {
        Text("· +\(current.count - shown)").webFont(.jobEntry)
          .foregroundStyle(WebColor.textMuted.color).fixedSize()
      }
    }
    .fixedSize()
  }
}

/// The web `processJobDisplayState`: tone, glyph mark and state word, plus the row's extra words
/// (a pending question beside another state, exit details, operator alerts and notes).
struct JobFace: Equatable {
  var tone: WebJobTone
  var mark: JobGlyphMark
  var word: String
  var pending: String?
  var details: [String] = []
  var alerts: [String] = []
  var notes: [String] = []

  init(_ job: ProcessJobProjection, now: Date) {
    let terminal = JobPresentation.terminal(job)
    let label = JobPresentation.status(job, now: now).label
    switch job.state {
    case "queued": (tone, mark) = (.waiting, .empty)
    case "starting", "running": (tone, mark) = (.running, .half)
    case "succeeded": (tone, mark) = (.success, .check)
    case "timed_out", "queue_expired": (tone, mark) = (.danger, .clock)
    case "cancelled": (tone, mark) = (.neutral, .stopped)
    case "failed", "spawn_failed", "interrupted": (tone, mark) = (.danger, .cross)
    default: (tone, mark) = (.neutral, .empty)
    }
    word = label
    let question = JobPresentation.pending(job, now: now)
    if !terminal && job.cancelRequested {
      (tone, mark) = (.stopping, .stop)
    } else if question && job.state == "succeeded" {
      (tone, mark) = (.question, .question)
    }
    if question && job.state != "succeeded" { pending = "Question pending" }
    if JobPresentation.command(job) {
      if let exit = job.exitCode, exit != 0 { details.append("exit \(exit)") }
      if let signal = job.signal { details.append(signal) }
    }
    if terminal {
      if job.childStillBusy == true {
        alerts.append("child still busy · awaiting actual settlement")
      }
      if job.wake.state == "failed" { alerts.append("wake failed") }
      if job.wake.state == "unknown" { alerts.append("wake outcome unknown · replay suppressed") }
      if job.wake.state == "suppressed" { alerts.append("wake suppressed") }
    }
    if job.subagentQuestion != nil {
      notes.append(
        job.wake.state == "pending"
          ? "Child question waiting for parent" : "asked the parent agent a question")
    }
  }

  /// The face of a shelf bucket (the open shelf's chips and the closed bar's marks).
  static func bucket(_ bucket: JobShelfBucket) -> (tone: WebJobTone, mark: JobGlyphMark) {
    switch bucket {
    case .question: (.question, .question)
    case .active: (.running, .half)
    case .issue: (.danger, .cross)
    case .done: (.success, .check)
    case .cancelled: (.neutral, .stopped)
    }
  }

  /// One line for a collapsed row (`processJobPreview`): the last output line of a command, the
  /// question a peer asks, a finished child's report or the call a running child is making.
  static func preview(_ job: ProcessJobProjection, now: Date) -> (
    label: String, text: String, mono: Bool
  )? {
    func lines(_ text: String) -> [String] {
      text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
    if JobPresentation.command(job) {
      if job.state == "queued" || job.state == "starting" { return nil }
      let output = job.output.preview
      if output.isEmpty || output == "(no output)" {
        return JobPresentation.terminal(job) ? nil : ("", "No output yet", false)
      }
      let markers: Set<String> = [
        "STDOUT:", "STDERR:", "… [earlier output omitted]", "(no output)",
      ]
      guard let line = lines(output).last(where: { !markers.contains($0) }) else { return nil }
      return ("Output", JobPresentation.preview(String(line.prefix(200))).text, true)
    }
    if JobPresentation.pending(job, now: now), let question = job.peerQuestion,
      let line = lines(question.message).last
    {
      return ("Asks", JobPresentation.preview(String(line.prefix(200))).text, false)
    }
    guard let progress = job.subagentProgress else { return nil }
    if JobPresentation.terminal(job) {
      guard let head = progress.answerHead.flatMap({ lines($0).first }) else { return nil }
      return ("Report", JobPresentation.preview(String(head.prefix(200))).text, false)
    }
    guard
      let call = progress.recent.last(where: { $0.status == "running" }) ?? progress.recent.last
    else { return nil }
    return (
      call.toolName, JobPresentation.preview(String((call.argsSummary ?? "").prefix(60))).text, true
    )
  }
}

/// Web `.process-job-chip`: the bucket's glyph + number in its text-safe tone on its tint.
struct JobCountChip: View {
  let bucket: JobShelfBucket
  let count: Int
  var body: some View {
    let face = JobFace.bucket(bucket)
    HStack(spacing: 4) {
      JobGlyph(face.mark, color: face.tone.text, size: 16)
      Text("\(count)").webFont(.jobEntry)
    }
    .foregroundStyle(face.tone.text)
    .padding(.leading, 5).padding(.trailing, 7)
    .frame(minHeight: 22)
    .background(face.tone.chipFill, in: Capsule())
  }
}

/// The meta line under a job title: state word, pending question, time, tool, details, alerts,
/// notes, recent call outcomes and (closed) a labelled one-line preview, wrapping like the web.
struct JobMetaLine: View {
  let job: ProcessJobProjection
  let face: JobFace
  let now: Date
  let offset: TimeInterval
  var expanded = false
  /// Agent groups say "n turns" (and the PeerAgent tool) instead of the tool name.
  var turns: String? = nil
  var extras: [String] = []
  var body: some View {
    let agent = !JobPresentation.command(job)
    WebFlowLayout(spacing: 5) {
      Text(face.word).fontWeight(.semibold).foregroundStyle(face.tone.text)
      if let pending = face.pending {
        JobMetaToken {
          Text(pending).fontWeight(.semibold).foregroundStyle(WebJobTone.question.text)
        }
      }
      if JobPresentation.elapsed(job, now: now) != nil {
        JobMetaToken { ProcessJobElapsed(job: job, offset: offset) }
      }
      JobMetaToken {
        HStack(spacing: 3) {
          Image(systemName: agent ? "face.smiling" : "terminal")
            .font(.system(size: 10, weight: .medium))
            .accessibilityHidden(true)
          Text(turns ?? job.tool)
        }
        .foregroundStyle(agent ? WebColor.delegation.color : WebColor.textMuted.color)
      }
      ForEach(face.details, id: \.self) { detail in
        JobMetaToken { Text(detail).webFont(.jobMono) }
      }
      ForEach(extras, id: \.self) { extra in JobMetaToken { Text(extra) } }
      ForEach(face.alerts, id: \.self) { alert in
        JobMetaToken {
          Text(alert).fontWeight(.semibold).foregroundStyle(WebColor.danger.color)
        }
      }
      ForEach(face.notes, id: \.self) { note in
        JobMetaToken { Text(note).foregroundStyle(WebJobTone.question.text) }
      }
      if agent && !JobPresentation.terminal(job), let recent = job.subagentProgress?.recent,
        !recent.isEmpty
      {
        JobMetaToken { JobCallOutcomes(statuses: recent.suffix(8).map(\.status)) }
      }
      if !expanded, let preview = JobFace.preview(job, now: now) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text("·").opacity(0.6).accessibilityHidden(true)
          if !preview.label.isEmpty {
            Text(preview.label).foregroundStyle(WebColor.textMuted.color).layoutPriority(1)
          }
          Text(preview.text)
            .modifier(MonoIf(preview.mono))
            .foregroundStyle(WebColor.textSoft.color)
            .lineLimit(1).truncationMode(.tail)
        }
        .webFlowFill()
      }
    }
  }
}

private struct MonoIf: ViewModifier {
  let mono: Bool
  init(_ mono: Bool) { self.mono = mono }
  func body(content: Content) -> some View {
    if mono { content.webFont(.jobMono) } else { content }
  }
}

/// `ProcessJobCallOutcomes`: dot = complete, × = failed, hollow ring = running (oldest first).
struct JobCallOutcomes: View {
  let statuses: [String]
  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
        Group {
          switch status {
          case "failed":
            Image(systemName: "xmark").font(.system(size: 7, weight: .heavy))
              .foregroundStyle(WebColor.danger.color)
          case "running":
            Circle().strokeBorder(WebColor.jobProgress.color, lineWidth: 1.5)
          default:
            Circle().fill(WebColor.textMuted.color).padding(2)
          }
        }
        .frame(width: 8, height: 8)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Last \(statuses.count) tool calls: \(statuses.filter { $0 == "complete" || $0 == "completed" }.count) complete, \(statuses.filter { $0 == "failed" }.count) failed"
    )
  }
}

/// Only this small leaf updates each second; neither the shelf nor transcript observes a tick.
private struct ProcessJobElapsed: View {
  let job: ProcessJobProjection
  let offset: TimeInterval
  var body: some View {
    if JobPresentation.terminal(job) {
      label(now: Date())
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in label(now: context.date) }
    }
  }
  @ViewBuilder private func label(now: Date) -> some View {
    if let elapsed = JobPresentation.elapsed(job, now: now.addingTimeInterval(offset)) {
      Text(JobPresentation.duration(elapsed)).webFont(.jobMono)
        .accessibilityLabel(
          "Job \(JobPresentation.terminal(job) ? "duration" : "elapsed time") "
            + JobPresentation.duration(elapsed))
    }
  }
}

struct ProcessJobCardView: View {
  let job: ProcessJobProjection
  let threadID: String
  let store: ConsoleStore
  let now: Date
  var isCurrent = false
  let disclosures: JobDisclosureState
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  /// Turns inside an open agent group sit on a lighter surface (web `.is-turn [open]`).
  var nested = false
  @State private var refreshFailed = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var body: some View {
    let face = JobFace(job, now: now)
    let expanded = disclosures.binding(threadID + ":card:" + job.jobId)
    JobRowDisclosure(
      "job-card-" + job.jobId, accessibilityLabel: spoken(face), expanded: expanded,
      openFill: nested ? WebColor.surface.color.opacity(0.7) : nil
    ) {
      JobGlyph(face.mark, tone: face.tone)
    } title: {
      Text(JobPresentation.title(job))
    } meta: {
      JobMetaLine(
        job: job, face: face, now: now, offset: store.serverClockOffset,
        expanded: expanded.wrappedValue)
    } content: {
      detail
    }
    .task(
      id: job.jobId + job.state + String(scenePhase == .active)
        + String(describing: store.connection)
    ) {
      guard !JobPresentation.terminal(job), scenePhase == .active else { return }
      // Only mounted/visible cards poll. Message.changed continues to refresh collapsed shelves.
      while !Task.isCancelled {
        do {
          try await store.refreshJob(threadID: threadID, jobID: job.jobId)
          try await Task.sleep(for: .seconds(store.effectiveDataMode == .lean ? 2 : 1))
        } catch { return }
      }
    }
  }
  @ViewBuilder private func outputHeading(bytes: Int) -> some View {
    Text("Output" + (job.output.truncated ? " (truncated)" : ""))
      .webFont(.jobOutputHead).foregroundStyle(WebColor.textSoft.color)
    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
    if bytes > 0 {
      Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) + " total")
        .webFont(.jobMono).foregroundStyle(WebColor.textMuted.color)
    }
  }
  private func spoken(_ face: JobFace) -> String {
    var parts = [JobPresentation.title(job), face.word]
    if isCurrent { parts.insert("Current job", at: 0) }
    if let pending = face.pending { parts.append(pending) }
    if let elapsed = JobPresentation.elapsed(job, now: now) {
      parts.append(JobPresentation.duration(elapsed))
    }
    parts.append(job.tool)
    parts += face.details + face.alerts + face.notes
    return parts.joined(separator: ", ")
  }
  @ViewBuilder private var detail: some View {
    if let progress = job.subagentProgress {
      JobProgressMeta(progress: progress, terminal: JobPresentation.terminal(job), wake: job.wake)
        .accessibilityIdentifier("subagent-progress")
    }
    if let error = job.lastError {
      JobErrorBox(error.message, code: error.code)
    }
    if let question = job.subagentQuestion {
      JobSubagentQuestionView(question: question)
    }
    if let question = job.peerQuestion {
      JobPeerQuestionView(
        question: question, now: now, onAnswerPeerQuestion: onAnswerPeerQuestion)
    }
    if let progress = job.subagentProgress {
      JobSubagentProgressView(progress: progress)
    }
    if JobPresentation.command(job) {
      let preview = JobPresentation.preview(job.output.preview, limit: 65_536)
      let empty = preview.text.isEmpty || preview.text == "(no output)"
      let bytes = job.output.stdoutBytes + job.output.stderrBytes
      if empty {
        Text(JobPresentation.terminal(job) ? "No output." : "No output yet.")
          .webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
      } else {
        // The output stays behind its own head so a long log never pushes the card's other
        // controls out of the bounded shelf.
        let open = disclosures.binding(threadID + ":output:" + job.jobId)
        Button {
          open.wrappedValue.toggle()
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
              if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) { outputHeading(bytes: bytes) }
              } else {
                HStack(spacing: 8) { outputHeading(bytes: bytes) }
              }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(WebColor.textMuted.color)
              .rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
          }
          .frame(minHeight: 28)
          .fixedSize(horizontal: false, vertical: true)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("job-output-" + job.jobId)
        if open.wrappedValue {
          JobOutputBox(preview.text)
          if preview.bounded {
            Text("Display bounded to 65,536 characters.")
              .webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
          }
          if job.output.truncated {
            Text(
              "The server supplied a truncated preview. Full logs are not available through this API."
            )
            .webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
          }
        }
      }
    } else if job.subagentProgress == nil {
      Text("Progress is unavailable for this retained job.")
        .webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
    }
    HStack(spacing: 8) {
      Button("Refresh job", systemImage: "arrow.clockwise") {
        Task {
          do {
            try await store.refreshJob(threadID: threadID, jobID: job.jobId)
            refreshFailed = false
          } catch { refreshFailed = true }
        }
      }
      .labelStyle(.titleOnly)
      .buttonStyle(WebSmallButtonStyle())
      .accessibilityIdentifier("job-refresh-" + job.jobId)
      if refreshFailed {
        Text("Could not refresh job. The retained state is shown.")
          .webFont(.jobMeta).foregroundStyle(WebColor.danger.color)
      }
    }
  }
}

/// `ProcessJobMetaLine` inside an open agent row: profile · route · tool calls · cost · wake.
struct JobProgressMeta: View {
  let progress: ProcessJobSubagentProgress
  let terminal: Bool
  let wake: ProcessJobProjection.Wake
  var body: some View {
    WebFlowLayout(spacing: 5) {
      Text(progress.profile + (progress.label.map { " · " + $0 } ?? ""))
        .lineLimit(1)
      if let route = progress.route {
        let executed = route.executed
        JobMetaToken {
          Text(
            TranscriptPresentation.route(
              executed?.model ?? route.requested.model,
              executed?.effectiveEffort ?? executed?.effort ?? route.requested.effort)
              + (executed == nil ? " · requested" : "")
          )
          .lineLimit(1)
        }
      }
      JobMetaToken {
        Text(
          "\(progress.toolCalls) \(progress.toolCalls == 1 ? "tool" : "tools")"
            + (progress.failedCalls > 0 ? ", \(progress.failedCalls) failed" : ""))
      }
      if terminal || progress.costUsd != nil || progress.costUnknown == true {
        JobMetaToken {
          Text(
            TranscriptPresentation.cost(
              .init(
                amount: progress.costUsd, unknown: progress.costUnknown,
                knownSpend: progress.knownCostUsd)))
        }
      }
      if terminal
        && (wake.attempts > 1 || ["failed", "unknown", "suppressed"].contains(wake.state))
      {
        JobMetaToken { Text("wake \(wake.state) · \(wake.attempts) attempts") }
      }
    }
    .webFont(.jobMeta)
    .foregroundStyle(WebColor.textMuted.color)
    .accessibilityElement(children: .combine)
  }
}

private struct ProcessJobGroupView: View {
  let item: JobShelfItem
  let messages: [WebMessage]
  let threadID: String
  let store: ConsoleStore
  let now: Date
  let disclosures: JobDisclosureState
  var onAnswerPeerQuestion: ((PeerProcessJobQuestion) -> Void)? = nil
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    let unfolded = disclosures.contains(threadID + ":earlier:" + item.id)
    let steps = JobShelf.visibleSteps(item, messages: messages, unfolded: unfolded, now: now)
    let folded = JobShelf.timeline(item, messages: messages).count - steps.count
    let lead = item.lead(now: now)
    let face = JobFace(lead, now: now)
    let expanded = disclosures.binding(threadID + ":group:" + item.id)
    let purpose = JobShelf.purpose(item, messages: messages)
    let turns = "\(item.jobs.count) \(item.jobs.count == 1 ? "turn" : "turns")"
    let closed = JobShelf.closed(item, messages: messages)
    let compact = sizeClass != .regular
    JobRowDisclosure(
      "job-group-" + item.id,
      accessibilityLabel: [
        item.instanceID ?? "", purpose, face.word,
        (item.family == "peer" ? "Peer agent" : "Agent") + " · " + turns,
        closed ? "Closed" : "",
      ].filter { !$0.isEmpty }.joined(separator: ", "),
      expanded: expanded
    ) {
      JobGlyph(face.mark, tone: face.tone)
    } title: {
      let name = Text(item.instanceID ?? "Agent").fontWeight(.bold)
        .foregroundStyle(WebColor.delegation.color)
      Text("\(name)  \(purpose)")
    } meta: {
      JobMetaLine(
        job: lead, face: face, now: now, offset: store.serverClockOffset,
        expanded: expanded.wrappedValue,
        turns: item.family == "peer" ? "PeerAgent · " + turns : turns,
        extras: [JobShelf.cost(item), closed ? "Closed" : nil].compactMap { $0 })
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if folded > 0 {
          Button {
            disclosures.binding(threadID + ":earlier:" + item.id).wrappedValue = true
          } label: {
            HStack(spacing: 7) {
              Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
                .foregroundStyle(WebColor.textMuted.color)
                .frame(width: 20, height: 20)
                .background(Circle().fill(WebColor.text.color.opacity(0.07)))
              Text("Show earlier turns and parent messages (\(folded))")
                .webFont(.jobEntry).foregroundStyle(WebColor.textSoft.color)
                .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 5).padding(.leading, 9).padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(
              RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
                .strokeBorder(
                  WebColor.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.bottom, 4)
        }
        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
          let first = index == 0 && folded == 0
          let last = index == steps.count - 1
          Group {
            switch step {
            case .turn(let job):
              let current = job.jobId == lead.jobId && item.bucket(now: now).current
              ProcessJobCardView(
                job: job, threadID: threadID, store: store, now: now, isCurrent: current,
                disclosures: disclosures, onAnswerPeerQuestion: onAnswerPeerQuestion,
                nested: true
              )
              .accessibilityValue(current ? "Current job" : "Earlier turn")
            case .call(let call):
              JobParentCallRow(
                call: call, threadID: threadID, store: store, disclosures: disclosures)
            }
          }
          .background(alignment: .topLeading) {
            JobRail(
              top: step.isTurn ? 8 : 6, showAbove: !first, showBelow: !last,
              x: compact ? 18.25 : 19.25)
          }
        }
      }
      .padding(.leading, compact ? -19 : -10)
      .padding(.bottom, 8)
    }
  }
}

extension JobTimelineStep {
  fileprivate var isTurn: Bool {
    if case .turn = self { return true }
    return false
  }
}

/// The group timeline's rail: one 1.5 pt segment above a step's mark and one below it, so it never
/// crosses a glyph (`--process-job-rail`: muted at 40%).
private struct JobRail: View {
  let top: CGFloat
  let showAbove: Bool
  let showBelow: Bool
  let x: CGFloat
  var body: some View {
    GeometryReader { proxy in
      let color = WebColor.textMuted.color.opacity(0.4)
      if showAbove {
        Rectangle().fill(color).frame(width: 1.5, height: max(0, top - 2))
          .offset(x: x - 0.75)
      }
      if showBelow {
        Rectangle().fill(color)
          .frame(width: 1.5, height: max(0, proxy.size.height - top - 22))
          .offset(x: x - 0.75, y: top + 22)
      }
    }
    .accessibilityHidden(true)
  }
}

/// The parent's call, read like a transcript tool row (`.process-job-call`): a 20 pt tinted icon,
/// tool, action word, status and mono time, then (closed) two lines of what it said.
private struct JobParentCallRow: View {
  let call: JobParentCall
  let threadID: String
  let store: ConsoleStore
  let disclosures: JobDisclosureState
  var body: some View {
    let open = disclosures.binding(threadID + ":call:" + call.id)
    let quiet = ["stop", "close", "decline"].contains(call.action)
    let text = call.text.map { JobPresentation.preview($0, limit: 16_384).text }
    VStack(alignment: .leading, spacing: 0) {
      Button {
        if text != nil || call.call.argsTruncated == true { open.wrappedValue.toggle() }
      } label: {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: quiet ? "stop.fill" : "paperplane")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(quiet ? WebColor.textSoft.color : WebColor.delegation.color)
            .frame(width: 20, height: 20)
            .background(
              Circle().fill(
                (quiet
                  ? WebColor.text.color.opacity(0.09) : WebColor.delegation.color.opacity(0.14))
              ))
          VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(call.call.toolName ?? "Agent").webFont(.jobOutputHead)
                .foregroundStyle(WebColor.text.color)
              Text(call.action).webFont(.attachment).foregroundStyle(WebColor.textMuted.color)
              Text(call.call.status).webFont(.attachment).fontWeight(.semibold)
                .foregroundStyle(
                  TranscriptPresentation.failed(call.call)
                    ? WebColor.danger.color : WebColor.textSoft.color
                )
                .lineLimit(1)
              Spacer(minLength: 4)
              if let at = JobPresentation.date(call.at) {
                Text(at.formatted(date: .omitted, time: .shortened))
                  .font(.system(size: 10.5, design: .monospaced))
                  .foregroundStyle(WebColor.textMuted.color)
              }
            }
            if let thread = call.peerThread {
              Text("thread " + thread).webFont(.attachment).fontWeight(.semibold)
                .foregroundStyle(WebColor.textSoft.color)
            }
            if let text, !open.wrappedValue {
              Text(text.split(whereSeparator: \.isNewline).joined(separator: " "))
                .font(.system(size: 12))
                .foregroundStyle(WebColor.textSoft.color)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if text != nil {
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(WebColor.textMuted.color)
              .rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
              .frame(width: 12, height: 18)
          }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(
          RoundedRectangle(cornerRadius: WebRadius.row, style: .continuous)
            .fill(
              open.wrappedValue
                ? (quiet
                  ? WebColor.text.color.opacity(0.03) : WebColor.delegation.color.opacity(0.05))
                : .clear)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "From parent · \(call.call.toolName ?? "Agent") · \(call.action) · \(call.call.status)")
      if open.wrappedValue {
        VStack(alignment: .leading, spacing: 6) {
          if let text { Text(text).webFont(.jobDetail).textSelection(.enabled) }
          if call.closed {
            Text("Host confirmed closed").webFont(.jobMeta)
              .foregroundStyle(WebColor.textMuted.color)
          }
          if call.call.argsTruncated == true {
            Text("Preview only").webFont(.jobMeta).foregroundStyle(WebColor.textMuted.color)
            Button("Load full message") {
              Task {
                _ = await store.repairToolOutput(
                  threadID: threadID, messageID: call.messageID, toolCallID: call.call.toolCallId)
              }
            }
            .buttonStyle(WebSmallButtonStyle())
          }
        }
        .foregroundStyle(WebColor.text.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 11)
        .background(
          WebColor.surface.color,
          in: UnevenRoundedRectangle(
            topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 9,
            topTrailingRadius: 9)
        )
        .overlay(
          UnevenRoundedRectangle(
            topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 9,
            topTrailingRadius: 9
          ).strokeBorder(WebColor.line.color, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
          Rectangle().fill(WebColor.delegation.color.mixedOpacity(0.45)).frame(width: 2)
        }
        .padding(.top, 2).padding(.leading, 35).padding(.trailing, 8).padding(.bottom, 8)
      }
    }
  }
}

extension Color {
  /// Approximates `color-mix(in srgb, self p, var(--line))` for thin accent rules.
  fileprivate func mixedOpacity(_ value: Double) -> Color { opacity(value) }
}

/// Inline lifecycle fact; the retained, interactive card lives once in the conversation shelf.
struct ProcessJobLifecycleView: View {
  let job: ProcessJobProjection
  let store: ConsoleStore
  var body: some View {
    Label(
      job.tool + " job " + job.state.replacingOccurrences(of: "_", with: " ") + " · "
        + JobPresentation.title(job),
      systemImage: JobPresentation.command(job) ? "terminal" : "person.crop.circle"
    )
    // Web: a quiet activity line in the transcript; the job itself lives in the shelf.
    .webFont(.activityMeta)
    .foregroundStyle(WebColor.textMuted.color)
    .accessibilityHint("Details in Background jobs above the message field")
  }
}
struct ProcessJobWakeView: View {
  let wake: ProcessJobWakePart
  var body: some View {
    Label("Job \(wake.jobId) · wake \(wake.disposition)", systemImage: "bell.badge")
      .webFont(.activityMeta).foregroundStyle(WebColor.textMuted.color)
  }
}
