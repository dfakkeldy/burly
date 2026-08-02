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

## 2026-08-02 — review round 1 fix pass (2 blockers + 10 majors), all accepted findings closed

Coordinator relayed a NOT-SAFE verdict on `f224412` (full report:
`.scratch/m4-04-review-1.md`, all 12 findings accepted). Fixed all 12 on
top of `f224412` in this same worktree, each pinned by a test that fails
on pre-fix behavior.

Done, blocker/major → fix → pin:
- **Blocker 1** (sidecar fail-open reset) — `PhoneSyncStatePersisting.swift`
  rewritten: a new append-only `HighWaterMarkLog` sidecar is written
  BEFORE every primary-state write; `load()` now returns
  `PhoneSyncLoadResult?` and reconstructs monotonic identities from the
  log's max whenever the primary is missing/unreadable/semantically
  invalid, never resetting to zero. Semantically-corrupt fields (negative
  versions/ages) now throw `PhoneSyncStateCorruptionError` from
  `Snapshot.makeRuntimeState()` (a throwing path) instead of trapping a
  precondition. Pins: 6 new tests in `PhoneSyncStatePersistingTests.swift`
  (garbage primary / deleted primary / semantically-corrupt primary all
  restore from the log; `makeRuntimeStateThrowsForEveryInvalidField`;
  high-water log tolerates partial corruption; identity never regresses
  across a simulated corruption+relaunch).
- **Blocker 2** (single-executor enforcement) — `BurlyStore` protocol and
  `SwiftDataStore` are now `@MainActor`-annotated (compiler-enforced, not
  just documented). Mechanical ripple below.
