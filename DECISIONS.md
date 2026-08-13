<!-- Newest entry first. Dates are local (ADT), matching the commit that adds them. -->

## 2026-08-12 — The phone-sync journal trades one redundancy for one boundary, knowingly

The two-file phone-sync persistence (authoritative sidecar + high-water log) was
replaced with a single append-only journal because the two-file design's
combinatorics — two files across absent/corrupt axes, an append path and a replace
path, a defensive max-merge, a tri-state read — produced a critical finding in each
of four consecutive review rounds. The journal collapses "first launch" and
"unrecoverable" into one boundary: file absent, versus file present with zero valid
records.

That collapse costs something real, and it is accepted rather than absent. Under the
old scheme the newest identity lived in two separate physical files, so media
corruption of one still yielded the correct identity. It now has a single physical
copy. Corrupting the newest record drops `latestSnapshotVersion` /
`lastTransferGeneration` back exactly one increment — potentially below a version the
watch has already adopted.

The regression is bounded to one step, because every earlier valid record still
contributes to the max and the load derives both identities as the maximum over all
valid records rather than reading them off the newest one. It is inherent to the
directed one-file design, not a defect in the implementation of it. Recorded here so
a future reader does not rediscover it as a bug: the redundancy was given up on
purpose, in exchange for deleting an entire class of two-file write-ordering and
orphaned-record failures that had proven, four times, to be harder to reason about
than the thing it protected against.
