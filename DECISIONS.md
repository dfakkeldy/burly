<!-- Newest entry first. Dates are local (ADT/AST), matching the commit that adds them. -->

## 2026-11-03 — Release lane archives unsigned; tag push uploads the checked .ipa with altool

#45. Every release run archived with automatic signing on an empty runner,
so cloud signing minted a new "Apple Development: Created via API"
certificate each time. On 2026-11-03 the team hit Apple's cap and the dry
run on `main` failed (dfakkeldy/grok-bots#873).

`Scripts/archive-release.sh` archives BurlyPhone with
`CODE_SIGNING_ALLOWED=NO` and no Apple contact, then signs the watch app
and the phone app ad hoc, inside out, with their entitlements files, and
checks the signatures. An unsigned archive would otherwise lose HealthKit
at export; ad hoc signing through build settings is refused for the iOS
SDK. `release.yml` exports that archive once — dry runs and tag pushes
alike — with the cloud-managed Apple Distribution certificate (which the
cap does not count) and `teamID` in the export options because the archive
carries no team. `Scripts/check-exported-ipa.sh` checks that both apps are
Apple Distribution-signed and kept their declared entitlements. A tag push
then uploads that same checked `.ipa` with `altool --upload-app` via
`Scripts/altool-ipa.sh`. It used to run a second `-exportArchive` with
destination `upload`, which re-signed and uploaded a file nobody had
checked.

`Scripts/altool-ipa.sh` holds the validate step's former inline logic (the
`AuthKey_<id>.p8` copy, ID scrubbing, strict error-text and success-line
matching) for both validate and upload. altool logs each HTTP 5xx it
retries as an `ERROR:` line. A line in that retry-notice shape with no
ITMS code on it is a warning when altool also printed its success line,
and a failure otherwise. Every dry run on 2026-11-03 printed several and
still ended `VERIFY SUCCEEDED`. The upload mode has not run live against
Apple yet; the first tag push is its first live run.

The acceptance gate archives through the same script in place of its
unsigned Release build, so a gated PR proves the archive half. A dry run
of the #45 branch ([run 41638767996](https://github.com/dfakkeldy/burly/actions/runs/41638767996)),
with the team at its certificate cap, archived with no certificate, exported,
and App Store Connect printed `VERIFY SUCCEEDED with no errors`. Nothing
was uploaded.

Two test assumptions, not app bugs, had kept Simulator acceptance red on
`main` since 2026-10-31:

- `testStatsRefreshesOnForegroundAndPreservesRange` asserted "This week: 1"
  then 2, but the seed's newest session is three days old, so on Sunday to
  Tuesday (UTC) the count starts at 0. It now reads the starting count
  (0 or 1) and requires exactly one more after foregrounding.
- `testRestTimerCountsDownAdjustsAndSkips` tapped a countdown that sat
  mostly below the 46 mm watch's bottom edge. The logging page now scrolls
  the rest banner into view when a new rest starts (spec §3: visible after
  logging), and the test asserts the countdown and +15 are fully on screen,
  with no scrolling of its own, before tapping.

`ci.yml` gives each `main` commit its own concurrency group, so `main` runs
neither cancel nor replace each other; branch runs still cancel older ones.

The Codex review of #45 also found that dispatches from any branch and tags
on any commit can reach the API key. That is issue #47; a protected
environment is Dan's call.

## 2026-11-03 — Hevy import: pound-unit columns, and timed or distance sets as one drop

#46. A Hevy export used to abort unless the header named `weight_kg`, so a
file from an account set to pounds was rejected as not a Hevy export. The
importer now requires exactly one weight column, `weight_kg` or
`weight_lbs`. Zero is `unrecognizedHeader`, naming `weight_kg (or
weight_lbs)`. More than one — both units, or one repeated — is
`HevyImportError.ambiguousWeightUnit` and also aborts, rather than reading
the first copy. Pounds convert to kilograms with `Weight.kilogramsPerPound`
at parse time, the same arithmetic as `Weight(pounds:)`. Identity is
unchanged: IDs never include the unit or the weight, so a pounds export and
a kilograms export of the same workouts still dedupe against each other.