- **Major 1** (atomic placeholder+session apply) — `BurlyStore` gained
  `applyReplicatedSession(_:upsertingPlaceholderExercises:)`; the
  `SwiftDataStore` implementation wraps placeholder inserts + graph
  reconciliation in one `do { ...; try commit() } catch { rollback(); throw }`
  block. This caught a REAL bug: a preflight throw after placeholder
  insert left the placeholder pending-but-unrolled-back in the long-lived
  context (commit()'s rollback was never reached). Pins: 3 new tests in
  `ReplicatedSessionApplyTests.swift` + rewrote
  `missingExerciseReferenceFailsClosedWithNoAckOrPublish` in
  `PhoneSessionIngestTests.swift` to assert the placeholder does NOT
  survive a rejected delivery (it did, pre-fix).
- **Major 2** — covered by blocker 2's annotation; documented in
  `SwiftDataStore`'s doc why the in-method re-read is now provably
  serialized (single executor, no interleaving possible between read and
  write within one method body).
- **Major 3** (trigger state consumed only after enqueue) —
  `PhoneSyncCoordinator`: `dailyPushIfDue` now persists `lastDailyPushAt`
  only after `runEvent` returns successfully; `watchAppInstalledDidChange`
  gained `pendingInstallPushRetry` so a failed install-flip push retries
  on the next call instead of requiring an uninstall/reinstall cycle;
  catalog-push failures are surfaced on `lastCatalogPushFailure` and
  retried automatically via `executeCatalogCommands(_:retriesRemaining:)`.
  Pins: 3 new tests in `PushTriggerTests.swift`.
- **Major 4** (serialize snapshot batches) — `execute`/`executeUnlocked`
  now acquire an explicit execution lock
  (`acquireExecutionLock`/`releaseExecutionLock`) around a whole command
  batch, so a second push's transport calls cannot start until the first
  batch fully finishes. Pin: `FakeTransport` gained a cancel-gate
  (`armCancelGate`/`releaseCancelGate`) to construct the A/B interleaving
  deterministically; new test in `PushTriggerTests.swift`.
- **Major 5** (digest coalescing carries only a signal) — `publishDigest`
  commands now coalesce a bare `Void` signal; `publishDigestNow()` reads
  `state.latestSnapshotVersion` / `Set(state.ackAge.keys)` at fire time,
  not at schedule time. Pin: new test asserting a digest published after a
  burst reflects state mutated DURING the quiet period, not state
  captured when the burst started.
- **Major 6** (coalescer: single task, no overlap) — `QuietPeriodCoalescer`
  rewritten from a generation-counter+task-array design to a single
  `currentTask`/`isPerforming`/`rerunRequested` state machine: exactly one
  pending countdown at a time, cancellation actually frees a superseded
  countdown (not just outnumbers it), and `perform` invocations never
  overlap — a rerun request during an in-flight `perform` is queued and
  fires only after that `perform` returns. `ManualTriggerScheduler`
  rewritten to a plain lock-protected class (was an `actor`, which could
  not be driven synchronously from test bodies) with a
  `withTaskCancellationHandler` that closes a stuck-waiter race window.
  Pins: new file `QuietPeriodCoalescerTests.swift` (4 tests, direct against
  the coalescer, not through the coordinator) exercising burst-collapse,
  cancellation actually freeing the slot, no-overlap under a
  coalesce-during-perform, and `drain()` awaiting a full rerun chain.
- **Major 7** (revision validation) — `SessionData.maximumRevision`
  (1_000_000_000) + `hasValidRevision`; `init(from:)` throws
  `DecodingError.dataCorruptedError` for an out-of-range wire revision
  (decode-time refusal, not an apply-time trap); `SwiftDataStore` gained
  `validateIncomingRevision` (thrown `BurlyStoreError.invalidRevision`,
  not a precondition) called from `createSession` /
  `applyReplicatedSession`; `applyPhoneEdit` refuses to increment past
  `maximumRevision` with the same thrown error instead of overflowing.
  Pins: 4 new tests spanning decode-time, create, replicated-apply, and
  phone-edit-overflow (an `Int.max` payload is refused end-to-end; a
  normal phone edit still works).
- **Major 8** (stale .active reorder guard order) — the existing-row
  revision no-op check in `applyReplicatedSession` now runs BEFORE the
  `.active`-state guard, so a stale `.active` replica at `revision <=
  stored.revision` is a silent no-op-with-ack rather than a thrown
  `activeSessionRequiresSaveActiveSession`. Pin:
  `staleActiveReplicaIsASilentNoOp`.
- **Major 9** (oracle independence + order-based set sort) —
  `SessionDigestGenerator`'s `latestPerformancePerExercise` now sorts a
  winning session's sets by `order` first (matching §2's "for this set
  index"), then `completedAt`, then `id` — not `completedAt` first, which
  is what production did before this fix. The property test's independent
  oracle no longer shares ANY comparator with production: it takes each
  fixture item's `sets` array verbatim (already order-ascending by
  construction) instead of re-sorting by `completedAt`; the random
  fixture's `completedAt` generation is now independent of `order`/
  `setIndex` so the two fields actually disagree on direction in roughly
  half of random trials, closing the gap that let the original bug slip
  through 40 seeds undetected. Pins: 2 new fixed, non-randomized tests —
  `setsOrderedByOrderFieldEvenWithReversedCompletedAt` and
  `identicalOrderAndCompletedAtBreakTieBySetID` (fixed low/high UUIDs
  resolve a same-order-same-completedAt tie, the "same exercise logged via
  two items" shape).
- **Major 10** (benchmark) — new gated file
  `DigestGenerationBenchmarkTests.swift`
  (`BURLY_RUN_DIGEST_BENCHMARK=1 swift test --filter
  DigestGenerationBenchmarkTests`), mirroring
  `StatsQueryBenchmarkTests`'s seeding/measurement pattern exactly.
  Result at ~50k SetRecords (50,351 across 12 exercises, 3,600 sessions):
  **2.64s wall, 193.1 MB process high-water RSS** — under the review's
  named thresholds (~3s / ~250MB) but at ~88%/~77% of them, not a
  comfortable margin. No regression fired, so nothing is ticketed, but
  this is closer to the ceiling than "clearly fine" — worth a note for
  whoever next touches `allLoggedSetSlices`/digest generation, and a
  natural candidate for m8-02's device-floor pass to re-measure on-device
  rather than assume the Mac number holds.

`@MainActor` ripple (blocker 2), mechanical as the review predicted:
- Production: `BurlyStore` protocol, `SwiftDataStore`,
  `SwiftDataStore+SessionDigest.swift` (isolated-conformance syntax:
  `extension SwiftDataStore: @MainActor SessionDigestApplying`),
  `SeedLoader.apply(_:to:)`/`applyBundled(to:)`,
  `SnapshotPayloadBuilder.build(version:from:)`,
  `PhoneSyncCoordinator` (already `@MainActor`, doc extended to explain
  why the annotation now makes the compare-and-save race class provably
  impossible rather than merely documented-away).
- Tests: `@MainActor` added (mechanically, via a scoped `sed` pass +
  manual fixups) to 19 files in `BurlyPersistenceTests` plus
  `StatsQueryBenchmarkTests.swift`, `MigrationSpikeTests.swift`, and
  `StoreTestSupport.swift`'s `makeStore`; `TestSupport.swift`'s
  `makePhoneStore` in `BurlyPhoneSyncTests`. No suite needed structural
  restructuring beyond the annotation itself — the whole 684-test package
  built and passed cleanly on the first full run after the annotation
  landed, confirming the review's own "mechanical churn" prediction.
  `ManualTriggerScheduler` needed a real rewrite (actor → lock-protected
  class) but that was major 6's fix, not the `@MainActor` ripple itself —
  its `actor`-ness was incompatible with tests needing to drive it
  synchronously, unrelated to store confinement.

Verification (this fix round):
- `swift test` (full suite): **684 tests, 72 suites, all pass** (up from
  659/70 at `f224412` — net +25 tests: 4 new digest-generator pins + 4
  new QuietPeriodCoalescer tests + 6 new state-persisting tests + 3 new
  ReplicatedSessionApply tests + 3 new PushTrigger tests + others folded
  into existing suites, minus the 1 benchmark file that's gated off by
  default).
- `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` —
  2/2 pass.
- `BURLY_RUN_DIGEST_BENCHMARK=1 swift test --filter
  DigestGenerationBenchmarkTests` — 1/1 pass, numbers above.
- `swift build -c release` — clean.
- Flakiness check: `QuietPeriodCoalescerTests`, `PushTriggerTests`,
  `ReplicatedSessionApplyTests`, `SessionDigestGeneratorTests`,
  `PhoneSyncStatePersistingTests`, `PhoneSessionIngestTests` run 3x back
  to back (61 tests, 6 suites) — consistently green, no observed flake.

Disagreements / flags (not silently resolved, not in the numbered list):
- The pre-existing "isWatchAppInstalled flip direction" interpretation
  (edge-triggered strictly on false→true, `watchAppInstalledDidChange`'s
  own doc at line ~248) was left unchanged — it was not one of the 2
  blockers or 10 majors, and changing trigger semantics beyond what was
  asked risks exactly the kind of scope creep the house rules warn
  against ("keep the diff mechanical"). Flagging rather than silently
  leaving it unaddressed, per the report format's request for explicit
  disagreements.
- Major 10's benchmark came in under threshold but close to it (88%/77%
  of the named ceilings on this Mac) — treated as "no ticket needed" per
  the review's own criterion ("if generation exceeds ~3s or ~250MB...
  ticketed to m8-02"), but flagged above rather than silently filed as a
  clean pass, since a slower device (the iPhone 12 Pro floor this
  program's acceptance bar names) could plausibly cross it.

Commit: not yet made as of this entry — see the commit immediately
following this HANDOFF update in the branch's log for the SHA.

Next:
- Nothing blocking. Hand off for dispatcher re-review of this fix round.
- Same two follow-ups as before remain out of scope for this task: real
  `PhoneSyncCoordinator` wiring into BurlyPhone's app lifecycle, and the
  real WCSession-backed `PhoneSyncTransporting`/`PhoneDigestPublishing`
  conformers (both still m4-03/m4-06 work).

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-04
Branch: task/burly-m4-04 (based on main 5ab56d1, review-fix round on f224412)
Status: all 12 review findings fixed + pinned, 684 tests green, release
build clean. Committed on top of f224412 (not pushed).
Next action: hand off for dispatcher re-review; no local work pending.
```

## 2026-08-02 — review round 2 fix pass (1 blocker edge + 5 majors), closing round

Re-review of `e5b908e` confirmed the `@MainActor`, revision, fire-time
digest, batch-lock, and independent-oracle fixes closed, but found 6 new
items — mostly edge cases the round-1 async rewrites introduced. Fixed
all 6 on top of `e5b908e` in this same worktree, each pinned by a test
verified to fail on the pre-fix behavior (confirmed by temporarily
reverting each fix and re-running its pin — see "verification method"
note at the end of this entry).

Per-finding fix + pin:

- **Blocker edge — dual-unreadable reset.**
  `BurlyKit/Sources/BurlyPhoneSync/PhoneSyncStatePersisting.swift`:
  `HighWaterMarkLog.currentHighWater()`'s tuple return (which conflated
  "log never written" with "log exists but every line is corrupt" into
  the same `(0, 0)`) is replaced by `read() -> HighWaterReadOutcome`
  (`.absent` / `.corrupt` / `.value`). `load()` now distinguishes: both
  files genuinely absent → `nil` (a true first launch); either file
  *present* but unreadable/corrupt with nothing usable from the other →
  throws a new `PhoneSyncStateUnrecoverableError` rather than silently
  reconstructing a zeroed state. `PhoneSyncCoordinator` catches this
  distinctly and sets a new `public private(set) var
  syncStateUnrecoverable: Bool` (alongside the existing
  `recoveredFromCorruptState`), documented as needing a host-app
  re-pair/rebuild response, not an automatic mitigation. Pins: 4 new
  tests in `PhoneSyncStatePersistingTests.swift`
  (`bothFilesAbsentIsACleanFirstLaunch`,
  `primaryAndHighWaterBothUnreadableIsUnrecoverable`,
  `highWaterCorruptWithNoPrimaryIsUnrecoverable`,
  `coordinatorSurfacesSyncStateUnrecoverable`). Verified the two
  "unrecoverable" tests fail (no error thrown) against the old
  tuple-based `load()`; the "both absent" test correctly still passes
  either way (proving it isn't a false-positive pin).
- **Major — Int.max high-water record traps downstream.** Added
  `maximumPhoneSyncIdentity = 1_000_000_000` (the same
  `SessionData.maximumRevision`-style ceiling, round 1, major 7) and
  applied it as an upper bound at BOTH JSON deserialization boundaries
  this file owns: `HighWaterMarkLog.read()`'s per-line validation (a
  line with `version`/`generation` above the bound is now skipped as
  corrupt, matching the existing negative-value skip) and
  `Snapshot.makeRuntimeState()` (new `.snapshotVersionTooLarge`/
  `.transferGenerationTooLarge` thrown cases) — the review named the
  high-water-log path specifically, but the identical hole existed in
  the primary-state path too (a corrupted primary carrying `Int.max`
  would sail through the round-1 `>= 0` check just the same), so both
  were closed together rather than leaving a twin gap. Pins:
  `highWaterLineWithIntMaxIsSkippedNotRestored` (new) plus two new
  assertions added to the existing
  `makeRuntimeStateThrowsForEveryInvalidField`. Verified the high-water
  test fails (reconstructs at `Int.max`) with the upper-bound check
  removed.
- **Major — throw during the 2nd placeholder existence fetch escapes
  rollback.** `BurlyKit/Sources/BurlyPersistence/Store/SwiftDataStore.swift`:
  the placeholder existence-check-and-insert loop in
  `applyReplicatedSession(_:upsertingPlaceholderExercises:)` was still
  OUTSIDE the round-1 rollback-on-throw block — only
  `preflightSessionGraph` and after were covered. Moved the whole loop
  inside the `do`/`catch { context.rollback(); throw error }` block, so
  any throw from the loop's own fetch (not just a dangling-reference
  preflight failure) now rolls back every placeholder inserted earlier
  in the same call. Added a test-only seam,
  `placeholderExistenceCheckFaultForTesting: ((Int, UUID) throws ->
  Void)?`, since a real `context.fetch` I/O failure cannot be
  deterministically timed to one specific loop iteration. Pin:
  `faultDuringSecondPlaceholderExistenceCheckRollsBackTheFirst` in
  `ReplicatedSessionApplyTests.swift` — injects a fault on the 2nd
  placeholder, confirms the 1st placeholder's insert does not survive
  (neither via the context's own pending-insert view nor after an
  unrelated successful save). Verified it fails (placeholder A survives)
  against the pre-fix loop placement.
- **Major — catalog state-persistence failure silently swallowed.**
  `BurlyKit/Sources/BurlyPhoneSync/PhoneSyncCoordinator.swift`:
  `deliverCatalogChanged` used to route through the generic `deliver(_:)`
  helper, whose `try?` swallowed a `persistRuntimeState()` failure
  outright — no surfaced failure, no retry, unlike every other trigger's
  failure class (major 3). Inlined the machine call and persistence step
  into `deliverCatalogChanged`/`persistThenExecuteCatalogCommands`, so a
  persistence failure now sets `lastCatalogPushFailure` and retries
  through the same `catalogPushRetryCount` loop a transport failure
  already used. Pin: `catalogPersistenceFailureIsSurfacedAndRetried` in
  `PushTriggerTests.swift`, using a new `FailableStatePersisting` test
  double (`TestSupport.swift`) that fails its next N `save()` calls.
  Verified: with the old `try? deliver(...)` shape restored, the test
  hangs forever waiting for a retry waiter that pre-fix code never
  schedules — itself conclusive proof of the swallow.
- **Major — stale catalog retry runs after a newer successful batch.**
  Same file: added `catalogBatchEpoch`, incremented once per
  `deliverCatalogChanged` invocation. Every entry into
  `persistThenExecuteCatalogCommands`/`executeCatalogCommands` — the
  first attempt AND every scheduled retry — re-checks its captured epoch
  against the current counter first and backs off with no side effects
  on a mismatch, so a retry from an older edit can never replay stale
  commands (resurrecting a transfer a newer edit's own cancel already
  retired) once a newer edit's batch has run. Pin:
  `staleCatalogRetryDoesNotResurrectASupersededTransfer` in
  `PushTriggerTests.swift` — edit A fails and queues a retry; edit B's
  own debounce computes the IDENTICAL deadline (both `catalogEditDebounce`
  after the same instant — an exact tie a real OS scheduler has no
  obligation to resolve one particular way), so a new
  `ManualTriggerScheduler.resumeWaiter(id:)` helper forces B to resolve
  on its own regardless of the tie; B succeeds (cancel(1)/transmit(2,2)),
  then A's retry is released and must be a complete no-op. Verified it
  fails (transmissions become `[2, 1]` — the resurrection) with the
  epoch guards removed, across 5 repeated runs. Note: this exact test
  needed a `settleRealWork()` helper (`Task.yield()` + a real 50ms sleep)
  instead of `ManualTriggerScheduler.settle()`'s pure yield-loop — in
  this specific busy context (right after edit B's whole batch just
  completed), 50 cooperative yields were not reliably sufficient to let
  the detached, untracked retry `Task` complete before the assertion ran
  (confirmed both ways empirically: this is a real synchronization gap
  in the test's own reliability, not a hint of a code bug — the
  underlying fix behaves identically either way).
- **Major — coalescer supersede-after-wake-before-fire.**
  `BurlyKit/Sources/BurlyPhoneSync/QuietPeriodCoalescer.swift`: `fire`
  used to trust "the scheduler resumed me and `Task.isCancelled` reads
  false" as proof it was still current — but a fresh `coalesce()` can
  install a new task between a countdown's wake and its `fire` call
  actually reaching the actor (cancellation is cooperative, not
  preemptive). Fixed by giving every countdown an opaque `UUID` token;
  `fire(token:)` now re-checks `token == currentToken` — read fresh,
  actor-isolated, at the moment it would consume the pending payload —
  and backs off with NO side effects (does not touch `pendingPayload`,
  `currentTask`, or `currentToken`) on a mismatch, rather than firing the
  newer payload at the stale deadline and then nulling out the live
  task reference. Added a test-only `afterWakeTestHook` seam (an
  actor-isolated suspension point right after wake, before the token
  check) so the exact interleaving is reproducible deterministically
  rather than by scheduling luck. Pin:
  `supersessionAfterWakeBeforeFireBacksOff` in
  `QuietPeriodCoalescerTests.swift`, using a new `WakeGate` test actor.
  Verified it fails (records B's payload at A's stale deadline) with the
  `guard token == currentToken` check removed, across 3 repeated runs.

Verification:
- `swift test` (full suite): **693 tests, 72 suites, all pass** (up from
  684/72 — 9 new tests: 4 for the blocker edge, 1 for the Int.max
  high-water record, 1 for the placeholder-rollback gap, 1 for catalog
  persistence-failure surfacing, 1 for the stale-retry epoch check, 1 for
  the coalescer wake-before-fire race).
- `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`:
  2/2 pass.
- `BURLY_RUN_DIGEST_BENCHMARK=1 swift test --filter
  DigestGenerationBenchmarkTests`: still gated correctly (skips without
  the env var; the benchmark itself was untouched this round).
- `swift build -c release`: clean.
- Flakiness check: full suite run 3x back to back — consistently green;
  `QuietPeriodCoalescerTests`/`PushTriggerTests` (the two timing-sensitive
  suites this round touched) run 3x in isolation — consistently green.
- Verification method note: for every one of the 6 fixes, the fix was
  temporarily reverted (or its guard/check removed) in-place, the new pin
  re-run to confirm it fails on that exact pre-fix code (not merely "some
  other assertion elsewhere fails"), and then the fix was restored and
  re-verified green — the backup/restore used `cp` to a scratch path
  outside the repo, never a git operation, so the working tree's history
  stays a single clean forward diff.

Disagreements / flags: none for this round — all 6 findings were
concrete, reproducible, and fixed as described; no finding is disputed.

Commit: see the commit immediately following this HANDOFF update in the
branch's log for the SHA.

Next:
- Nothing blocking. Hand off for dispatcher re-review — this was
  characterized as the closing round.
- Same two follow-ups as before remain out of scope for this task: real
  `PhoneSyncCoordinator` wiring into BurlyPhone's app lifecycle, and the
  real WCSession-backed `PhoneSyncTransporting`/`PhoneDigestPublishing`
  conformers (both still m4-03/m4-06 work).

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-04
Branch: task/burly-m4-04 (based on main 5ab56d1; two review-fix rounds
on top of f224412: e5b908e round 1, then round 2 below)
Status: all 18 cumulative review findings (12 round 1 + 6 round 2) fixed
+ pinned, 693 tests green, release build clean. Committed (not pushed).
Next action: hand off for dispatcher re-review; no local work pending.
```

## 2026-08-02 — review round 3 fix pass (the blocker's PREVENTION + 2), closing round

Round 3 (`.scratch/m4-04-review-3.md`) on `387549b`: NOT-SAFE. §1 the
recurring blocker — the unrecoverable state was detected (flag) but the
coordinator still OPERATED from a zeroed state, so a corrupted phone could
retransmit reused `(version, generation)` identities. Plus a §1 write-path
ceiling gap and §6's wall-clock race pins. Exactly 3 fixes, on top of
`387549b`:

- **§1 BLOCKER — detect AND prevent.** `PhoneSyncCoordinator`: while
  `syncStateUnrecoverable`, EVERY public entry point is a silent no-op —
  gates on `sessionReceived`, `applicationDidLaunch`,
  `watchAppInstalledDidChange`, `dailyPushIfDue`, `catalogDidChange`,
  `historyDidChange`, `snapshotTransferFinished` (that one also prevents
  `deliver` laundering the zero state into a clean save) — plus
  defense-in-depth gates on the two transmission funnels (`execute`,
  `publishDigestNow`) and `deliverCatalogChanged`. New explicit exit:
  `resetSyncStateForRePair()` — no-op unless unrecoverable; persists a
  fresh zero domain FIRST, only then lifts the gates (failed persist stays
  quiescent); contract documented on the method (call only as part of a
  real re-pair; misuse against a non-reset watch stalls, never corrupts —
  the watch's version rule refuses regressed versions). Pins: new
  `SyncUnrecoverableQuiescenceTests.swift` (5 tests) incl. the review's
  named pin: files held (7, 11), corrupted both, every trigger driven,
  transport + digest publisher provably received NOTHING, machine state
  never moved, ingest is a full no-op.
- **§1/§2 — identity ceiling on the WRITE path.**
  `validatePhoneSyncIdentityBounds(_:)` now runs at the top of BOTH
  conformers' `save()` (before even the high-water append), throwing new
  `PhoneSyncIdentityOverflowError`; bound is inclusive
  `0...maximumPhoneSyncIdentity` consistently across read, save, and
  increment (the increment PAST the ceiling is what fails, at persist
  time, before any transmit — deliver/persist-before-execute makes save
  the transmission choke point). 5 new pins in
  `PhoneSyncStatePersistingTests` (save-refusal both conformers + files
  unchanged, at-ceiling round-trip, launch-increment past ceiling throws
  with transport untouched, catalog-edit overflow surfaced on
  `lastCatalogPushFailure` with zero transmissions).
- **§6 — deterministic race pins, no wall-clock.** `settleRealWork()`
  (50 ms sleep) deleted from TestSupport. The epoch pin now captures the
  untracked retry `Task` via new internal seam
  `PhoneSyncCoordinator.mostRecentCatalogRetryTaskForTesting` and awaits
  `.value`; the coalescer pin captures countdown A's handle via new
  internal seam `QuietPeriodCoalescer.currentTaskForTesting` and awaits
  it after releasing the wake gate. Both negative assertions now run only
  after the stale work has provably completed.

Round-2 closed fixes untouched: SwiftDataStore/ReplicatedSessionApplyTests
not in the diff at all (placeholder rollback); epoch guards, token guard,
and catalog retry/surface logic unchanged (only read-only seams added).

Verification: `swift test` 703/73 green (was 693/72; +10 pins);
`BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` 2/2;
`swift build -c release` clean; QuietPeriodCoalescerTests and
PushTriggerTests each run 5x — 10/10 green (~0.001 s / ~0.09 s, no
wall-clock dependence). Revert-verified all three (cp-backup, revert,
re-run, restore — no git ops): gates stripped → quiescence pins fail on
the exact transmit-from-zero trace; validation stripped → out-of-range
identity persisted AND transmitted; token guard stripped → coalescer pin
fails 3/3; epoch guards stripped → epoch pin fails 3/3 with the [2, 1]
resurrection.

Disagreements: none. Round 3's §1 explicitly overrules round 2's
"deliberately not auto-mitigated" doc stance; the doc now says the
opposite and explains why.

Next:
- Hand off for dispatcher re-review. Same out-of-scope follow-ups as
  before (app wiring, real WCSession conformers — m4-03/m4-06). The host
  app must surface `syncStateUnrecoverable` and offer the re-pair flow
  that calls `resetSyncStateForRePair()` — app-integration work.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-04
Branch: task/burly-m4-04 (f224412 → e5b908e → 387549b → this round 3 fix)
Status: 3 round-3 fixes done + pinned + revert-verified, 703 tests green,
release build clean. Committed (not pushed).
Next action: hand off for dispatcher re-review; no local work pending.
```
