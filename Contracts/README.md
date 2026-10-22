# Console API v1 contract

Pinned from `robertsreberski/mono-agent` source commit
`299996bf1cebbb9e1185e9339d99e2006dfc2ccf` (contract publication PR #1325).
No npm release exists for this snapshot; no package version/integrity is invented.
`console-api.lock.json` records the repository, full source SHA, API version, four source
paths, local test-resource paths and complete SHA-256 hashes.

```sh
./Tools/update-contract --commit <full-source-sha> [--from <local-upstream-checkout>]
./Tools/generate-routes
./Tools/check-contract --locked
```

The importer reads Git objects (not checkout dirt), or immutable GitHub raw URLs. Golden
artifacts are committed unchanged under the Kit **test** target, not the Release app.
Review generated changes, DTO compatibility and fixture privacy before updating.

`routes-ledger.json` accounts for all 78 entries: 73 covered (including `/healthz` and the
SSE request) and five `notApplicableToNative` browser Web Push subscription/ack operations.
They require browser service workers, not native notification registration; their DTOs are
still Codable. `Tools/generate-routes` generates the ledger, transport table and typed
forwarding methods; DTOs and union semantics are hand-written.

The locked gate checks all four hashes, route policy/status/coverage drift and fixture type
mappings. It validates each fictional golden against its named schema definition. This
uses the draft-07 assertions present in this pin, not a general-purpose schema validator.
Swift host tests separately decode all 35 goldens and require re-encoded JSONValue equality
(the documented intentional-difference allowlist is empty), parse every event frame, match route
metadata, and replay all 11 shared delta vectors. `--connection-only` is now a compatibility
alias for the full locked gate, never a provisional pass.

The separate advisory scheduled/manual `Contract drift` workflow compares latest upstream
main's artifacts against the lock, fails visibly on drift and **never** auto-updates files.
The required quality job always uses the offline `--locked` gate.
