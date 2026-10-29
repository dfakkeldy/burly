<!-- Newest entry first. Dates are local (ADT), matching the commit that adds them. -->

## 2026-10-29 — Phone Settings ships the display unit phone-only and the rest default read-only

Spec §9 lists "display unit (kg/lb)" and "global rest default" among the phone
Settings rows, and planning task m5-05 is titled for both. The Settings screen
delivers the first on iPhone only and shows the second without a control. Both
gaps have one cause: the watch can only honour either setting if it arrives in
the §5 phone→watch snapshot, and the Settings task deliberately leaves the
snapshot wire format alone.

- **Display unit.** The kg/lb choice lives in the phone's UserDefaults and
  drives History, the set editor and Stats. Apple Watch still logs and shows
  kilograms, and the unit footer says so. §9 acceptance #2 ("render correctly in
  lb everywhere") is therefore met on the phone, not yet on the watch.
- **Rest default.** The row shows the §3 global default the watch actually
  uses (90 s) and points at per-exercise rest in routines, which is editable
  and does reach the watch. A phone-side control that the watch ignored would
  be a row that silently does nothing, which Settings avoids everywhere else.

Follow-up, still open: add the display unit and an editable global rest default
(the §3 range in `RestDuration`) to the snapshot, resolve rest on the watch as
override → routine → global, and render watch weights through `WeightUnit`.
Until that lands, m5-05's "rest default" item and the watch half of §9
acceptance #2 are not done, whatever the Settings screen looks like.

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
