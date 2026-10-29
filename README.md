# Burly

Burly is a free, open-source, watch-first lifting tracker for iPhone and
Apple Watch.

**Status: under active development.** Nothing here is ready for daily
use. There is no App Store listing and no Fastlane pipeline.

## What works today

On iPhone:

- **History**: logged sessions grouped by week, with a session editor
  (sets, warmups, added or removed exercises, notes). Edits keep the linked
  HealthKit workout identifier.
- **Routines**: a routine builder, plus a catalog browser where you can
  create and archive your own exercises.
- **Stats**: exercise progression, weekly volume, muscle split and
  consistency charts, each with its own empty state.
- **Settings**: kg or lb for every phone screen, including the weight you
  type into the set editor; the default rest time; an Apple Health row;
  the version, a source code link and the full licence text.
- **Import from Hevy**: choose a Hevy CSV export and see a preview (new
  workouts, already-imported ones, date range, matched and new exercises,
  and everything that will be dropped) before anything is saved. Importing
  the same file again adds nothing. Imports are never written to Apple
  Health.

On Apple Watch: the routine list and the logging screen, with a guarded
weight edit, the rest timer, finish, discard and resume.

## Not wired up yet

The sync engine and the HealthKit workout controller are built and tested
in `BurlyKit`, but neither app calls them yet. Until they do:

- The phone and the watch don't exchange routines or sessions.
- No workout is saved to Apple Health.
- The watch shows kilograms and uses the 90-second rest default whatever the
  phone's Settings say. Carrying those two choices to the watch needs a
  sync schema change; see `DECISIONS.md`.

## Simulator acceptance

```bash
cd BurlyKit && swift test
Scripts/acceptance-sim.sh
```

`acceptance-sim.sh` needs a simulator pair named `Burly iPhone` and
`Burly Watch S11 46mm` on the newest installed runtimes. CI creates the pair
the same way (see `.github/workflows/ci.yml`).

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
