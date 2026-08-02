<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Handoff — m1-06 fix round F

## 2026-08-01 — round E's digest check reverted, contract moved upstream

Round E merged as `7c267b9`; this branch continues on top of it. Review 4
passed round E's other two claims (one-way active + revision transitivity,
rollback-on-failed-save) and rejected the digest coverage preflight as
over-strict.

Done: removed `preflightDigestCoversAckedHistory` and the `.partialDigest`
error case. The refused shape (empty entries + a lift-bearing ack) is a
payload the phone legitimately produces — it may delete a session (§1) while
still holding the ack (§5 retains acked ids ~30 days) — and refusing it
stranded the session on the watch permanently once the ack aged out. The
watch cannot distinguish that from a generator bug, so the anti-partial
invariant is now a documented contract on `SessionDigestReceipt` /
`SessionDigestApplying`, owed by the phone-side generator (M4) and to be
property-tested there. Duplicate-entry validation, all prune tolerances, and
`applyDigest`'s one-save atomicity are untouched. The stranding sequence is
now a positive cold-reopen test. Also restored the unmentioned-ghost-row
survival control alongside the overwrite test.

Both CI invocations green: `swift test` 367 tests / 39 suites (365 run, 2
spike skipped; round-E baseline 368/366 — net −1, eight throw-expecting
tests of a wrong invariant replaced by seven of the right one), and
`BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` 2
tests / 1 suite, both ci.yml anti-false-green guards satisfied.

Next: the M1 gate decision, then merge `task/m1-06-fix-d` into `main`.

Resume:

```
Review m1-06 fix round F: worktree
/Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-d, branch
task/m1-06-fix-d (1 commit on top of origin/main 7c267b9). It REMOVES the
round E digest coverage preflight and the .partialDigest error case, and
replaces them with a generator-side contract on BurlySync's
SessionDigestReceipt. No other public surface changed. Verify BOTH test
invocations.
```
