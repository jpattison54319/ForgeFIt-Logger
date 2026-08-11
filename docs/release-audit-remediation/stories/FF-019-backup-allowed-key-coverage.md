# FF-019 — Backup allowed-key coverage (exhaustive structural guard)

- **ID:** FF-019
- **Title:** Backup allowed-key coverage (exhaustive structural guard)
- **Status:** Planned
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

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- The exhaustive key guard genuinely covers every emitted/restored workout field.
- Round-trip and privacy tests extended and green.
- Acceptance criteria met.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_