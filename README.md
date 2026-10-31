# Burly

Burly is a free, open-source, watch-first lifting tracker for iPhone and
Apple Watch.

**Status: under active development.** Nothing here is ready for daily
use. There is no App Store listing yet; its text and the lane that uploads it
live in `fastlane/` (see DECISIONS.md).

## What works today

On iPhone:

- **History**: logged sessions grouped by week, with a session editor
  (sets, warmups, added or removed exercises, notes). Edits keep the linked
  HealthKit workout identifier. History refreshes when a session arrives
  from the watch.
- **Routines**: a routine builder, plus a catalog browser where you can
  create and archive your own exercises. The bundled curated catalog is
  applied when the on-device store opens.
- **Stats**: exercise progression, weekly volume, muscle split and
  consistency charts, each with its own empty state.
- **Settings**: kg or lb for every phone screen, including the weight you
  type into the set editor; an editable rest-default stepper (15-second
  steps from 15 seconds to 5 minutes); an Apple Health row that says what
  the watch saves, with a button that opens the Health app; the version, a
  source code link, the privacy policy and the full licence text. If the
  watch sent a newer sync schema than this iPhone can read, Settings shows
  an update-needed row.
- **Import from Hevy**: choose a Hevy CSV export and see a preview (new
  workouts, already-imported ones, date range, matched and new exercises,
  and everything that will be dropped) before anything is saved. Importing
  the same file again adds nothing. Imports are never written to Apple
  Health.

On Apple Watch: the routine list and the logging screen, with a guarded
weight edit, the rest timer, finish, discard and resume. Weights, volume
and the crown step follow the phone's display unit. Rest uses the
exercise's own rest time if it has one, otherwise the phone's rest
default. The watch asks for Health access the first time a workout
starts; with access, each finished workout is saved to Apple Health,
normally with heart rate and active energy (a session resumed after the
app relaunched may be saved without sensor data). If access is declined,
sets still save in Burly.

The phone and the watch exchange routines, exercises and finished sessions
over WatchConnectivity (`PhoneSyncHost` / `WatchSyncHost`). Snapshot schema
2 carries the phone's display unit and rest default. Before the first
snapshot the watch shows kilograms and 90 seconds.

## Not wired up yet

The iPhone app does not read or write Apple Health itself; only the watch
does. Deleting a workout from Health when its session is deleted is built
in `BurlyKit` but not wired, because the phone has no session-delete action
yet (see DECISIONS.md).

## Simulator acceptance

```bash
cd BurlyKit && swift test
Scripts/acceptance-sim.sh
```

`acceptance-sim.sh` needs a simulator pair named `Burly iPhone` and
`Burly Watch S11 46mm` on the newest installed runtimes. CI creates the pair
the same way (see `.github/workflows/ci.yml`). That script is the CI
simulator acceptance gate.

`Scripts/paired-sync-sim.sh` is a separate local check on the same pair. It
is not part of the CI gate. It proves the phone half of sync: a routine
built on the real store, its snapshot handed to WatchConnectivity, and the
phone's digest applied on the watch. Simulator never delivers a
WatchConnectivity file to the receiving app, so the snapshot cannot reach
the watch UI between simulators.

The `Simulator acceptance` job runs on pushes to `main` and on pull requests
labelled `sim-acceptance`. Without that label a green PR check is not
simulator acceptance, and CI runs Xcode 26 runtimes, which can behave
differently from a local Xcode 27 run. From August to October 2026 `main` failed
in `testHistoryEditsAdvanceRevisionAndPreserveHealthKitLink` ("Expected edit
to persist exactly revision 5"). The cause was in the test, not the app: the
revision row sits at the top of a lazy list, and the test looked for it after
scrolling to the bottom.

## License

Burly is licensed under the [GNU General Public License v3.0 or later](LICENSE),
with an [App Store distribution exception](LICENSE-APP-STORE-EXCEPTION.md) that
permits distribution through Apple's App Store while keeping the complete
source available to everyone under the GPL.
