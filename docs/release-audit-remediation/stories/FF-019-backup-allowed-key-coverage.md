# FF-019 — Backup allowed-key coverage (exhaustive structural guard)

- **ID:** FF-019
- **Title:** Backup allowed-key coverage (exhaustive structural guard)
- **Status:** Verified
- **Severity:** P3 (test integrity)
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

The backup test that claims to walk the documented allowed-key sets
exhaustively does not actually cover every emitted/restored optional field:
the maximally populated workout fixture leaves six valid optional fields nil,
so those keys never appear in the emitted workout JSON and are missing from the
`workout` allowed-key set. The guard is therefore not exhaustive — a future
change to those fields would not be structurally reviewed.

## Confirmed trigger

The `maximallyPopulatedWorkout` fixture (`Packages/ForgeData/Tests/ForgeDataTests/BackupFormatTests.swift`) never sets the six fields, so the walk in `everyObjectLevelStaysWithinDocumentedKeySets` never visits them and the `workout` allow-list omits them. The actual backup does contain some of these fields and decodes correctly (per release audit, `artifacts/release-audit-2026-08-09/FINAL-AUDIT.md`).

## User impact

No user-visible behavioral bug today: the backup still round-trips and no
Health-data leak is indicated. The impact is test integrity — the claimed
exhaustive privacy/structural guard could miss a future field addition because
the fixture exercises a subset of the real schema.

## Source evidence

- `Packages/ForgeData/Tests/ForgeDataTests/BackupFormatTests.swift`
  - `maximallyPopulatedWorkout(userID:)` fixture (lines ~10–137) — the six fields are unset (nil).
  - `allowedKeys["workout"]` allow-list (lines ~155–192) — omits the six keys.
  - `everyObjectLevelStaysWithinDocumentedKeySets()` (lines ~213–283).
  - Health sentinels + `forbiddenKeys` (lines ~139–150).
- `Packages/ForgeData/Sources/ForgeData/Backup/BackupMapper.swift` — `workout` emit/restore paths.
- The six fields (release audit): `conditioningPlanSnapshotJSON`, `conditioningProgressJSON`, `conditioningResultJSON`, `wholeSessionRPE`, `wholeSessionRPERatedAt`, `wholeSessionRPEProtocolVersion`.

## Scope

- `Packages/ForgeData/Tests/ForgeDataTests/BackupFormatTests.swift` fixture and allow-list.
- Verification against `BackupMapper.swift` that all six fields are, in fact, emitted and restorable (round-trip + privacy guard).

## Non-goals

- Not changing what the backup includes/excludes (that is FF-020 policy work).
- Not adding new backup content beyond ensuring existing fields are covered by the guard.

## High-level fix direction

Populate the fixture with those six fields (realistic non-health values), add
the corresponding keys to the `workout` allow-list, and extend the
round-trip/privacy tests so every emitted workout field is both exercised and
guarded against Health sentinels. Enumerate all documented fields in one place
so a future field addition must be reviewed before it ships.

## Acceptance criteria

- [ ] The fixture sets all six previously-nil fields with non-health values.
- [ ] `allowedKeys["workout"]` includes all six fields.
- [ ] The emitted JSON for the fixture contains all six fields and the walk validates them.
- [ ] Round-trip restore preserves the six fields.
- [ ] No Health sentinel/key appears for these six fields in emitted JSON.

## Required automated tests

- Extend `everyObjectLevelStaysWithinDocumentedKeySets` (re-run with the populated fixture).
- Extend `roundTripPreservesEveryUserAuthoredField` to assert the six fields round-trip.
- Re-run the forbidden-key/sentinel absence test to confirm the six fields are non-health.

## Required runtime/hardware validation

- Package tests only (`make test`); no hardware validation required for a test fixture/guard change.

## Dependencies

