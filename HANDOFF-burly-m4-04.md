# HANDOFF — burly-m4-04 (Phone-side apply, digest generation, push triggers)

## 2026-08-02 — implementation complete, full package green

Done:
- Added `BurlyStore.applyReplicatedSession(_:)` (conditional replicated
  session upsert, revision recheck in-transaction, verbatim revision
  carry-forward — the m1-06 "round A" local-authoring/replicated-apply
  split extended from routines to sessions) and
  `BurlyStore.allLoggedSetSlices()` (bounded, one-shot, all-exercise
  fetch for the digest generator) in `BurlyPersistence`, both implemented
  in `SwiftDataStore` and covered by
  `Tests/BurlyPersistenceTests/ReplicatedSessionApplyTests.swift` (8
  tests) and `AllLoggedSetSlicesTests.swift` (3 tests).
- New SPM target `BurlyPhoneSync` (sits above BurlyPersistence + BurlySync
  — cannot live inside either without a circular dependency):
  - `PhoneSyncCoordinator` (`@MainActor final class`) — the binding
    contract's session-ingest executor + all five push-trigger entry
    points (`sessionReceived`, `applicationDidLaunch`,
    `watchAppInstalledDidChange`, `dailyPushIfDue`, `catalogDidChange`,
    `historyDidChange`, `snapshotTransferFinished`).
  - `SessionDigestGenerator` — the §5 digest derivation, property-tested.
  - `QuietPeriodCoalescer<Payload>` — the reusable trailing-edge debounce
    backing both the 5 s catalog-edit window and digest-publish
    coalescing (binding contract item 6).
  - `TriggerScheduling` / `SystemTriggerScheduler` — injected
    sleep abstraction (no `Timer`/`Date()` in logic).
  - `PhoneSyncStatePersisting` / `FileBackedPhoneSyncStatePersisting` /
    `InMemoryPhoneSyncStatePersisting` — durable JSON persistence for
    `PhoneSyncMachine.State` + the daily-push bookkeeping, deliberately
    NOT a new SwiftData `@Model` (house rule: no schema changes).
  - `PhoneSyncTransporting` / `PhoneDigestPublishing` — the seam to
    m4-03's (not-yet-landed) WCSession adapter; this task's tests use
    in-memory fakes (`FakeTransport`, `FakeDigestPublisher`).
  - `SnapshotPayloadBuilder` — builds `BurlySnapshotPayloadDTO` from store
    truth for `.transmitSnapshot`.
- 29 new tests in `BurlyPhoneSyncTests`: digest generator (property test +
  4 unit tests), session ingest (8, one per binding-contract item),
  push triggers (11), state persistence (5).
- Full package green: `swift test` — 659 tests, 70 suites, all pass.
  `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` —
  2/2 pass. `swift build -c release` also clean.
- Nothing committed yet — see "Next" below.

Key design decision worth flagging for review: `PhoneSyncCoordinator` is
`@MainActor`, not a standalone custom `actor`. `BurlyStore`'s own doc says
store confinement is "the app's `@MainActor` in practice", and the binding
contract's item 1 wants "the same executor as every other store mutation
(§6 edits, deletes, imports)" — a standalone actor would give sync its own
isolation domain over a store object the rest of the app is expected to
touch from `@MainActor`, which is exactly the race the store's threading
doc warns about. This assumes BurlyPhone's own store access (§6 edits, §9
catalog edits) is also `@MainActor` — true by SwiftUI/SwiftData default,
but not verified against actual BurlyPhone code in this task (out of scope
per the "pure package work" house rule). Flagged for m4-03/app-integration
to confirm or reconcile explicitly.

Also flagged: `SyncMachineBinding.swift`'s own file comment (line ~70)
attributes the "BINDING CONTRACT — phone session ingest" to "(m4-05
implements and tests)", and `plan/tasks/burly-m4-05.md`'s "Carried from
m4-02" section pastes the same 6-item contract text this task's brief
does. Interpreted this as a stale comment / shared-context copy-paste
predating the final m4-04/m4-05 split (m4-05's own task title is
"Watch-side apply, pruning, placeholder embedding" — a different, watch-
side scope) — proceeded per this task's explicit, detailed brief, which
unambiguously assigns the phone-side executor to m4-04. Did not touch
`SyncMachineBinding.swift`'s comment text itself (read-only reference
doc, not code I own).

Next:
- Nothing blocking. Commit this worktree's changes to `task/burly-m4-04`
  (do not push, per task instructions) and hand off for dispatcher
  re-run / review.
- Real wiring of `PhoneSyncCoordinator` into BurlyPhone's app lifecycle
  (scenePhase, WCSession activation, §6 edit call sites invoking
  `catalogDidChange()`/`historyDidChange()`) is explicit app-integration
  work this task did not do (out of scope: BurlyKit package only, "no
  xcodebuild/simulators" house rule) — likely m4-06's paired-sim
  integration task, or a follow-up.
- `PhoneSyncTransporting`/`PhoneDigestPublishing` conformers backed by
  m4-03's real WCSession adapter do not exist yet (m4-03 not landed at
  time of writing) — this task's tests use in-memory fakes; m4-06 is
  where the real adapter gets wired against this coordinator.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-04
Branch: task/burly-m4-04 (based on main 5ab56d1)
Status: implementation + tests complete, all green, NOT yet committed.
Next action: git add -A && git commit (do not push), matching the
commit message style of prior burly-m4-* merges in this repo's log.
```
