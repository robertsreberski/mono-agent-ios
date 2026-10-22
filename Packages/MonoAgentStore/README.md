# MonoAgentStore seams

`ConnectionRegistry` is MainActor/Observable; I/O lives behind `ProfileRepository`.
`FileProfileRepository` writes versioned atomic JSON, excluded from backup and protected
until first unlock on iOS. It stores profile metadata only, not raw bootstrap data,
cookies, transcripts, credentials or capability URLs. Storage failures are visible.

Profile UUIDs are namespace identity. Changing an endpoint replaces its UUID and clears
its identity/state, rather than merging by advertised hostname. Connect attempts carry
generations, so old results cannot resurrect removed or edited profiles. Last returned
identity is a label, not proof of a current connection. Relaunch never probes automatically.
C4 owns transcript persistence, pruning, recovery and namespace data deletion; C2 retains
no transcript data. Removing a profile deletes the only retained C2 data for it.

Mutators wait until the initial load attempt finishes. Snapshots carry monotonic revisions;
the file actor ignores stale/equal writes before atomic replacement, even if async calls
arrive out of order. Older v1 snapshots without a revision load as revision zero. After
a failed load the registry stays memory-only and preserves the unreadable file; relaunch
to retry after fixing storage.
