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
  private func shelf(_ items: [JobShelfItem], now: Date) -> some View {
    let current = items.filter { $0.bucket(now: now).current }
    let finished = items.filter { !$0.bucket(now: now).current }
    return ContentDisclosure("job-stack", expanded: $expanded) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        Rectangle().fill(WebColor.line.color).frame(height: 1).padding(.horizontal, -10)
          .accessibilityHidden(true)
        ForEach(current) { item in group(item, now: now) }
        if !finished.isEmpty || state.nextCursor != nil {
          DisclosureGroup("History · \(finished.count) finished", isExpanded: $history) {
            VStack(alignment: .leading, spacing: DesignSpacing.md) {
              ForEach(finished) { item in group(item, now: now) }
              if state.nextCursor != nil {
                Text("Older jobs are in earlier messages.").designFont(.caption)
              }
            }
          }
        }
      }.padding(.top, DesignSpacing.sm)
    } label: {
      JobShelfSummary(items: items, current: current, expanded: expanded, now: now)
    }
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
    .padding(.leading, 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Background jobs, " + JobShelf.summary(items, now: now))
  }
  private func entries(_ shown: Int) -> some View {
    HStack(spacing: 5) {
      ForEach(Array(current.prefix(shown).enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Text("·").font(.system(size: 12, weight: .bold)).foregroundStyle(WebColor.textMuted.color)
            .padding(.horizontal, 2)
        }
        let lead = item.lead(now: now)
        let face = JobPresentation.status(lead, now: now)
        HStack(spacing: 5) {
          Image(systemName: face.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(JobTone(face.tone, state: lead.state).glyph)
          Text(item.instanceID ?? lead.tool)
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

/// Fixed job status hues (never the console theme): progress yellow, questions amber, success
/// green, danger red, neutral text.
struct JobTone {
  let glyph: Color
  let text: Color
  let fill: Color
  init(_ tone: String, state: String = "") {
    switch tone {
    case "warning" where state == "running" || state == "starting":
      self.init(bucket: .active)
    case "warning": self.init(bucket: .question)
    case "danger": self.init(bucket: .issue)
    case "success": self.init(bucket: .done)
    default: self.init(bucket: .cancelled)
    }
  }
  init(bucket: JobShelfBucket) {
    switch bucket {
    case .question:
      glyph = WebColor.warning.color
      text = WebColor.jobWarningText.color
      fill = WebColor.warning.color.opacity(0.14)
    case .active:
      glyph = WebColor.jobProgress.color
      text = WebColor.jobProgressText.color
      fill = WebColor.jobProgress.color.opacity(0.14)
    case .issue:
      glyph = WebColor.danger.color
      text = WebColor.danger.color
      fill = WebColor.danger.color.opacity(0.12)
    case .done:
      glyph = WebColor.success.color
      text = WebColor.jobSuccessText.color
      fill = WebColor.success.color.opacity(0.12)
    case .cancelled:
      glyph = WebColor.textMuted.color
      text = WebColor.textSoft.color
      fill = WebColor.text.color.opacity(0.07)
    }
  }
}

/// Web `.process-job-chip`: glyph + number in the bucket's text-safe tone on its tint.
struct JobCountChip: View {
  let bucket: JobShelfBucket
  let count: Int
  var body: some View {
    let tone = JobTone(bucket: bucket)
    let symbol =
      switch bucket {
      case .question: "questionmark.circle"
      case .active: "circle.lefthalf.filled"
      case .issue: "xmark.circle.fill"
      case .done: "checkmark.circle.fill"
      case .cancelled: "stop.circle"
      }
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
      Text("\(count)").webFont(.jobEntry)
    }
    .foregroundStyle(tone.text)
    .padding(.leading, 5).padding(.trailing, 7)
    .frame(minHeight: 22)
    .background(tone.fill, in: Capsule())
  }
}

struct JobStateLabel: View {
  let job: ProcessJobProjection
  let now: Date
  var title: String? = nil
  @Environment(\.consoleTheme) private var theme
  var body: some View {
    let face = JobPresentation.status(job, now: now)
    let tone: StatusTone =
      switch face.tone {
      case "success": .success
      case "warning": .warning
      case "danger": .danger
      default: .neutral
      }
    Label {
      Text((title.map { $0 + " · " } ?? "") + face.label)
    } icon: {
      Image(systemName: face.symbol).foregroundStyle(tone.color(in: theme).color)
        .accessibilityHidden(true)
    }.designFont(.supporting).accessibilityElement(children: .combine)
      .accessibilityLabel((title.map { $0 + ", " } ?? "Job ") + face.label)
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
      Text(JobPresentation.duration(elapsed)).monospacedDigit().designFont(.caption)
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
  @State private var refreshFailed = false
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    ContentDisclosure(
      "job-card-" + job.jobId, expanded: disclosures.binding(threadID + ":card:" + job.jobId)
    ) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        if let error = job.lastError {
          Text(error.message + (error.code.map { " · " + $0 } ?? "")).designFont(.supporting)
        }
        if let progress = job.subagentProgress {
          JobSubagentProgressView(progress: progress)
        } else if !JobPresentation.command(job) {
          Text("Progress is unavailable for this retained job.").designFont(.caption)
        }
        if let question = job.peerQuestion {
          JobPeerQuestionView(
            question: question, now: now, onAnswerPeerQuestion: onAnswerPeerQuestion)
        }
        if let question = job.subagentQuestion {
          VStack(alignment: .leading, spacing: DesignSpacing.sm) {
            Label("Asked the parent agent", systemImage: "questionmark.bubble").designFont(
              .headline)
            Text(question.question).textSelection(.enabled)
            if let options = question.options {
              Text("Options: " + options.joined(separator: " · ")).designFont(.caption)
            }
            Text("Untrusted child text; the parent agent answers it.").designFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if JobPresentation.command(job) {
          ContentDisclosure(
            "job-output-" + job.jobId,
            expanded: disclosures.binding(threadID + ":output:" + job.jobId)
          ) {
            let preview = JobPresentation.preview(job.output.preview, limit: 65_536)
            CodeDocumentView(
              source: preview.text.isEmpty || preview.text == "(no output)"
                ? (JobPresentation.terminal(job) ? "No output." : "No output yet.") : preview.text,
              language: "Output")
            if preview.bounded {
              Text("Display bounded to 65,536 characters.").designFont(.caption)
            }
            if job.output.truncated {
              Text(
                "The server supplied a truncated preview. Full logs are not available through this API."
              ).designFont(.caption).foregroundStyle(.secondary)
            }
          } label: {
            Text("Output" + (job.output.truncated ? " · server-truncated" : ""))

          }
        }
        Button("Refresh job", systemImage: "arrow.clockwise") {
          Task {
            do {
              try await store.refreshJob(threadID: threadID, jobID: job.jobId)
              refreshFailed = false
            } catch { refreshFailed = true }
          }
        }.designButtonStyle(.secondary).accessibilityIdentifier("job-refresh-" + job.jobId)
        if refreshFailed {
          Text("Could not refresh job. The retained state is shown.").designFont(.caption)
        }
      }.padding(.top, DesignSpacing.sm)
    } label: {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        if isCurrent {
          Text("Current job").designFont(.caption).accessibilityIdentifier(
            "current-job-" + job.jobId)
        }
        Text(JobPresentation.title(job)).designFont(.headline).foregroundStyle(.primary)
        JobStateLabel(job: job, now: now)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DesignSpacing.sm) { meta }
          VStack(alignment: .leading, spacing: DesignSpacing.xs) { meta }
        }
        if JobPresentation.pending(job, now: now), job.state != "succeeded" {
          Text("Question pending").designFont(.caption)
        }
        if job.childStillBusy == true {
          Text("Child still busy · awaiting actual settlement").designFont(.caption)
        }
        if ["failed", "unknown", "suppressed"].contains(job.wake.state) {
          Text("Wake \(job.wake.state) · \(job.wake.attempts) attempts").designFont(.caption)
        }
        if !job.output.preview.isEmpty && JobPresentation.command(job) {
          Text(JobPresentation.preview(job.output.preview, limit: 200).text).designFont(.code)
            .lineLimit(2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(DesignSpacing.sm)
    .background(DesignColor.contentSurface, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
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
  @ViewBuilder private var meta: some View {
    Text(job.tool).designFont(.caption).foregroundStyle(.secondary)
    ProcessJobElapsed(job: job, offset: store.serverClockOffset)
    if let exit = job.exitCode { Text("exit \(exit)").designFont(.caption) }
    if let signal = job.signal { Text(signal).designFont(.caption) }
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
  var body: some View {
    let unfolded = disclosures.contains(threadID + ":earlier:" + item.id)
    let steps = JobShelf.visibleSteps(item, messages: messages, unfolded: unfolded, now: now)
    let folded = JobShelf.timeline(item, messages: messages).count - steps.count
    ContentDisclosure(
      "job-group-" + item.id, expanded: disclosures.binding(threadID + ":group:" + item.id)
    ) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        if let cost = JobShelf.cost(item) {
          Text(cost).designFont(.caption).foregroundStyle(.secondary)
        }
        if folded > 0 {
          Button("Show earlier turns and parent messages (\(folded))") {
            disclosures.binding(threadID + ":earlier:" + item.id).wrappedValue = true
          }
        }
        ForEach(steps) { step in
          switch step {
          case .turn(let job):
            Group {
              ProcessJobCardView(
                job: job, threadID: threadID, store: store, now: now,
                isCurrent: job.jobId == item.lead(now: now).jobId && item.bucket(now: now).current,
                disclosures: disclosures, onAnswerPeerQuestion: onAnswerPeerQuestion
              )
              .overlay(alignment: .leading) {
                if job.jobId == item.lead(now: now).jobId && item.bucket(now: now).current {
                  RoundedRectangle(cornerRadius: DesignRadius.sm).strokeBorder(
                    DesignColor.warning.color, lineWidth: 2
                  ).allowsHitTesting(false)
                }
              }
              .accessibilityValue(
                job.jobId == item.lead(now: now).jobId && item.bucket(now: now).current
                  ? "Current job" : "Earlier turn")
            }
          case .call(let call):
            DisclosureGroup(
              "From parent · \(call.call.toolName ?? "Agent") · \(call.action) · \(call.call.status)"
            ) {
              if let text = call.text {
                Text(JobPresentation.preview(text, limit: 16_384).text).textSelection(.enabled)
              }
              if let thread = call.peerThread { Text("Thread: " + thread).designFont(.caption) }
              if call.closed { Text("Host confirmed closed").designFont(.caption) }
              if call.call.argsTruncated == true {
                Text("Preview only").designFont(.caption)
                Button("Load full message") {
                  Task {
                    _ = await store.repairToolOutput(
                      threadID: threadID, messageID: call.messageID,
                      toolCallID: call.call.toolCallId)
                  }
                }
              }
            }.designFont(.supporting)
          }
        }
      }.padding(.top, DesignSpacing.sm)
    } label: {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        JobStateLabel(job: item.lead(now: now), now: now, title: item.instanceID)
        Text(JobShelf.purpose(item, messages: messages)).designFont(.supporting).foregroundStyle(
          .primary)
        if JobShelf.closed(item, messages: messages) { Text("Closed").designFont(.caption) }
        Text(
          "\(item.family == "peer" ? "Peer agent" : "Agent") · \(item.jobs.count) \(item.jobs.count == 1 ? "turn" : "turns")"
        )
        .designFont(.caption)
      }
    }
  }
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
    .designFont(.supporting)
    .accessibilityHint("Details in Background jobs above the message field")
  }
}
struct ProcessJobWakeView: View {
  let wake: ProcessJobWakePart
  var body: some View {
    Label("Job \(wake.jobId) · wake \(wake.disposition)", systemImage: "bell.badge").designFont(
      .caption)
  }
}
