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
  `nextCursor`, `freshness`, `runningConfirmed` and `truncated`. Historical turn groups
  derive from message IDs; only the current turn has a server run-state projection.
  Never infer confirmed running from a hydrated `runState.status`: use
  `isRunningConfirmed(threadID:)` for fleet/bucket rows and `runningConfirmed` for detail.
- Read `connection`, `freshness`, `errorMessage`, `storage`, `authoredStorage`,
  `journalStorage`, `pendingSubmissions`, `draftClearStorage`, `serverClockOffset`, and `serverNow()`.
- Commands: `start`, `hydrate`, `select(sourceID:archived:threadID:)`, `loadOlder`,
  `refreshBucket(_:older:)`, `markVisible`, `reconcile`, `repairMessage`,
  `repairToolOutput`, `cancel(threadID:)`, `scenePhaseChanged`, and `stop`.
  Call `markVisible(true)` only when that transcript is actually visible; selection alone
  does not mark it read. Call false when it leaves the visible surface.
- Composer: `draft(sourceID:threadID:)`, `setDraft`, `canSend`, `canUpload`, `stageUploads`,
  `stagedAttachments`, `discardStagedUploads`, `createConversation`, and `submit`.
  New conversations are created **before** submission recovery. Pass `draftContext` when
  the authored draft still belongs to a source's new-conversation context. Switching context
  cancels uploads and disposes reservations; bytes and capability URLs are never restored.
- `enqueueThreadWrite` serializes pending settings/project edits; `settleThreadWrites`
  completes before a submission POST. Each write has the web's 15-second deadline. A failed
  edit is reported once, a successful later edit clears it, and drained tails are removed.
- `setDataMode(.auto/.lean/.full)` persists per console. Auto uses full unless the app's
  NWPathMonitor adapter reports Low Data Mode. Full publishes applied deltas immediately;
  lean batches only transcript publication for one second, never terminal writes, and halves
  thread/message page sizes (50→25 and 30→15). The cache reducer always applies every delta immediately.

`ConsoleEventSource`, `StreamClock` and `UploadReservations` are injectable boundaries.
The live app uses Kit's single EventStream; Store debounces subscription changes by 250 ms.
Every discontinuity reconciles selected detail, current bucket, active fleet and source
registries. Real gaps revalidate bootstrap once; other buckets stay stale until selected.
`unreadable` repairs the identified message/thread, or marks everything stale without IDs.
Overflow is a gap, not a request for a second subscription. Message repair is single-flight
with a trailing obligation. Generation/selection guards and invalidation clocks protect
reads and 304s; deletion tombstones prevent late resurrection. Server transcript order,
message sequences and summary revisions are authoritative. Full tool repairs survive
preview writes only while server digests match.

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
Corrupt/newer/oversized files are preserved and that record becomes memory-only.
The Store exposes separate failure states; cache degradation cannot evict authored data.
Profile removal deletes all its identity namespaces, and late flushes cannot recreate them.
An endpoint edit creates a new UUID namespace; no advertised-hostname alias merging occurs.

Bounds per namespace:

| Record | Bounds |
|---|---|
| In-memory detail | 8 conversations, 256 observation clocks |
| Deletion barriers | 256 tombstones, 30 days; explicit removal or two confirming 404s; newer authoritative revisions lift barriers |
| Cache | 24 conversations, 24 buckets, 30 days, 16 MiB total; 2 MiB per conversation |
| Authored | 40 text drafts, 32,768 characters each, 30 days; 200 LRU seen revisions; 6 MiB |
| Journal | 1 MiB; dispatched references never age-evicted; prepared references expire after 24 h only after an authoritative 404 |

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
response cache is used. Read/write failure states must remain visible in future feature UI.

A submission UUID and payload digest are durably journaled **before POST**. Failure to write
that reference prevents dispatch. Provably undispatched exits remove the prepared reference
and re-save; a failed save also rolls it back in memory. Dispatch is marked at the POST call
boundary, never while waiting on authored state/thread writes. A crash inside POST may leave
only the prepared checkpoint, which is still recovered exclusively by GET. The journal
contains no immutable payload, upload bytes or capability URLs; only attachment IDs are retained.
Attachments move out of visible staging into protected in-flight ownership before POST and
are not deleted by selection/background cleanup. Known receipts release that ownership.
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
