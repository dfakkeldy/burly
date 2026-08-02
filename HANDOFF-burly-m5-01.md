# HANDOFF — burly-m5-01 (iPhone app shell)

Task: implement the Burly iPhone app shell (m5-01) on branch `task/burly-m5-01`
(cut from `main` @ 51bede0). Worktree: `~/Developer/worktrees/burly-m5-01`.
NOT pushed — the dispatcher runs the simulator acceptance itself.

## What shipped

The entire phone app surface for this task:

- **One-time welcome** (`WelcomeView.swift`, `WelcomeState.swift`): a single
  screen offering **Import from Hevy** and **Start fresh**. Import pushes the
  clearly-labeled placeholder (`ImportPlaceholderView.swift`); Start fresh
  lands in the tab shell. The choice persists in UserDefaults
  (`com.burly.lifting.welcomeCompleted`) — relaunches skip the welcome.
  Debug launches (UI tests) can override either side with the launch
  arguments `-burly-force-welcome` / `-burly-skip-welcome`, the same
  DEBUG-only out-of-process seam as the watch's `WatchDemoSeed`.
- **Four-tab shell** (`MainTabView.swift`): History (default) / Routines /
  Stats / Settings, with stable `accessibilityIdentifier`s on each tab bar
  button (`tab.history`, `tab.routines`, `tab.stats`, `tab.settings`).
- **Real, store-backed empty states** — not hardcoded "always empty":
  - `PhoneHomeViewModel.swift` loads once per launch from the phone store
    (`SwiftDataStore.phone()`, resolved once in `ContentView.init` per the
    m2-01 finding 3.1 pattern): `routines(includingArchived: false)` and
    `sessions(state: .logged)` — the store's own §6/§9 history-surface reads.
  - `HistoryTabView` / `RoutinesTabView` / `StatsTabView` render a shared
    `EmptyStateView` (honest copy per tab) when the store answers empty, and
    a minimal honest list/summary when it doesn't (History = session rows,
    Routines = name rows, Stats = "Workouts logged" count + "charts later"
    note — no charts, per spec). Load failures render the same layout with a
    Retry; a store that fails to open at all shows `StoreUnavailableView`.
  - `SettingsView` = static placeholder rows only (Import from Hevy row,
    Version row), as the spec allows.
- **UI tests** (added to the existing `BurlyPhoneUITests` target, no new
  targets, no target surgery): the obsolete placeholder smoke test
  (`testAppLaunchesToPlaceholderUI`, which asserted the deleted placeholder
  UI) is replaced by four identifier-based tests:
  `testTabShellAllTabsReachableWithHistoryDefault` (default tab = History,
  all four tabs reachable), `testFirstLaunchStartFreshLandsInTabs`,
  `testFirstLaunchImportShowsPlaceholder`, and
  `testWelcomeSkippedOnRelaunch` (real UserDefaults persistence, terminate +
  relaunch with no overrides). All selection is by stable identifiers
  (m2-01 review finding 6.2); the only copy assertion is the Import
  placeholder heading, where "clearly labeled" is the spec contract.

## Files

```
BurlyPhone/ContentView.swift            (rewritten: store resolution + welcome gate)
BurlyPhone/WelcomeState.swift           (new: persistence + DEBUG launch-arg seam)
BurlyPhone/WelcomeView.swift            (new)
BurlyPhone/ImportPlaceholderView.swift  (new)
BurlyPhone/MainTabView.swift            (new)
BurlyPhone/PhoneHomeViewModel.swift     (new)
BurlyPhone/HistoryTabView.swift         (new)
BurlyPhone/RoutinesTabView.swift        (new)
BurlyPhone/StatsTabView.swift           (new)
BurlyPhone/SettingsView.swift           (new)
BurlyPhone/EmptyStateView.swift         (new)
BurlyPhone/StoreUnavailableView.swift   (new)
BurlyPhoneUITests/BurlyPhoneUITests.swift  (rewritten: 4 tests)
Burly.xcodeproj/project.pbxproj         (11 files added to BurlyPhone target only)
HANDOFF-burly-m5-01.md                  (this file)
```

All new files carry the exact `// SPDX-License-Identifier: GPL-3.0-or-later`
header used across the repo; naming/comment density mirrors BurlyWatch (the
m2-01 shell). No unit tests were added: the app has no unit-test target and
creating one would be pbxproj target surgery, which the task forbids
("Swift Testing" would apply to any future unit tests).

## Verification (run for real, one xcodebuild at a time)

1. `cd BurlyKit && swift test`
   → `Test run with 428 tests in 48 suites passed after 1.081 seconds.`
   (BurlyKit untouched; full suite green.)
2. `xcodebuild build -scheme BurlyPhone -destination 'generic/platform=iOS Simulator'`
   → `** BUILD SUCCEEDED **`
3. `xcodebuild build-for-testing -scheme BurlyPhone -destination 'generic/platform=iOS Simulator'`
   → `** TEST BUILD SUCCEEDED **`

HARD LIMITS respected: no simulator was booted/created/shut down, no
`xcodebuild test` was run, `Scripts/acceptance-sim.sh` was not executed —
the dispatcher runs the simulator acceptance (which boots the named sim pair,
runs BurlyPhoneUITests, and exports the .xcresult).

## Interpretations / notes for review

- **Both welcome buttons complete the one-time choice.** The spec says
  "relaunches skip welcome" without qualification, so tapping Import from
  Hevy (not just Start fresh) marks the welcome complete and persists it;
  within the same session the Import path stays inside the welcome's
  NavigationStack so Back behaves normally, and the shell only switches to
  the tabs on Start fresh.
- **History/Stats show `.logged` sessions only** (via `sessions(state:)`),
  matching the store's own doc ("an `.active` workout is not history yet").
- **Non-empty rendering is minimal on purpose**: the task's scope is the
  shell + real empty states, so History/Routines show simple rows and Stats
  shows a count line — enough to prove the empty state is store-driven, no
  charts/editor/catalog per spec.
- **Tab bar buttons are selected by `accessibilityIdentifier`** set on the
  `.tabItem` Label (SwiftUI propagates it to the UITabBarButton); each tab's
  content is additionally asserted by its own empty-state/row identifier, so
  the smoke test verifies actual content per tab, not just a button tap.
- The old placeholder smoke test was **replaced** (not kept): it asserted the
  deleted placeholder UI and would fail against the new shell.
- One deviation encountered while building: a `try!` store call inside a
  multi-statement `#Preview` result-builder closure tripped a compiler
  diagnostic bug ("failed to produce diagnostic for expression"), so previews
  use a DEBUG-only `PhoneHomeViewModel.previewLoaded` helper instead.

## Repo state

`git status --short --branch` on the worktree is clean at the commit below.
The canonical checkout (`~/Developer/burly`) was untouched; its pre-existing
untracked `.superpowers/` directory was left alone. Other agents' worktrees
(`burly-m6-01`, `burly-m7-01`) were not disturbed.
