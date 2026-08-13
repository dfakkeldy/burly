## 2026-08-13 — first real gate red, both failures fixed (d55a0bd)

Done: Branch gated for the first time ever (`runs/20260813T204904Z`, rc=65,
phone 7/9). Both failures root-caused and fixed. `:316` — `historyDetail.addExercise`
sat at the bottom of a lazy `List` below the whole seeded graph and never entered
the a11y hierarchy; moved to `ToolbarItemGroup(.primaryAction)`. `:236` — a
regression in m5-01's `testPopulatedScenarioRendersRealRows`: m5-03 makes the row
navigable so it carries the button trait and `app.staticTexts[id]` stops matching.
Retargeted to the suite's `anyElement` idiom, identifier/timeout/message byte-identical.
Deliberate contract change to a merged task's test. The seed is healthy — `:287`
found the same identifier via `anyElement` and passed in that same red run.

Next: stage 4 re-gates via `gate-m5-03b.sh` (pre-flight asserts both fixes AND that
the inherited assertion survived verbatim). On green, take PR #4 out of draft and
delete this file in the closing PR. m5-05 unblocks when m5-03 merges.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m5-03, branch task/burly-m5-03 at d55a0bd.
Read scratchpad/gate-m5-03b.log. If rc=0, take PR #4 out of draft; if red, read the
EXACT FAILING LINES section before theorising.
```