Cardio detection reads `distance_miles` as well as `distance_km`. Either
column, if it parses and is above zero, drops the row; there is no distance
conversion. A positive `duration_seconds` drops it too. Those rows stay in
one count: cardio, and also timed or distance strength work (planks, hangs,
carries) that Burly cannot store because a set is weight and reps. The
phone labels the count "Timed or distance sets". The summary field
`cardioRowsSkipped` and the `.drop.cardio` accessibility identifiers keep
their names. The two kinds are not split, because telling them apart would
need guessing from the exercise name.

The `weight_lbs` and `distance_miles` column names come from two
third-party Hevy importers, not Hevy documentation, and still need
confirming against a real export (planning task m7-03).

## 2026-11-03 — Stats opens progression on the latest session's highest-volume exercise; the picker hides archived exercises not trained in that window

#48. Spec §7 #1 names the progression chart's ranges but no default
exercise. Opening on Back Squat showed an empty chart to anyone who
doesn't squat, even when the other Stats cards had data. The card now
opens on the main exercise of the latest session in the last 52 weeks
(the longest §7 window, so the all-exercise stats queries stay
window-bounded): among working sets that name an exercise, the session
with the latest start, then the exercise with the most volume
(Σ weight × reps) in it. Warmups and unnamed sets do not count. Set
times can't settle it, because a Hevy import stamps every set with the
workout's start; volume also passes over bodyweight accessories, whose
chart would be a flat line at 0 kg. Equal volume goes to the exercise
trained first in that session. Back Squat remains the fallback when
nothing was trained in the window.

The picker lists exercises trained in that window first, and leaves out
archived exercises unless they were trained in it. Archiving takes an
exercise out of the pickers you plan with, but its recent history is
still worth charting; an archived exercise last trained more than 52
weeks ago is no longer reachable from Stats. Muscle-tag attribution
still uses the whole catalog. The rule is `ExerciseRecencyStats` in
BurlyCore; the phone reuses the 52-week volume fetch when that range is
already showing. Recorded because m6-03 left the archived listing as an
open product call.

## 2026-11-03 — Watch snapshots carry the full catalog; background tasks wait for the apply

#49. The snapshot now carries every exercise, archived ones included with
their `archivedAt`. The watch already copies `archivedAt` on apply, so an
archive or a naming-queue merge on the phone hides the exercise from the
watch picker. Archiving by absence was rejected: a placeholder the watch
created and the phone has not ingested yet is in no snapshot and must
survive it. The phone cannot delete an exercise, so every exercise the
watch was sent appears in every later snapshot. Archived routines are
still left out.

"Waiting for iPhone" now means no snapshot has been applied, not "no
routines". After the first snapshot the watch shows its routine list even
when it is empty, with Empty session. The newer-schema "Update Burly"
notice is kept in `UserDefaults` (`burly.sync.heldSchemaVersion`) and
shown on the routine list too, because the only code between the sync
host and the list is `ContentView`, which another package owns. Only a
readable snapshot newer than the held one clears it, or the watch app
updating.

A Watch Connectivity background task now completes only after three
gates: WCSession is activated, `hasContentPending` is false, and
`hasUndeliveredContent` is false (content events counted until the sink
has handled them: received and held envelopes, plus activation
completion). WCSession clears `hasContentPending` once the delegate
received the content, not once the app wrote it. `SystemWCSessionTransport`
hops to the main dispatch queue in callback order, so the adapter counts
the content before it sees the cleared flag. That WCSession ordering is
an assumption from the documented background-task pattern; it has not
been observed on hardware. On activation, the adapter re-reads
`WCSession.receivedApplicationContext` and delivers it as a digest
before it reports activation, so a digest lost to suspension is applied
and its acks prune the outbox before the outbox retry runs.

An unrecoverable phone sync journal is reset from `PhoneSyncHost` at the
first foreground (`sceneDidBecomeActive()`), if it is still unrecoverable
then, and never at launch: a read blocked by data protection before first
unlock looks the same at launch. The reset's known cost: if the journal
had already sent snapshots, the watch ignores the restarted snapshot
versions until they pass the last one it applied. The wire protocol still
has no epoch.

