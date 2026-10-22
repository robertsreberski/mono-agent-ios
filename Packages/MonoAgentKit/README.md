# MonoAgentKit

Platform-neutral Swift 6 console API v1 client. No third-party packages or live console
access in tests. IDs/cursors and ISO timestamps are opaque strings; unknown response fields
are ignored. String vocabularies accept additive server values. Unknown message parts retain
opaque JSON, but cannot be installed by a delta.

## Contract and public seams

The four upstream artifacts in the **test target only** are immutable source-pinned goldens;
see `Contracts/console-api.lock.json`. There is no npm release at this pin.

- `ConsoleAPI` / actor `APIClient`: typed async methods for health/bootstrap, agents/defaults,
  provider usage/auth/check sessions, restart/proposals, skills/models, cron, threads/search/
  active fleet, messages/tool repairs/usage, projects/tags, wake schedules, compaction, turns/
  submissions/receipts/live input/cancellation, asks, uploads, reply files, MCP resources/
  requests/proxy, and the SSE request. `APIRoute` and `Contracts/routes-ledger.json` are
  generated from the manifest. Five browser Web Push operations are explicitly excluded
  because native clients have no service worker; their DTOs remain Codable.
- All manifest DTOs have Codable/Sendable models (`ApiErrorBody` is the wire error;
  `APIError` is the safe transport error). Opaque arguments/results, telemetry and peer
  schemas use `JSONValue`. `InputField` preserves omitted/null/value requests. `CostAmount`
  never turns a missing or unknown amount into zero. Response encoding is not a persistence
  format: nullable response properties may encode as omitted. Preserve the original wire
  or define a separate Store record if that distinction matters.
- `ReadResult.modified(value, etag:)` / `.notModified`: 304 is accepted only after a
  validator was supplied. Mutations never retry automatically. Cron 428 is a typed
  `WebCronMutationResult.confirmationRequired`; submission 409 decodes its receipt.
- `SSEParser`, `EventDecoder`, `WebEvent` (12 typed cases), and `ApiEvent` (envelope).
  Incremental bytes handle split UTF-8, CR/LF/CRLF, comments and multiline data. Unknown
  names/versions are skipped one frame at a time with diagnostics. Malformed known frames
  require a gap. Default line/frame limit: 2 MiB.
- Actor `EventStream.subscribe(thread:capacity:)`: generation-tagged attempts with gap
  reasons, 45-second complete-line watchdog (heartbeats count), 20-second initial ready
  deadline, injected `StreamClock`/random, jittered 1–30-second backoff and Retry-After.
  Ready resets backoff. Selection changes restart immediately; Store owns debounce and
  reconciliation. There is no Last-Event-ID/replay. Default delivery buffer: 128 updates.
  Overflow cancels the socket and finishes with `StreamDeliveryGap(.overflow)`; the consumer
  must reconcile and subscribe again, never treat queued events as a complete history.
- `DeltaReducer`: pure, transactional replay; applied/stale/gap/unknown/unheld results.
  Pass Store's repaired tool-call IDs; digest-matching full arguments/results survive
  preview writes, including subagent children. No invented consecutive-sequence condition.
- Actor `UploadService`: validates MIME/hard/server limits, accepts `existing` attachments
  for the whole turn budget, reserves metadata then streams a file through raw PUT.
  Progress is Sendable and reaches 100% only on server acceptance. Cancel the caller's
  Task; failures/cancellation delete known reservations best-effort. Returned staged files
  remain the caller's responsibility (`discard` when abandoned).
- Actor `CapabilityService`: exact part-bound root-relative URL validation; supports durable
  stored upload content and short-lived attachment/MCP resources. Read expiry
  `reply_access_expired` renews access once. MCP mutations are **not** automatically replayed;
  callers can explicitly issue access renewal before a user-requested retry.

`ConsoleEndpoint` remains the only origin normalizer and `RequestBuilder` the only URL
constructor. Every request sends `X-Mono-Agent-Web-Origin`, never a forged Host. Sessions
are ephemeral, cache-free, cookie-free and credential-store-free. Redirects are rejected;
TLS uses system validation. Transport errors discard URL-bearing userInfo; API errors retain
status/code/retry class and locally generated safe details, not server prose. Capability and
provider-auth debug descriptions redact private fields. Never persist capability URLs/auth
material or log DTO bodies.

`ConnectionProbe` uses this client and full bootstrap model, not a parallel implementation.
`MonoAgentTestSupport` keeps fictional DEBUG-only scenarios, refreshed from the pinned
bootstrap golden without renaming `connection-empty`, `connection-failed`, `console-online`.
Production Release contains no fixture resources or routing code.

## Updating and testing

```sh
./Tools/update-contract --commit <full-source-sha> --from <upstream-checkout>
./Tools/generate-routes
./Tools/check-contract --locked
swift test --package-path Packages/MonoAgentKit -Xswiftc -warnings-as-errors
```

Omit `--from` to fetch immutable GitHub raw sources. Review every import and route/type
change intentionally. The locked gate validates hashes, coverage, and each golden against
its **named definition**, using the draft-07 vocabulary present in the pin—not a claim to
be a general JSON Schema engine. Swift tests decode every golden, parse every SSE frame,
match all route descriptors and replay all 11 delta vectors. Network smoke tests use
request-local URLProtocol fixtures, with no global mutable mock registry; supervisor tests
inject byte streams and a manual clock. The advisory scheduled/manual workflow compares
upstream main and never updates the pin.
