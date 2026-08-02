# HANDOFF — m1-06 fix c2 (CI-red: migration spike's post-migration write)

## 2026-08-01 — save/close discipline made explicit; not reproducible locally

Done:
- Test-only change. The spike's phase 3 wrote `rpe`, saved, and then opened a
  second container **while the writing container was still alive**; the
  reopen was therefore a concurrent-connection question, not a cold-open
  one. Writer is now confined to an `autoreleasepool` scope that ends before
  the reopen, and the reopen is its own scope.
- Added two diagnostics so a residual CI failure names its own cause:
  `SpikeMigrationTrace.stageRuns` (asserted == 1 after the migration *and*
  after the reopen — catches a store that re-migrates on every open) and a
  same-container re-fetch right after `save()` (separates "never left the
  context" from "not durable to the file").
- `swift test` from BurlyKit: 337 tests / 37 suites green.

Not done / open:
- **Could not reproduce the CI failure locally.** This Mac is Darwin 27; CI
  is macos-26 and there is only one Xcode (26.6) here, and SwiftData is an
  OS framework, so the CI runtime is unavailable. A scratch diagnostic ran
  both the old (live-writer) and new (scoped) orderings 12× each: all 24
  passed with `stageRuns == 1`. The fix is therefore correct-by-discipline,
  **not verified against the failing build**.

Next:
- Dispatcher merges `task/m1-06-fix-c2` and watches CI. If it is still red,
  read which of the three new assertions failed before changing anything —
  `stageRuns == 2` means re-migration is discarding the write (a real
  SwiftData defect on that build), a failing same-container check means the
  save never left the context, and only the cold-open check failing means a
  genuine durability gap.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-c2, branch
task/m1-06-fix-c2 (off origin/main 14bdd21). Committed and green locally.
Next action: merge task/m1-06-fix-c2 to main and re-run CI; do not push.
```