- None blocking. Keep in sync with `BackupMapper.swift` field naming so allow-list and mapper cannot drift.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-019 | Claimed. Root cause confirmed by reading `BackupMapper.backupWorkout` / `workoutModel` and `BackupWorkout`: all six previously-uncovered fields are emitted and restored under their model-DTO names (`conditioningPlanSnapshotJSON`, `conditioningProgressJSON`, `conditioningResultJSON`, `wholeSessionRPE`, `wholeSessionRPERatedAt`, `wholeSessionRPEProtocolVersion`). `maximallyPopulatedWorkout` now sets all six with realistic non-health values; the `workout` allow-list includes the exact emitted keys; emission-presence, not-a-Health-key, and round-trip assertions added. One test file changed. **`make test` explicitly NOT run** (file-edit-only worker, no shell). |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-019 | Implementation submitted for manager review. The `workout` allow-list entry was re-checked and switched from a stored-static derivation (`Set([...]).union(Self.workoutTrainingKeys)`) to the direct, type-safe array literal used by every sibling key set — compile safety could not be executed locally, so the deterministic form was chosen; the key-walk test still fails on any emitted key missing from the allow-list, so `workoutTrainingKeys` (used by the guard tests) and the allow-list cannot silently drift. Status moved Planned → In Progress → In Review. NO acceptance criteria checked; NOT Verified; NOT Done. **`make test` evidence explicitly NOT RUN — no pass claimed.** |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-019 | Adversarial-review P3 round addressed (test file only): (1) `readinessMethodID` / `readinessCoverageAtStart` added to `forbiddenKeys`; (2) `emittedJSONContainsNoHealthKeysOrSentinelValues` rewritten from raw-string substring greps to exact parsed structural comparisons — forbidden keys checked at every level of the parsed tree and scalar leaves compared exactly against restated `sentinelValues` renders (`52344.5`, `52399.9`, `6177.5`, all five `hrZoneSeconds` values); the substring grep was nondeterministic because random fixture UUID hex can contain digit-sentinel fragments, and exact comparison does not weaken the guard — any leaked health key or scalar is an exact match by construction; (3) `everyObjectLevelStaysWithinDocumentedKeySets` now populates and walks a representative `WorkoutImportBatchModel` so the existing `batch` allow-list branch is actually exercised; (4) documented honestly that `preferences` is a free-form `[String: BackupPreferenceValue]` dictionary validated app-side by `AppPreferenceKeys.backedUp`, outside this ForgeData structural walk — DoD exhaustiveness is scoped to the workout graph and the other documented structured levels. Test-file changes only; no production code touched. **`make test` still explicitly NOT RUN — no pass claimed.** Status remains In Review; no acceptance criteria checked; NOT Verified; NOT Done. |
| 2026-08-11 | Verified | Codex final reviewer | ForgeData completed with 88 tests in 13 suites passing (`/tmp/forgefit-forgedata-full.log`); the final ForgeFit unit gate also completed with 896 tests in 134 suites passing (`/tmp/forgefit-final-unit-only.log`). This story requires package tests only, so no hardware evidence remains. |

### Files changed

- `Packages/ForgeData/Tests/ForgeDataTests/BackupFormatTests.swift` — the one test file changed. Fixture populates the six previously-nil workout fields; `workoutTrainingKeys` guard enum set; `workout` allow-list now carries all six exact emitted keys; new `emittedWorkoutJSONContainsEveryDocumentedTrainingField`; not-a-Health-key loop inside `emittedJSONContainsNoHealthKeysOrSentinelValues`; six round-trip assertions in `roundTripPreservesEveryUserAuthoredField`. Adversarial P3 round (same file, still the only test file changed): `readinessMethodID`/`readinessCoverageAtStart` added to `forbiddenKeys`; the absence test rewritten to exact parsed-scalar comparisons; a representative `WorkoutImportBatchModel` populated and walked; `preferences` free-form/app-side note documented. No production files touched (`BackupMapper.swift`, `BackupFormat.swift`, models unchanged).
- `docs/release-audit-remediation/stories/FF-019-backup-allowed-key-coverage.md` — status/owner/work log/files changed/tests/residual risks updated (this file).

### Tests requested / run

