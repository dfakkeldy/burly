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
  Stats / Settings, with stable `accessibilityIdentifier`s on each tab
  item's Label (`tab.history`, `tab.routines`, `tab.stats`,
  `tab.settings`).
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
- **Tab bar buttons are selected by their spec'd titles in the UI tests**
  (`app.tabBars.buttons["Routines"]`, ...), **not** by the `tab.*`
  identifiers: iOS 26's iPhone `UITabBarButton` ignores
  `accessibilityIdentifier` entirely (a known UIKit bug since iOS 10 — the
  simulator acceptance failed on `tabBars.buttons["tab.routines"]` for
  exactly that reason). The buttons do expose their title as the label,
  and §9 names the four tabs verbatim, so the titles are the contract —
  the same exception as the Import placeholder heading. The `tab.*`
  identifiers stay on the tab item Labels: that is the correct placement
  and they propagate on iPad's Liquid Glass toolbar (see Fix round 1).
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

## 2026-08-02 — Fix round 1: simulator acceptance failure (tab bar button identifiers)

The dispatcher's engine-blind simulator acceptance failed with exactly one
test: `testTabShellAllTabsReachableWithHistoryDefault` at
`BurlyPhoneUITests.swift:46` — `XCTAssertTrue failed - Expected tab bar
button tab.routines`.

**Root cause (verified, not assumed).** The shell tagged each tab's
`.tabItem` `Label` with `accessibilityIdentifier("tab.*")` — the placement
the dispatcher's hint recommends — but iOS 26's iPhone `UITabBarButton`
ignores `accessibilityIdentifier` entirely: a known UIKit bug since iOS 10
(the identifier never reaches the tab bar button; `app.tabBars.buttons`
shows `identifier=''` on every button). The acceptance sim is the "Burly
iPhone" device on the newest installed runtime (iOS 26.5, the only one
installed), so `app.tabBars.buttons["tab.routines"]` could never resolve.
The buttons *do* expose their title as the label.

**Fix (smallest, test-side only).** The UI test now selects each tab bar
button by its spec'd title (`app.tabBars.buttons["Routines"]`,
`"Stats"`, `"Settings"`, and back to `"History"`), which resolves by the
button's label — the same "wording is contractual" exception the test
already uses for the Import placeholder heading, and spec §9 names the
four tabs verbatim ("Four tabs: **History** (default) · **Routines** ·
**Stats** · **Settings**"). The `tab.*` identifiers stay on the tab item
Labels: that is the correct placement per the hint and they propagate on
iPad's Liquid Glass toolbar, so both query dialects remain valid. Content
per tab is still asserted by the views' stable identifiers
(`routinesTab.emptyState.heading`, `statsTab.emptyState.heading`,
`settingsTab.importRow`), unchanged. No app code changed; no other test
changed.

**Verification (run for real):**
1. `cd BurlyKit && swift test`
   → `Test run with 428 tests in 48 suites passed after 1.133 seconds.`
   (BurlyKit untouched; full suite green.)
2. `xcodebuild build-for-testing -scheme BurlyPhone -destination
   'generic/platform=iOS Simulator'`
   → `** TEST BUILD SUCCEEDED **`

HARD LIMITS respected: no simulator booted/created/shut down, no
`xcodebuild test` run, `Scripts/acceptance-sim.sh` not executed — the
dispatcher re-runs the simulator acceptance itself. Not pushed.

Resume:
```
Fix round 1 is done and committed on task/burly-m5-01 in
~/Developer/worktrees/burly-m5-01 (NOT pushed — the dispatcher runs the
simulator acceptance). If the acceptance comes back with another tab-bar
finding, the selector for tab bar buttons on iPhone is the spec'd title,
not an accessibilityIdentifier — the UITabBarButton ignores identifiers
on iPhone; identifiers work only on iPad's Liquid Glass toolbar.
```
