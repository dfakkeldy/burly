# HANDOFF — m1-06 fix c3 (CI-red: same-name v1/v2 schemas share a process)

## 2026-08-01 — migration spike isolated into its own process

Done:
- Test + CI only; no `Sources/` change.
- Spike tests moved out of `MigrationPlanTests` into a new gated suite
  `MigrationSpikeTests` (BurlyKit/Tests/BurlyPersistenceTests/
  MigrationSpikeTests.swift), `.enabled(if: migrationSpikeIsEnabled)` on
  `BURLY_RUN_MIGRATION_SPIKE=1`, plus `.serialized`. Header records both CI
  run IDs and both failure shapes.
- `.github/workflows/ci.yml` `package-tests` now runs two steps: plain
  `swift test` (spike gated off), then
  `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`.
  The second step greps its own log, because a closed gate or a typo'd
  filter both exit 0 having run nothing.
- Local: pass 1 = 337 tests / 38 suites (spike's 2 skipped); pass 2 = 2
  tests / 1 suite. Coverage unchanged at 337 across the two processes.
- Scripts/ has no canonical local test entrypoint (only acceptance-sim.sh,
  release-notes.sh), so the two-invocation recipe is documented in the test
  header instead.

Open:
- Collision theory is consistent with both CI failures but **still not
  reproducible locally** (Darwin 27). macos-26 is the only bench.
- Escalation if CI fails again with the spike skipped in pass 1: linking
  the v2 classes is itself enough to poison the registry, and the spike
  must move to a separate package. Noted in the test header.

Next:
- Dispatcher pushes `task/m1-06-fix-c3` to CI as the verification bench
  BEFORE merging to main.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-c3, branch
task/m1-06-fix-c3 (off origin/main 6e75fb4). Committed, both passes green
locally. Next action: push the branch to CI and read both package-test steps.
```
