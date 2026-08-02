# HANDOFF — burly-m4-02 (delete in the PR that closes this task)

## 2026-08-02 — machines implemented, all gates green

Done: BurlySyncMachine target (dependency-free seam; Watch/PhoneSyncMachine as pure reducers), BurlySync DTO binding (`SyncMachineBinding.swift`), digest strict decode (m4-01 review 2), fake-transport convergence tests for all §5 acceptance #1 scenarios. `swift test` 486/486; migration spike green; 3 mutation spot-checks caught.
Next: dispatcher acceptance review; then m4-03 binds WCSession to the command/event vocabulary per the mapping table in `SyncMachineBinding.swift`.
Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-02 (branch task/burly-m4-02, do not push)
Next action: dispatcher re-runs acceptance — in BurlyKit/: swift test && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```

## 2026-08-02 — review round 1 closed (4 majors + minors), all gates green

Done: pin-first outbox payloads (reorder-convergence pinned); ack retention rebuilt as forward-only accumulated age (oscillation/rollback pins); push triggers cancel-and-resend (wedge pin); two-phase ingest — ack/publish only on `.sessionStoreConfirmed`, BINDING m4-05 contract in SyncMachineBinding.swift (stale-drop, stale-low, failed-commit pins); digest-coalescing obligation documented; seam guard checks manifest too. All mutation-checked. `swift test` 493/493; spike green. Commit 1004361.
Next: dispatcher re-review; m4-03 binds WCSession per the binding contract (items 1–6) and command mapping.
Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-02 (branch task/burly-m4-02, do not push)
Next action: dispatcher re-runs review/acceptance — in BurlyKit/: swift test && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```

## 2026-08-02 — review round 2 closed (3 findings + minor), all gates green

Done: watch refuses same-id completions inside the remembered acked-digest set (resurrection guard, bounded by phone retention); snapshot transfers identified by (version, generation) so cancelled same-version callbacks cannot clear the live slot; sessionStoreConfirmed correlated to a pending routing slot — at most once, duplicates/replays/never-routed ignored, pending slots aged out at the retention bound; seam import parser handles access-level modifiers and is itself pinned. Binding contract item 3 now requires at-most-once causal confirmations. All mutation-checked (11/3/17/7 failures). `swift test` 502/502; spike green. Commit 1ff8e00.
Next: dispatcher re-review round 3.
Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-02 (branch task/burly-m4-02, do not push)
Next action: dispatcher re-runs review/acceptance — in BurlyKit/: swift test && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