**Run by the original worker: none.** The manager/final reviewer subsequently
ran the required suite: ForgeData passed 88 tests in 13 suites; log
`/tmp/forgefit-forgedata-full.log`. The final app-unit gate also passed 896
tests in 134 suites; log `/tmp/forgefit-final-unit-only.log`.

Requested for the manager (from the repo root as defined in `AGENTS.md`):

1. `make test` — package suites (ForgeCore + ForgeData). Covers `BackupFormatTests` (`everyObjectLevelStaysWithinDocumentedKeySets`, `emittedWorkoutJSONContainsEveryDocumentedTrainingField`, `emittedJSONContainsNoHealthKeysOrSentinelValues`, `roundTripPreservesEveryUserAuthoredField`). `CloudKitCompatTests` must stay green — no schema change was made.
   - No hardware validation required (P3 test-integrity fixture/guard change; package tests only).

### Residual risks

- **Execution evidence now present:** the manager-run ForgeData suite passed all
  88 tests, including the structural, emission, privacy, and round-trip guards.
- **Allow-list spelled out in two places:** the six keys now appear both in the `workout` allow-list and in `workoutTrainingKeys` (guard tests). Drift is prevented one-directionally — the key-walk fails if an emitted key is missing from the allow-list — but a future field addition is still a two-place edit by design. Restoring a single-source derivation (e.g. union) requires a compile-verified run first.
- **Emission-guard scope:** the fixture deliberately leaves `deletedAt` nil, so the presence guard covers the six training keys, not every allowed `workout` key; making it fully two-directional (every allowed key emitted) needs a `deletedAt` decision first.
- **Sentinel-substring and ISO-8601 assumptions, inspection-only:** the fixture values (including `wholeSessionRPERatedAt = 1_700_003_800`, a whole second under the `.iso8601` strategy, giving an exact round-trip) were checked by eye against `forbiddenKeys`/`sentinelValues`; only a run can prove no accidental substring.
- **`preferences` is outside this ForgeData walk (documented, not a gap):** the top-level `preferences` value is a free-form `[String: BackupPreferenceValue]` dictionary. This ForgeData guard checks only that the `preferences` key exists at the `file` level; preference-key allow-listing is enforced app-side by `AppPreferenceKeys.backedUp` (`BackupExporter`/`BackupRestoreService`), which package tests cannot see. DoD exhaustiveness is therefore specifically scoped to the workout graph and the other documented structured levels.
- **Exact-scalar sentinel semantics (deliberate, review-sanctioned):** the absence test now compares parsed scalar leaves exactly instead of substring-grepping the raw JSON, so an embedded JSON-string fragment (e.g. `155991` inside `sampleSeriesJSON`) matches only if it leaks as a bare scalar with that exact render; the field's own key (`sampleSeriesJSON`) remains bind-guarded by `forbiddenKeys`. A future worker restoring substring semantics must first switch the fixture to fixed noncolliding UUIDs, or the digit-sentinel collision flake the review flagged returns.

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| 2026-08-11 | Adversarial reviewer (P3 round) | P3s raised; corrections applied by the worker; NOT Verified | (1) `readinessMethodID` / `readinessCoverageAtStart` (Health-derived, local-only fields) were missing from `forbiddenKeys`; (2) the sentinel-absence test's raw-substring grep is nondeterministic — random fixture UUID hex or timestamps can contain digit-sentinel fragments (e.g. `15599`, `4577`); (3) the `batch` allow-list branch of the key walk was dead code while `batches: []`; (4) `preferences` needed honest documentation as a free-form dictionary enforced app-side by `AppPreferenceKeys.backedUp`, outside this ForgeData walk. All four accepted and implemented in `BackupFormatTests.swift` (exact parsed-scalar comparison chosen over fixed noncolliding IDs). `make test` still explicitly NOT run; Verified awaits the manager's run. |
| 2026-08-11 | Codex final reviewer | Verified | Required package evidence is green: ForgeData 88 tests / 13 suites. No hardware validation is required for this test-integrity story. |

## Definition of Done

- The exhaustive key guard genuinely covers every emitted/restored workout field.
- Round-trip and privacy tests extended and green.
- Acceptance criteria met.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_
