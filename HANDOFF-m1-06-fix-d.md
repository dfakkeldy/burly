<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Handoff — m1-06 fix round D

## 2026-08-01 — surface leaks closed, committed, not pushed

Done: `logSet` removed from `BurlyStore`; creating `saveActiveSession`
forces revision 1; digest seam widened to `SessionDigestReceipt` /
`SessionDigestApplying` (both halves required) with
`upsertLastPerformance`/`pruneDeliveredSessions` made internal;
`createSession` and `applyPhoneEdit` refuse `.active`, `applyPhoneEdit`
retires the journal, single-active enforced, `resumableActiveSession` scans
past stale journals; `WeightEditState` validating decoder + non-finite
arithmetic refused; stored-NaN limitation and module Sendable doc corrected.
Rebased onto origin/main `bdee3fe`; the spike's set-logging body was
transplanted into c3's gated `MigrationSpikeTests`. Both CI invocations
green: `swift test` 354 tests / 38 suites (352 run, 2 spike skipped;
baseline 337/335), and `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter
MigrationSpikeTests` 2 tests / 1 suite, both ci.yml anti-false-green guards
satisfied.

Next: review round E, then merge `task/m1-06-fix-d` into `main`.

Resume:

```
Review the m1-06 fix round D branch: worktree
/Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-d, branch
task/m1-06-fix-d (1 commit on top of origin/main bdee3fe). Re-run the
combined adversarial review against it; the public BurlyStore/BurlySync
surface changed deliberately this round. Verify BOTH test invocations.
```
