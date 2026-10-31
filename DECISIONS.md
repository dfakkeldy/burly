<!-- Newest entry first. Dates are local (ADT), matching the commit that adds them. -->

## 2026-10-30 — App Store listing as code with fastlane deliver; uploads stay on xcodebuild

Burly's builds already reach App Store Connect without fastlane: a release tag
archives and uploads with `xcodebuild -exportArchive` (release.yml), and that
stays. What had no home was the store page itself: listing text, screenshots,
review notes. It now lives in the repo under `fastlane/` and goes up with
`fastlane deliver` from the manual Store listing workflow, using the same App
Store Connect API key secrets. Reviewable text in a public repo beats edits made
by hand in App Store Connect, and the workflow needs no key on any Mac.

The lane edits the listing only: it never uploads a binary and never submits for
review. A pull request that touches `fastlane/` runs an offline check of App
Store Connect's length limits; only a dispatched run can reach the secrets.
The review contact's name, email and phone come from optional repo secrets, not
files, so they stay out of the public repo. `name.txt` is deliberately absent
until the existing App Store Connect record's name is confirmed, so the lane
cannot rename the app by accident.

Two answers fastlane cannot send with an API key: the App Privacy details (its
action needs an Apple ID session) and, for now, the age rating questionnaire.
Both are one-time answers in App Store Connect. The privacy answer is "Data Not
Collected", matching PRIVACY.md and the apps' privacy manifests.

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
so on the preview. Identity does not follow that zone: session, item and set IDs hash
the wall-clock `start_time` text (spec §8, "title+start_time"), not the instant it
means in the chosen zone, so re-importing after travelling or a time-zone change
still finds every workout already stored. Under UTC the key is unchanged from m7-01.
And both entry points present the import over the tab shell,
so the welcome path and the tabs share one store instance and finishing or
cancelling lands on History.

The phone app does not own a `PhoneSyncCoordinator` yet, so an import, like every
other phone-side history edit today, refreshes local state only.
`PhoneHomeViewModel.refreshAfterHevyImport` names where `historyDidChange()` and
`catalogDidChange()` belong once that wiring exists.

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

The Apple Health row is informational for a related reason. Authorization is
the watch's job at first session start (§4), no target carries a HealthKit
entitlement yet, and a status read on the phone would report the phone app's
grant, not the watch's. The row says only what is true today and opens the
Health app.

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