## 2026-11-03 — Schema V1 is frozen at TestFlight 0.9.1; V2 adds SessionTombstone

TestFlight 0.9.1 (burly-rc1, 37ea85e) shipped today, so every tester's phone
and watch now holds a store with `BurlySchemaV1`'s exact shape. #52 first
added `SessionTombstone` to V1 in place, under the old "V1 has not shipped"
rule. A 0.9.1 store would then match no version in `BurlyMigrationPlan`,
SwiftData would refuse to open it, and the tester's history would be lost.
So V1 is frozen as main had it, and the tombstone arrives in a V2, following
the procedure in `Schema/CurrentSchema.swift`:

- `Schema/BurlySchemaV2.swift` holds verbatim copies of V1's ten models,
  never references to them; `SessionTombstone` is V2's only addition.
  `MigrationPlanTests.v2CopiesV1Verbatim` compares the two schemas entity by
  entity.
- `BurlyMigrationPlan` is `[V1, V2]` with one `.lightweight` stage: a new,
  empty table and no changed entity, so there is nothing to transform.
  `BurlyContainer` builds V2, and the typealiases point at V2.
- Evidence: `Fixtures/ShippedV1/` holds a phone and a watch store written by
  the burly-rc1 BurlyKit sources (routines, sessions of each origin with
  sets, a naming placeholder; on the watch an unacked session, an in-flight
  one with its journal, a digest and the watch-sync journal).
  `ShippedStoreMigrationTests` opens them through the production container,
  checks the data, then deletes with a tombstone and cold-reopens.
- CI's two-process split stays. The migration spike moves to a test-only
  V3 on top of the real V2, still in its own process: its `SetRecord` has a
  column the shipping one lacks, the shape mismatch behind the macOS 26
  SwiftData failures that forced the split. Real V1 and V2 share entity
  names but no shared entity differs in shape, and opening a 0.9.1 store
  realises both exactly as a device will, so `ShippedStoreMigrationTests`
  runs in the ordinary pass. First hosted evidence: CI run 41681740096
  (Xcode 26.6, macos-26) passed both processes, 927 tests in the ordinary
  pass and the spike alone; #52 lists the reruns.

V2 is frozen in turn once 1.0 ships; the next change is a V3.

## 2026-10-31 — The store text describes Apple Health again; acceptance compiles Release

#13 put HealthKit on the watch, and #39, merged just before it, had
rewritten PRIVACY.md and the review notes to say Burly never touches Health,
and dropped the Health line from the description. The App Store privacy URL points at `main`, so the live policy
was wrong. The Health text Dan approved in #33 is back in all three, and the
README says what the watch saves. Text that says whether Burly uses Health
should follow the code on `main` (`HealthKitWorkoutAdapters` and
`SessionWorkoutRecorder`), not the order PRs merge in.

Settings now links to the privacy policy, because Guideline 5.1.1(i) wants it
reachable in the app as well as in App Store Connect. Both apps set
`CFBundleDisplayName` to "Burly"; without it the Home Screen showed the target
names.

`Scripts/acceptance-sim.sh` now also compiles BurlyPhone, with the embedded
watch app, in Release for a generic iOS device, unsigned. Nothing had compiled
Release since the burly-m0 upload, and three phone previews used a Debug-only
view model. `#Preview` bodies compile in every configuration, so the v1.0.0
archive would have failed at the tag. The build is unsigned, so it proves the
compile only: signing and the HealthKit capability on the App IDs are proven
by a tagged release run. (Superseded by 2026-11-03.)

## 2026-10-30 — App Store listing as code with fastlane deliver; uploads stay on xcodebuild

Burly's builds already reach App Store Connect without fastlane: a release tag
archives and uploads with `xcodebuild -exportArchive` (release.yml), and that
stays. (Superseded by 2026-11-03.) What had no home was the store page itself: listing text, screenshots,
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
adapter's `hasContentPending` completion rule. (Superseded by 2026-11-03.)
UI-test scenario launches get their seeded store and no sync, so the
standalone UI suites never touch WCSession.

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
