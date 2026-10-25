# MonoAgentStore

Swift 6, Observation and Foundation; no SwiftUI/UIKit or Combine in the package.
`@MainActor @Observable ConsoleStore` owns one console in the single supported scene.
Network I/O uses `MonoAgentKit.ConsoleAPI` and `EventStream`; actors own disk I/O.

## Feature UI seam

AppModel constructs the selected console's Store after a successful connection. A saved
identity can hydrate offline without probing; losing connectivity retains that Store.
Screens must not instantiate API clients or submit directly.

- Read `agents`, `buckets[BucketKey(sourceID:archived:)]`, `activeFleet`, `tags`, `projects`,
  `selectedBucket`, `selectedThreadID`, `selectedConversation`, and `isUnread(thread)`.
- Observe the small `ConversationState`: ordered `messages`, grouped `turns`, `thread`,
  `nextCursor`, `freshness`, `runningConfirmed` and `truncated`. Stable `orderedMessageIDs` / `messageStates` (`TranscriptMessageState.message` and `turnID`)
  let lazy rows observe only their message. Historical turn groups
  derive from message IDs; only the current turn has a server run-state projection.
  Never infer confirmed running from a hydrated `runState.status`: use
  `isRunningConfirmed(threadID:)` for fleet/bucket rows and `runningConfirmed` for detail.
- Read `connection`, `freshness`, `errorMessage`, `storage`, `authoredStorage`,
  `journalStorage`, `pendingSubmissions`, `draftClearStorage`, `serverClockOffset`, and `serverNow()`.
- Commands: `start`, `hydrate`, `select(sourceID:archived:threadID:)`, `loadOlder`,
  `refreshBucket(_:older:)`, `markVisible`, `reconcile`, `repairMessage`,
  `repairToolOutput`, `cancel(threadID:)`, `scenePhaseChanged`, `clearErrorMessage`, and `stop`.
- Activity: `refreshJob(threadID:jobID:)` refreshes a held job with monotonic lifecycle merging; `refreshUsage(threadID:)` publishes ephemeral `ConversationState.usage` and its summary revision. Both refuse offline/background/stopped calls and discard late results. `JobPresentation`, `JobShelf` and `UsagePresentation` are pure presentation decisions. The pinned API has no per-job stop or full-log route; output references are not URLs.
- Search: `searchThreads(sourceID:query:) -> ThreadSearchResult` is the web console's
  server-side `chats`-scope search. Trimmed queries shorter than `minimumSearchQuery` (2)
  return an empty result without a request; an offline-hydrated, stopped or backgrounded
  Store throws `ConsoleSearchError.unavailable` without a request; a late answer after
  stop/background throws `CancellationError`. Hits never patch buckets, the fleet, the cache
  or read markers, and tombstoned conversations are filtered. Debounce belongs to the caller.
  Call `markVisible(true)` only when that transcript is actually visible; selection alone
  does not mark it read. Call false when it leaves the visible surface.
- Composer: `draft(sourceID:threadID:)`, `setDraft`, `canSend`, `canUpload`, `stageUploads`,
  `stagedAttachments`, `uploadProgress`, `discardStagedUpload(_:)`, `discardStagedUploads`,
  `createConversation(_:retainingAttachments:)`, and `submit`.
  `prepareSubmission` allocates a frozen attempt identity (or reuses matching pending recovery).
  Keep that input through explicit retries and pass its ID as `submit(attemptID:)`, even after
  receipt recovery retires the journal. Legacy callers omit attemptID and retain digest-based
  Store allocation (their wire input ID is intentionally ignored).
  `submit(draftBinding:)` accepts an exact authored key/version or `.none` for quick replies;
  retries never rebind a pending identity to a newer draft. Known receipts are held in a bounded
  memory cache, so retry after recovery resolves without another POST; the frozen UUID still
  provides server idempotency if that cache ages out.
  New conversations are created **before** submission recovery. Pass `draftContext` when
  the authored draft still belongs to a source's new-conversation context; pass the staged
  attachment IDs as `retainingAttachments` so creation's own selection change keeps them.
  Reselecting the same context, run-state changes, refresh/reconnect and scene suspension keep
  staged files and in-flight uploads in memory. Draft attachment ownership is keyed by source
  and thread, not the sidebar archive filter. Archive/delete selection exits abandon that context
  too. Only explicit context abandonment (including
  terminal Store stop), removal or confirmed admission clears them; suspension does not.
  Switching context cancels uploads and disposes reservations; bytes and capability URLs are
  never restored. `canSend`/`canUpload` mirror the web console: live connection, agent online
  (and accepting attachments), and the thread's flags; a new conversation follows its agent.
  `stageUploads` validates the bootstrap limits before any progress row appears;
  `uploadProgress` lists files still uploading (memory only). `discardStagedUpload` removes
  one chip and never touches files protected by an active submission.
