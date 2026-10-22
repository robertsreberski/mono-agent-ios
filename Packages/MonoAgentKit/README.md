# MonoAgentKit seams

Connection-only API v1 projections are hand-written from the upstream health and bootstrap
contracts. Unknown bootstrap fields are deliberately ignored. C3 expands these DTOs and
replaces the provisional scenario payloads with published C1 goldens without renaming
`connection-empty`, `connection-failed`, or `console-online`.

`ConsoleEndpoint` is the only URL normalizer. `RequestBuilder` supplies root routes and
claimed origin for future manifest-marked requests. `HTTPTransport` is injectable and
`URLSessionTransport` owns an ephemeral, cache-free, cookie-free session. Redirects are
rejected; TLS uses system validation. No requests are retried automatically.

C3 adds explicit ETags, bounded incremental SSE parsing, injected clock/jitter and byte
streams. Unknown future SSE envelope versions must be skipped **per frame**, not stop sync.
Never use Last-Event-ID as replay; reconcile after ready. No SSE implementation is claimed here.

`MonoAgentTestSupport` owns synthetic, versioned scenario names and per-instance scripts.
Script exhaustion always fails, never accesses the network. FixtureEnvironment provides
fixed time/identity and caller-owned isolated storage; add byte-stream/clock/random
protocols when C3 has concrete consumers.
