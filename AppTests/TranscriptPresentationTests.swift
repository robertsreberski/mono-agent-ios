// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import Testing

@testable import MonoAgent

struct TranscriptPresentationTests {
  @Test func compactCountsPromoteAfterRoundingAndBoundAbsurdValues() {
    #expect(TranscriptPresentation.compactionTokenCount(999_949) == "999.9k")
    #expect(TranscriptPresentation.compactionTokenCount(999_960) == "1M")
    #expect(TranscriptPresentation.compactionTokenCount(999.96) == "1k")
    #expect(TranscriptPresentation.compactionTokenCount(999_960_000) == "1B")
    #expect(TranscriptPresentation.compactionTokenCount(.greatestFiniteMagnitude) == "≥1T")
    #expect(TranscriptPresentation.compactionTokenCount(-1) == nil)
    #expect(TranscriptPresentation.compactionTokenCount(.infinity) == nil)
    #expect(TranscriptPresentation.compactionTokenCount(.nan) == nil)
  }
  @Test func compactionSegmentsNormalizeStatusCountsAndTrigger() {
    let success = TranscriptPresentation.compactionContent(
      status: "succeeded", reason: "model_changed", trigger: "manual", before: 12000,
      after: 2500, exact: false, running: false)
    #expect(success.label == "Context compacted")
    #expect(success.counts == "12k → ≈2.5k tokens")
    #expect(success.detail == nil)
    #expect(success.trigger == "manual")
    #expect(!success.running && !success.failed)
    let interrupted = TranscriptPresentation.compactionContent(
      status: "running", reason: nil, trigger: "unexpected", before: nil, after: nil,
      exact: false, running: false)
    #expect(interrupted.label == "Context compaction interrupted")
    #expect(interrupted.failed && !interrupted.running)
    #expect(interrupted.trigger == "automatic")
    let partial = TranscriptPresentation.compactionContent(
      status: "succeeded", reason: nil, trigger: nil, before: .nan, after: 800,
      exact: false, running: false)
    #expect(partial.counts == "≈800 tokens after")
    let failed = TranscriptPresentation.compactionContent(
      status: "unknown", reason: "outcome_unknown", trigger: nil, before: -1, after: .infinity,
      exact: true, running: false)
    #expect(failed.failed)
    #expect(failed.counts == nil)
    #expect(failed.detail == "Response lost; it may have completed.")
  }
  @Test func liveInputWordingRejectsUnknownStatuses() {
    #expect(TranscriptPresentation.liveInputLabel("pending") == "Steering current run…")
    #expect(TranscriptPresentation.liveInputLabel("applied") == "Consumed by current run")
    #expect(TranscriptPresentation.liveInputLabel("queued") == "Queued as next turn")
    #expect(
      TranscriptPresentation.liveInputLabel("uncertain") == "Delivery uncertain — not retried")
    #expect(TranscriptPresentation.liveInputLabel("cancelled") == "Cancelled")
    #expect(TranscriptPresentation.liveInputLabel("unknown") == nil)
  }
  @Test func onlyRunningMessagesScheduleElapsedTicks() {
    #expect(TranscriptPresentation.needsElapsedTimeline(status: "running"))
    for status in ["complete", "failed", "cancelled", "interrupted", "queued", ""] {
      #expect(!TranscriptPresentation.needsElapsedTimeline(status: status))
    }
  }

  @Test func adjacentSameToolClustersAndChronologySurvives() throws {
    let a = WebMessagePart.toolCall(try TranscriptFixture.tool(1))
    let b = WebMessagePart.toolCall(try TranscriptFixture.tool(2))
    let text = WebMessagePart.text(.init(text: "Between calls"))
    let rows = TranscriptPresentation.clusters([a, b, text, a])
    #expect(rows.map(\.id) == [0, 2, 3])
    #expect(rows.map { $0.parts.count } == [2, 1, 1])
    var ask = try TranscriptFixture.tool(1)
    ask.toolName = "AskUser"
    #expect(TranscriptPresentation.clusters([.toolCall(ask), .toolCall(ask)]).count == 2)
    #expect(TranscriptPresentation.failed(try TranscriptFixture.tool(2)))
  }
  @Test func activityBandsPreserveOrderAndExcludeAnswerSurfaces() throws {
    let tool = WebMessagePart.toolCall(try TranscriptFixture.tool(1))
    let text = WebMessagePart.text(.init(text: "A fictional response"))
    var ask = try TranscriptFixture.tool(1)
    ask.toolName = "AskUser"
    let bands = TranscriptPresentation.activityBands([tool, tool, text, .toolCall(ask), tool])
    #expect(bands.map(\.id) == [0, 2, 3, 4])
    #expect(bands.map { $0.parts.count } == [2, 1, 1, 1])
    #expect(bands.flatMap(\.parts) == [tool, tool, text, .toolCall(ask), tool])
    #expect(!TranscriptPresentation.isActivity(.toolCall(ask)))
  }
  @Test func previewsDoNotConfusePathsCommandsOrDates() throws {
    var call = try TranscriptFixture.tool(1)
    call.args = .object(["file_path": .string("docs/sample.md")])
    #expect(TranscriptPresentation.preview(call) == "docs/sample.md")
    #expect(TranscriptPresentation.clusterSummary([call, call]) == "sample.md")
    call.toolName = "Bash"
    call.args = .object(["command": .string("cd '/tmp/sample dir' && git status")])
    #expect(TranscriptPresentation.preview(call) == "git status")
    #expect(!TranscriptPresentation.pathLike("2030/01/02"))
    #expect(!TranscriptPresentation.pathLike("git clone https://example.com/repo"))
    #expect(TranscriptPresentation.verb("memory_search") == "Memory search")
    call.args = .string(String(repeating: "x", count: 200))
    #expect(TranscriptPresentation.preview(call).count == 72)
  }
  @Test func durationsAndCostsNeverInventZero() {
    #expect(TranscriptPresentation.duration(nil) == nil)
    #expect(TranscriptPresentation.duration(.nan) == nil)
    #expect(TranscriptPresentation.duration(-1) == nil)
    #expect(TranscriptPresentation.duration(42) == "42ms")
    #expect(TranscriptPresentation.duration(1240) == "1.2s")
    #expect(TranscriptPresentation.cost(.unknown(knownSpend: nil)) == "Cost unknown")
    #expect(TranscriptPresentation.cost(.known(0)) == "$0.0000")
    #expect(TranscriptPresentation.cost(.unknown(knownSpend: 0.25)).contains("unknown"))
  }
  @Test func markersKeepServerOrderEvenWithReversedTimestamps() throws {
    let a: WebConversationMarkerPart = try TranscriptFixture.decode(
      #"{"type":"conversation-marker","at":"2030-01-02T12:00:00Z","kind":"compaction","status":"skipped","trigger":"manual","reason":"nothing_to_compact"}"#
    )
    var b = a
    b.kind = "resumed"
    b.at = "2030-01-01T12:00:00Z"
    let labels = TranscriptPresentation.markerLabels([
      .conversationMarker(a), .text(.init(text: "hello")), .conversationMarker(b),
    ])
    #expect(labels[0].contains("skipped"))
    #expect(labels[1].contains("Resumed"))
    b.kind = "compaction"
    b.status = "succeeded"
    b.tokensBefore = 1e100
    b.tokensAfter = 1e90
    #expect(!TranscriptPresentation.marker(b).isEmpty)
  }
  @Test func manualCompactionUsesNestedEvidenceAndFencesOlderOrAutomaticResults() throws {
    var message = try TranscriptFixture.message(
      id: "compaction-result", role: "assistant", text: "")
    var telemetry: TelemetryPart = try TranscriptFixture.decode(
      #"{"type":"telemetry","event":"runtime","data":{"kind":"context_compaction","data":{"status":"succeeded","trigger":"manual","timestamp":1893585600000,"tokensBefore":12000,"tokensAfter":2000}}}"#
    )
    #expect(
      TranscriptPresentation.compaction(telemetry, running: false)?.contains("12k → ≈2k")
        == true)
    message.parts = [.telemetry(telemetry)]
    #expect(
      TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T11:59:00.000Z"))
    #expect(
      !TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T12:01:00Z"))
    telemetry.data = .object([
      "kind": .string("context_compaction"),
      "data": .object([
        "status": .string("running"), "trigger": .string("automatic"),
        "timestamp": .number(1_893_585_600_000),
      ]),
    ])
    message.parts = [.telemetry(telemetry)]
    #expect(
      !TranscriptPresentation.hasManualCompactionResult(message, since: "2030-01-02T11:59:00Z"))
    #expect(
      TranscriptPresentation.compaction(telemetry, running: false)?.contains("interrupted") == true)
  }
  @Test func requestedOnlyDoesNotClaimExecutionAndFallbackStaysFlagged() throws {
    var value: WebRunAttribution = try TranscriptFixture.decode(
      #"{"requested":{"model":"sample:small","effort":"none"},"executed":{},"disposition":"requested","transitions":[],"retries":[]}"#
    )
    #expect(
      TranscriptPresentation.attribution(value, status: "complete").contains("not a confirmed run"))
    value.disposition = "fallback"
    #expect(TranscriptPresentation.attribution(value, status: "running").hasPrefix("Fallback:"))
  }
  /// Web `shouldShowMessageRunAttribution` cases: only a deviating run keeps the footer.
  @Test func runAttributionShowsOnlyForDeviatingRuns() throws {
    func attribution(_ json: String) throws -> WebRunAttribution {
      try TranscriptFixture.decode(json)
    }
    let ordinary = try attribution(
      #"{"requested":{"model":"sample:large","effort":"high"},"executed":{"model":"sample:large","effort":"high"},"disposition":"executed","transitions":[],"retries":[]}"#
    )
    #expect(!TranscriptPresentation.showsRunAttribution(nil, status: "complete"))
    #expect(!TranscriptPresentation.showsRunAttribution(ordinary, status: "complete"))
    #expect(!TranscriptPresentation.showsRunAttribution(ordinary, status: "running"))
    var fallback = ordinary
    fallback.disposition = "fallback"
    #expect(TranscriptPresentation.showsRunAttribution(fallback, status: "complete"))
    let transition = try attribution(
      #"{"requested":{"model":"sample:large"},"executed":{"model":"sample:large"},"disposition":"executed","transitions":[{"from":"sample:large","to":"sample:small"}],"retries":[]}"#
    )
    #expect(TranscriptPresentation.showsRunAttribution(transition, status: "complete"))
    let retry = try attribution(
      #"{"requested":{"model":"sample:large"},"executed":{"model":"sample:large"},"disposition":"executed","transitions":[],"retries":[{"model":"sample:large","reason":"rate limited"}]}"#
    )
    #expect(TranscriptPresentation.showsRunAttribution(retry, status: "complete"))
    // Effort the provider did not honour; "none" and "off" are the same level.
    var effort = ordinary
    effort.executed?.effectiveEffort = "medium"
    #expect(TranscriptPresentation.showsRunAttribution(effort, status: "complete"))
    #expect(TranscriptPresentation.effortChange(effort) == "Requested High → effective Medium")
    var off = ordinary
    off.requested.effort = "none"
    off.executed?.effectiveEffort = "off"
    #expect(!TranscriptPresentation.showsRunAttribution(off, status: "complete"))
    #expect(TranscriptPresentation.effortChange(off) == nil)
    // An unsettled run already attempting another model shows; once complete it does not.
    let attempting = try attribution(
      #"{"requested":{"model":"sample:large","effort":"high"},"attempted":{"model":"sample:small","effort":"high"},"disposition":"attempted","transitions":[],"retries":[]}"#
    )
    #expect(TranscriptPresentation.showsRunAttribution(attempting, status: "running"))
    #expect(TranscriptPresentation.showsRunAttribution(attempting, status: "failed"))
    #expect(!TranscriptPresentation.showsRunAttribution(attempting, status: "complete"))
    let sameModel = try attribution(
      #"{"requested":{"model":"sample:large"},"attempted":{"model":"sample:large"},"disposition":"attempted","transitions":[],"retries":[]}"#
    )
    #expect(!TranscriptPresentation.showsRunAttribution(sameModel, status: "running"))
    let unreportedModel = try attribution(
      #"{"requested":{},"attempted":{"model":"sample:small"},"disposition":"attempted","transitions":[],"retries":[]}"#
    )
    #expect(!TranscriptPresentation.showsRunAttribution(unreportedModel, status: "running"))
  }

  @Test func thoughtsPreviewAsProseAndUnreadableThoughtsAreNotSteps() throws {
    #expect(!TranscriptPresentation.hasReadableThought("."))
    #expect(!TranscriptPresentation.hasReadableThought("** -- ##"))
    #expect(TranscriptPresentation.hasReadableThought("🌱"))
    #expect(TranscriptPresentation.hasReadableThought("Plan 2"))
    #expect(
      TranscriptPresentation.thinkingPreview("## **Checking** the `sample`\n\n> outline")
        == "Checking the sample outline")
    #expect(
      TranscriptPresentation.thinkingPreview("```\nlet x = 1\n``` After code") == "After code")
    let long = String(repeating: "word ", count: 30)
    let preview = TranscriptPresentation.thinkingPreview(long)
    #expect(preview.count == 52)
    #expect(preview.hasSuffix("\u{2026}"))
    let dot = WebMessagePart.reasoning(.init(type: "reasoning", text: "."))
    let thought = WebMessagePart.reasoning(.init(type: "reasoning", text: "Reading files"))
    let tools = [
      WebMessagePart.toolCall(try TranscriptFixture.tool(1)),
      .toolCall(try TranscriptFixture.tool(2)),
    ]
    #expect(TranscriptPresentation.activityStepCount([dot, thought] + tools) == 3)
    #expect(!TranscriptPresentation.isShown(dot))
    #expect(TranscriptPresentation.failedLabel(0, clustered: true) == nil)
    #expect(TranscriptPresentation.failedLabel(1, clustered: false) == "failed")
    #expect(TranscriptPresentation.failedLabel(2, clustered: true) == "2 failed")
  }

  @MainActor @Test func bandChoicesOutliveRowsAndYieldToSettle() {
    let disclosures = TranscriptDisclosures()
    #expect(disclosures.isOpen("m#band-0", running: true))
    #expect(!disclosures.isOpen("m#band-0", running: false))
    // Collapsed while streaming, then the turn settles: still collapsed (web collapseOnSettle).
    disclosures.choose("m#band-0", open: false, running: true)
    #expect(!disclosures.isOpen("m#band-0", running: true))
    // Opened while streaming: the settle collapses it.
    disclosures.choose("m#band-0", open: true, running: true)
    #expect(disclosures.isOpen("m#band-0", running: true))
    #expect(!disclosures.isOpen("m#band-0", running: false))
    // Reopened after settling: it stays open, independent of other bands.
    disclosures.choose("m#band-0", open: true, running: false)
    #expect(disclosures.isOpen("m#band-0", running: false))
    #expect(!disclosures.isOpen("m#band-2", running: false))
    #expect(!disclosures.isOpen("other#band-0", running: false))
  }

  @Test func runningIndicatorFollowsTheLastShownPart() throws {
    let tool = WebMessagePart.toolCall(try TranscriptFixture.tool(1))
    #expect(!TranscriptPresentation.endsWithProse([]))
    #expect(!TranscriptPresentation.endsWithProse([.text(.init(text: "Hi")), tool]))
    #expect(TranscriptPresentation.endsWithProse([tool, .text(.init(text: "Answer"))]))
    #expect(!TranscriptPresentation.endsWithProse([tool, .text(.init(text: ""))]))
  }

  @Test func scrollFollowRequiresUserProximityAndPagingNeverFollows() {
    var policy = TranscriptFollowPolicy()
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 0), userDriven: false)
    #expect(policy.shouldFollowWrite)
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 0), userDriven: true)
    #expect(!policy.shouldFollowWrite)
    policy.jump()
    policy.paging = true
    #expect(!policy.shouldFollowWrite)
    policy.paging = false
    #expect(policy.shouldFollowWrite)
    policy.update(
      .init(contentHeight: 2000, viewportHeight: 1000, contentOffset: 960), userDriven: true)
    #expect(policy.following)
  }
  @Test func unreadablePartsAndFixtureDeltasDecodeWithoutWholeMessageFailure() throws {
    let part: WebMessagePart = try TranscriptFixture.decode(#"{"type":"text","text":42}"#)
    #expect(part.decodingDiagnostic == .unreadableKnownKind("text"))
    for index in 1...8 {
      let event = try TranscriptFixture.delta(index)
      #expect(event.event.name == "message.delta")
    }
  }
  @Test func longFixtureHasFiveHundredRowsAndSeparateOlderPage() throws {
    #expect(try TranscriptFixture.messages(.conversationLong).count == 500)
    #expect(try TranscriptFixture.messages(.conversationLong, older: true).count == 40)
  }
}