- Composer support: `skillRegistries` / `loadSkills(sourceID:)` (a failed refresh keeps
  earlier items as stale, which disables insertion); `askSnapshot(threadID:interactionID:)`
  (exact by-id read when known, else the pending ask) and `answerAsk(…)` (`POST
  /threads/:id/ask`; `invalid_answer` → `AskAnswerError.incomplete`); `setRunOverride(threadID:
  model:effort:)` — optimistic per-conversation model/effort through `enqueueThreadWrite`,
  newest-choice publication with rollback to confirmed (not optimistic) settings when refused,
  so a following submission settles after it. Stopped/stopping/backgrounded stores refuse writes
  both at entry and queue execution. Ask reads/answers discard late results after lifetime,
  selection or held-conversation replacement.
  `cancel(threadID:)` sends the contract's `user-stop` origin and adopts the returned thread.
- `enqueueThreadWrite` serializes pending settings/project edits; `settleThreadWrites`
  completes before a submission POST. Each caller's 15-second deadline starts at enqueue,
  including queue wait. An expired queued write never starts. Cancelling settlement stops
  only that caller's wait, without releasing the real write-ordering barrier. A failed
  edit is reported once, a successful later edit clears it, and drained tails are removed.
  Timeout/cancellation settles the caller but **not** the physical write queue: a transport
  that ignores cancellation blocks subsequent writes on that thread until it actually completes.
- `setDataMode(.auto/.lean/.full)` persists per console. Auto uses full unless the app's
  NWPathMonitor adapter reports Low Data Mode. Full coalesces transcript publication at 12 Hz; terminal writes remain immediate.
  Lean batches only transcript publication for one second, never terminal writes or shared run
  metadata, and halves
  thread/message page sizes (50→25 and 30→15). The cache reducer always applies every delta immediately.

`TranscriptFollowPolicy` / `TranscriptScrollMetrics` are pure, host-tested scroll decisions:
short content counts as bottom, and only user scroll gestures change follow intent.
Authoritative detail reads synchronize held bucket/fleet summaries; older listings cannot
replace a newer held detail. Run metadata publishes immediately even in lean mode.

`ConsoleEventSource`, `StreamClock` and `UploadReservations` are injectable boundaries.
The live app uses Kit's single EventStream; Store debounces subscription changes by 250 ms.
Every discontinuity reconciles selected detail, current bucket, active fleet and source
registries. Real gaps revalidate bootstrap once; other buckets stay stale until selected.
`unreadable` repairs the identified message/thread, or marks everything stale without IDs.
Overflow is a gap, not a request for a second subscription. Message repair is single-flight
with a trailing obligation. Generation/selection guards and invalidation clocks protect
reads and 304s; deletion tombstones prevent late resurrection. Server transcript order,
message sequences and summary revisions are authoritative. Legacy tombstones without a known
origin are weak barriers and can also be repaired by a fresh authoritative equal-revision row. `repairToolOutput` returns Bool (discardable): true only when a matching held part changed;
  false for a stale/no-op/failed repair, so a UI cannot claim a successful load. Full tool repairs survive
preview writes only while server digests match.

## Rich reply parts

- `downloadReplyAttachment(threadID:messageID:partID:)` resolves only a held part of the
  selected conversation and returns a `ReplyFileLease` containing a local URL. Release it
  after preview/export. Late lifetime, selection or part-identity changes are discarded.
  Kit owns fresh access, one access-expiry renewal, identity/integrity checks and bounded
  binary transfer; neither UI nor disk cache receives capability URLs.
- `ReplyFileCache` retains at most 64 MiB / 24 files / 24 hours, 32 MiB per file. Active
  leases prevent eviction; a full pinned cache refuses another insertion. Disk contains
  bytes beneath hashed identity directories with sanitized export basenames, excluded from backup and protected on iOS.
  `clearReplyFileCache` removes unleased bytes and decoded retention.
- `decodeReplyImage(_:)` uses `ReplyImageCache`'s off-main ImageIO actor: raster-only,
  source <=40 million pixels / 16,384 per edge, decoded <=2,048 per edge. Decoded retention
  is 24 images / 32 MiB / 60s (lean: 8 / 8 MiB / 20s). Active UI images are not retained-cache entries.
- `downloadMessageAttachment(threadID:messageID:attachmentID:)` reads only a held sent
  upload (`committed` and `uploaded`) through Kit's bounded authenticated upload-content route.
  It derives that route from the durable ID and ignores any advertised `contentUrl`. The
  existing durable reply `storedUrl` handling is unchanged. It shares the leased file/image
  caches, validates size and lifetime/selection/file identity, and treats missing/deleted
  uploads as unavailable. No DTO URLs are written into the byte cache or re-adopted into history.
