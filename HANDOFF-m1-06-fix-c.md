# HANDOFF — m1-06 fix round C (finding M3: V1 schema not frozen)

## 2026-08-01 — nested models + migration spike landed

Done:
- All nine `@Model` classes moved into `extension BurlySchemaV1 { … }`
  (BurlyKit/Sources/BurlyPersistence/Models/*.swift); new
  Schema/CurrentSchema.swift holds the single typealias block
  (`BurlySchemaCurrent` + nine names) and the v2 procedure.
- Shipping `BurlyMigrationPlan` unchanged: `[BurlySchemaV1]`, no stages.
  No public API touched; no non-model source file touched.
- Migration spike is **test-scoped**: Tests/BurlyPersistenceTests/
  MigrationSpikeSchemaV2.swift declares a throwaway v2 (all nine models
  copied, `SetRecord.rpe: Double?` added) plus a `.custom` V1→V2 stage that
  records what it saw. MigrationPlanTests writes a v1 store to disk and
  reopens it through that ladder.
- `swift test` from BurlyKit: 337 tests / 37 suites, all green (baseline 334).

Next:
- Dispatcher merges `task/m1-06-fix-c` into local `main`. Nothing pushed.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m1-06-fix-c, branch
task/m1-06-fix-c (off local main 7d99ec1). Work is committed and green.
Next action: merge task/m1-06-fix-c into local main; do not push.
```
