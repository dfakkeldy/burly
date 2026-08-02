<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Handoff — m1-06 fix round E

## 2026-08-01 — round E findings closed, committed, not pushed

Round D merged as `4f86e5f`; this branch continues on top of it.

Done: `applyDigest` now validates the payload against what the prune
destroys — acking a session whose sets name exercises the digest omits
throws `.partialDigest` before any mutation (empty entry lists stay legal
when they prune nothing); `saveActiveSession`'s existing-row branch requires
the stored row to still be `.active`, throwing `.sessionNoLongerInFlight` —
which closes resurrection and makes "every `.active` row holds revision 1"
transitive; `ActiveSessionJournal`'s ownership comment now names all five
retirement paths; every `context.save()` routes through one `commit()`
helper that rolls back and rethrows, pinned by a suite that induces a real
failing save and was verified against its own inverse.

Both CI invocations green: `swift test` 368 tests / 39 suites (366 run, 2
spike skipped; round-D baseline 354/352), and `BURLY_RUN_MIGRATION_SPIKE=1
swift test --filter MigrationSpikeTests` 2 tests / 1 suite, both ci.yml
anti-false-green guards satisfied.

Next: the M1 gate decision, then merge `task/m1-06-fix-d` into `main`.

Resume:

```
Review m1-06 fix round E: worktree
/Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-d, branch
task/m1-06-fix-d (2 commits on top of origin/main 4f86e5f). Two new
BurlyStoreError cases this round (.partialDigest, .sessionNoLongerInFlight);
no other public signature changed. Verify BOTH test invocations.
```
