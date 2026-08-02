# HANDOFF — burly-m4-02 (delete in the PR that closes this task)

## 2026-08-02 — machines implemented, all gates green

Done: BurlySyncMachine target (dependency-free seam; Watch/PhoneSyncMachine as pure reducers), BurlySync DTO binding (`SyncMachineBinding.swift`), digest strict decode (m4-01 review 2), fake-transport convergence tests for all §5 acceptance #1 scenarios. `swift test` 486/486; migration spike green; 3 mutation spot-checks caught.
Next: dispatcher acceptance review; then m4-03 binds WCSession to the command/event vocabulary per the mapping table in `SyncMachineBinding.swift`.
Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m4-02 (branch task/burly-m4-02, do not push)
Next action: dispatcher re-runs acceptance — in BurlyKit/: swift test && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