- Reply and sent-upload GIFs intentionally show their first decoded frame, unlike the web's
  animation; PNG/JPEG/GIF/WebP use the same bounded raster decoder. Sent files reuse native
  QuickLook, Share and Save-to-Files actions; sent raster images reuse the strip/lightbox.
- `restartProposalState`, `restartUnavailableReason`, `requestRestartConfirmation`,
  `cancelRestartConfirmation`, `confirmRestart` and `pollRestartProposal` own ephemeral
  proposal state. Only a confirmed available proposal can POST, never automatically.
  Polling is caller-cancellable and uses the injected clock; lost POST recovery requires
  latest-operation correlation with this exact persisted proposal, never a mutation retry.

## Persistence and recovery

`ConsoleRepository` separates cache, authored state, and journal operations.
`FileConsoleRepository` stores atomic versioned JSON beneath Application Support:

```
MonoAgent/Consoles/<profile UUID>/<SHA256(endpoint + console identity)>/
  cache-v1.json
  authored-v1.json
  journal-v1.json
```

Each record has independent monotonic revisions; stale/equal saves cannot replace newer
ones. Save commands return `RepositorySaveResult.saved` or `.superseded(revision:)`.
The Store and headless service reload/rebase and retry once; a second superseding write
remains explicitly non-durable (`PersistenceState.superseded`, `ChangeSummary.persisted == false`).
Authored rebasing merges drafts by key, version and update time and keeps the highest seen
revision per thread. A known deleted draft version cannot erase another writer's newer draft.
A draft unchanged from the loaded baseline stays deleted if another writer removed its key.
Stopped stores cannot flush authored state, including late submission confirmations.
AppModel serializes replacement, awaiting the old store's final flush before the next hydrate;
quick requests coalesce to the latest selection. Connection-shell readiness is published after
the profile/probe phase, not after Store I/O; feature data must use `store.hydrated`/freshness.
DEBUG Store scenarios still wait for their prepared Store state before declaring readiness.
Corrupt/newer/oversized files are preserved and that record becomes memory-only.
The Store exposes separate failure states; cache degradation cannot evict authored data.
Profile removal deletes all its identity namespaces, and late flushes cannot recreate them.
An endpoint edit creates a new UUID namespace; no advertised-hostname alias merging occurs.

Bounds per namespace:

| Record | Bounds |
|---|---|
| In-memory detail | 8 conversations, 256 observation clocks |
| Deletion barriers | 256 tombstones, 30 days; explicit removal or two 404s ≥5 s apart; a newer revision lifts an explicit-removal barrier, any authoritative row fetched after removal lifts a not-found barrier |
| Cache | 24 conversations, 24 buckets, 30 days, 16 MiB total; 2 MiB per conversation |
| Authored | 40 text drafts, 32,768 characters each, 30 days; 200 LRU seen revisions; 6 MiB |
| Journal | 1 MiB / 50 entries for new writes; oldest non-active uncertain dispatched references evicted first. A dispatched reference with an authoritative 404 expires 30 days after its latest dispatch checkpoint. Historical prepared identities are never automatically age/count-evicted; if they fill capacity, sends fail with visible guidance and explicit acknowledged forgetting can free a slot |

Drafts flush after 500 ms and on context/background changes. Cache flushes batch at one
second. Oversized cached history is explicitly `truncated`, with paging disabled until a
fresh detail supplies a valid cursor. Cache eviction retains up to 24 previously persisted
details independently of the eight held in memory. Authored data and journal are separate
from cache pruning. Cache hydration and writes strip capability URLs, all validators,
transient compaction and legacy silent-cron rows (including count/preview corrections).
Durable attachment `storedUrl` is retained. Opaque tool payload keys such as `token` and
`expiresAt` are not reinterpreted or removed; stripping is scoped to the reference's
attachment/MCP capability fields. Authored capability links are scrubbed too.

Files are excluded from backup and use complete protection until first authentication on
iOS. This is OS-protected local data, not application-level encryption. No shared network
response cache is used. Read/write failure states must remain visible in future feature UI. Backup-exclusion tests run
on host/simulators. The explicitly named `physicalDeviceOnly…` protection-attribute test is
excluded on CoreSimulator, is **not CI coverage**, and requires a physical iOS test run.

