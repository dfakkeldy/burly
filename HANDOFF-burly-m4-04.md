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
