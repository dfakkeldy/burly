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

## 2026-10-29 — HealthKit on the watch: the store save is the commit, Health is best-effort

Spec §4 is wired into the watch session flow through one new BurlyHealth type,
`SessionWorkoutRecorder`, which sits between the session screens and the existing
`WorkoutController`. The controller still owns the ordered end sequence; the
recorder decides whether a session gets a workout and which one.

- **Authorization** is requested from `SessionEntryView.saveAndEnter`, after the
  new session is saved, and only while HealthKit reports the workout type as not
  determined. A declined or unavailable Health means no live workout and no save,
  and nothing on screen: sets are app data and Finish never waits on or reports a
  HealthKit problem (§4 acceptance #4). Every HealthKit call except the prompt is
  bounded (10 s) so a stuck callback cannot hold Finish.
- **Finish order.** The HealthKit workout is saved first and its UUID rides in the
  same store save that marks the session logged. That save also queues the session
  for the phone (`onSessionLogged`). If the app dies between the two, the next
  Finish asks HealthKit for a workout already linked to the session (by
  `HKMetadataKeyExternalUUID`) and does not save a second one. If that question
  cannot be answered, nothing is saved: a missing workout is better than a
  duplicate. A timed-out end sequence also saves nothing more, since it may still
  complete by itself.
- **Recovery matrix.** At launch the recorder reattaches a workout HealthKit kept
  alive to the store's active session (row 1, through a new
  `WorkoutController.adopt`), or ends and discards it when the store has none
  (row 3). A finished session with no live workout, Health allowed, gets a
  duration-only workout from the non-live builder with the same metadata, and the
  summary says it has no sensor data (row 2). Resume never starts a new live
  workout. An unreadable store leaves HealthKit alone; an orphan is discarded when
  the next session starts.
- **Stale guard.** The resume gate checks the active session's last logged set
  (or its start) on every load. Past one hour it asks "Still working out?" and
  offers "End workout", which opens the usual Finish/Keep going/Discard summary
  with the session ending at that last set (`SessionEngine.finish(endingAt:)`).
  Keep going clears that end time.
- **Seeded UI-test scenarios run without Health** unless the test sets
  `BURLY_WATCH_UI_TEST_HEALTH=live`, because the system authorization sheet would
  cover the screens the existing suites drive and `simctl privacy` cannot
  pre-grant Health. `HealthKitUITests` covers the real path and skips unless the
  runner sets `BURLY_HEALTH_UI_TESTS=1`.

Both app targets carry the HealthKit entitlement and the two purpose strings; the
watch also declares the `workout-processing` background mode. The phone links no
HealthKit code yet. `HealthKitWorkoutStore.deleteWorkouts(linkedTo:)` is the §4
delete-propagation helper, but the phone has no session-delete action to call it
from, so delete propagation is not wired. The phone Settings row now describes
what the watch does; it still reads no authorization status, for the reason in
the HealthKit Settings entry below.

## 2026-10-29 — Sync is wired into both apps; the snapshot carries the unit and rest default

Phone and watch now exchange data. Each app owns one store and one sync host,
built at launch from its app delegate (Watch Connectivity can wake either app
with no view on screen): `PhoneSyncHost` binds `PhoneSyncCoordinator` to the
WCSession adapter, `WatchSyncHost` does the same for `WatchSyncCoordinator`,
and the watch delegate hands every Watch Connectivity background task to the
adapter's `hasContentPending` completion rule. UI-test scenario launches get
their seeded store and no sync, so the standalone UI suites never touch
WCSession.

Snapshot schema 2 adds the phone's display unit and global rest default. A
schema-1 body decodes as kilograms and 90 s, the only values a schema-1 phone
could have meant; schema 2 requires both keys. The rest default is clamped onto
§3's grid rather than rejected, because rejecting it would also reject every
routine in the same snapshot. The watch stores both in its sync journal, in the
same save as the working set they arrived with, so a snapshot and its settings
can never be applied separately. Before the first snapshot the watch shows
kilograms, the phone's own default; it used to hardcode pounds. The crown step
follows the unit (1.25 kg or 2.5 lb, §2's two defaults).

Choices worth knowing before changing this:

- **Every envelope goes out at schema 2**, sessions and digests included, even
  though only the snapshot changed. An older peer holds them and shows "update
  Burly" (§5) instead of reading them. The two apps ship in one bundle, so the
  mismatch only lasts until both update, and the watch keeps every session
  until it is acknowledged.
- **The launch push waits for WCSession activation**, because transfers before
  activation fail. When the watch app is installed, the install edge is the
  launch push; firing both would cancel and resend the same version.
- **A snapshot transfer that cannot start counts as a finished transfer.** The
  adapter reports it as an event rather than throwing, and the host echoes it
  to the coordinator so the outstanding-transfer slot clears.
- **Sync failures never reach an edit.** Edits are durable in the store first;
  the host logs a failed push, and §5's triggers re-send from store truth.
- **No legacy phone-sync paths are wired.** The two-file layout that
  `FileBackedPhoneSyncStatePersisting` can migrate was never constructed by a
  shipped build, so no device has those files to migrate.
- **The paired-simulator check is its own script**, `Scripts/paired-sync-sim.sh`,
  not a step in `acceptance-sim.sh`. It needs the two simulators paired, it
  leaves data in both on-device stores, and Watch Connectivity between
  simulators is slower and less predictable than the standalone suites, so
  folding it in would make the CI gate flaky. It takes the same simulator lock,
  and its UI test skips unless `BURLY_PAIRED_SYNC_UI_TESTS=1`. It proves the
  phone half only: a routine built on the real store, its snapshot handed to
  Watch Connectivity, and the phone's digest applied on the watch. Simulator
  never delivers a Watch Connectivity file to the receiving app, so the
  snapshot cannot reach the watch UI between simulators; the full round trip
  needs paired devices, or a simulator-only snapshot carrier that would be a
  §5 design change of its own.

This closes the 2026-10-29 follow-up below (watch unit and rest default) and
the app-wiring half of planning task m4-06. The paired-simulator run is
evidence for §5 acceptance #2, not a substitute for the kill-mid-transfer
review that task still owns.

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