A submission UUID and payload digest are durably journaled **before POST**. After settling
thread writes, a second durable checkpoint marks the reference possibly dispatched; POST is
strictly gated on that save. A checkpoint is not proof of admission. New references carry per-entry `dispatchProtocol: 1`, declaring that POST requires the
checkpoint. A marked `dispatched: false` reference therefore proves no POST occurred and is
retired at hydration without receipt polling (also if a previous cleanup save failed).
Resolved and idle provably-undispatched entries never consume admission capacity.
Only unmarked/legacy prepared references remain historical uncertainty through retries and
relaunch, unless a receipt resolves them. A later failed preflight or rejection cannot erase an earlier ambiguous
attempt. Historical oversized journals retain those protected identities but cannot grow;
repository writes reject >50 entries. The 50-entry cap and 30-day dispatched-404 policy are
explicit retention limits, **not proof of non-admission**: check the transcript before sending
again after an uncertain identity has been evicted. Recovery never submits automatically. `forgetRecoveryReference(_:acknowledgingPossibleAdmission:)`
is an explicit user action, requires risk acknowledgement, and refuses active POST/recovery
owners. It saves the removal durably and reports failures; it never sends or DELETEs uploads.
Forgetting cannot undo an admission and ends same-UUID recovery for that reference.
The journal contains no immutable payload, upload bytes or capability URLs, only attachment IDs
and identity/dispatch metadata. Payload IDs are protected before the first submit suspension.
Files stay staged through preparation and POST; selection/background cannot DELETE owned files.
All non-admission exits release protection and retain staging. Unchanged uncertain retries keep
the digest and UUID; a compaction HTTP rejection with absent receipt also keeps an in-memory
retry identity. A known receipt settles its journal identity. Admission removes staged files
without DELETE; rejection retains them. Only explicit context abandonment with no active owner
can DELETE staged files. Recovery rechecks active submissions and the live dispatch checkpoint after every receipt GET;
a stale 404 cannot expire a reference whose checkpoint changed while the GET was pending.
Relaunch, foreground and reconnect recover by receipt GET only; there is no offline send
queue or automatic resend. An explicit unchanged retry reuses the UUID, including across
relaunch; changed input gets another UUID. Only confirmed admission clears the exact draft
version. A newer edit survives an older admission. Known admission always retires the UUID,
even if draft clearing cannot be saved; `draftClearStorage` reports that separate durability.
An authored record degraded to memory-only does not disable sending. A real authored write
failure blocks that attempt without leaving a prepared journal ghost. Journal/draft failures
never claim durable recovery. Definite rejection retains authored text; compaction busy refreshes detail/bootstrap.

`ReconciliationService.refresh(profile:budget:) -> ChangeSummary` is a headless actor seam
for a future poller. Its conservative first implementation performs at most one bootstrap
GET within the supplied read/time budget and persists the sanitized snapshot. It never
submits or schedules background work. Background permissions, notification policy and
multi-scene synchronization are not implemented here. `stop()` terminally disables live
network effects until an explicit `start()`. Foreground alone only resumes a started,
connected store; offline hydration never opens SSE. Interrupted initial hydration resumes
before bootstrap/stream setup when the connected scene becomes active.

## Connection registry

`ConnectionRegistry` remains MainActor/Observable; profile I/O uses `ProfileRepository`.
Profile UUIDs are namespace identity. Connect attempts carry generations so late results
cannot resurrect removed/edited consoles. Loading profiles never probes automatically.
`FileProfileRepository` stores only profile metadata in revisioned atomic JSON, excludes it
from backup and applies first-unlock protection. Mutators wait for the initial load; a failed
load stays memory-only and preserves the original file. Older v1 snapshots without revision
load as revision zero.

## Verification

```
swift test --package-path Packages/MonoAgentStore -Xswiftc -warnings-as-errors
```

Tests inject clocks, event sources, per-instance route transports and temporary storage.
They never contact a console. DEBUG app scenarios `store-offline`, `store-streaming`,
`store-unread`, `store-uncertain` use the pinned-golden-derived TestSupport bootstrap and
scripted fail-closed transports. They prepare state for feature UI; they do not add screens.
Release fixture gates reject their symbols and scenario strings.

## Ephemeral MCP sessions

`ConsoleStore` composes one `CapabilityService` from its profile endpoint and injected API.
`loadMcpApp` returns a generation-bound `McpAppAccess`; App sees only a URL-stripped resource.
`requestMcpApp`, `renewMcpApp` and `closeMcpApp` require that exact profile/part/session,
selection, Store lifetime, held conversation and authoritative (not delayed UI) part identity.
Offline, background and stopped calls are refused. Selection/background/stop clears sessions,
HTML and current access and cancels their operations. Explicit renewal invalidates older
in-flight access adoption; no late response can roll capabilities back. Matching-session
results still return, including completed confirmed effects overlapped by a renewal. Expired confirmed requests
set retryRequiresConsent and never renew/replay automatically. The bridge must obtain fresh
native consent for an explicit retry. None of this state participates in persistence.
