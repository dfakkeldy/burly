<!-- Newest entry first. Dates are local (ADT), matching the commit that adds them. -->

## 2026-10-29 — Hevy import: the preview is the write plan

Spec §8 acceptance #4 asks that the preview's numbers match the import's result
exactly. Rather than computing a preview and a result separately and hoping they
agree, `BurlyImport.HevyImportPlan` holds the exact exercise and session rows the
commit will write, the preview numbers are derived from those rows, and
`apply` writes those rows and nothing else. The plan is built from the parse plus
the store's existing session and exercise IDs, so a re-import previews "0 new" and an
overlapping export previews only what is missing. The phone re-plans immediately
before writing; if the store changed under the preview, it shows the new preview
instead of writing numbers the user never saw.

Three smaller choices ride along. A catalog-matched exercise the store lacks (a
store the bundled seed never reached) is inserted as a curated row, the way the seed
would insert it, instead of failing the session write; it still counts as matched.
Hevy's CSV carries no time zone, so the phone parses in its current zone and says
so on the preview. And both entry points present the import over the tab shell,
so the welcome path and the tabs share one store instance and finishing or
cancelling lands on History.

The phone app does not own a `PhoneSyncCoordinator` yet, so an import, like every
other phone-side history edit today, refreshes local state only.
`PhoneHomeViewModel.refreshAfterHevyImport` names where `historyDidChange()` and
`catalogDidChange()` belong once that wiring exists.

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
