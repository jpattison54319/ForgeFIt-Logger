# FF-016 — Superset drop-set round indexing

- **ID:** FF-016
- **Title:** Superset drop-set round indexing
- **Status:** In Review
- **Severity:** P2
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

In a superset, per-exercise `roundIndex` is produced by comparing against the
raw set array index, which includes drop sets as their own positions. Because
rounds are derived from those raw indices and compared across member
exercises, drop chains can make rounds uneven: an exercise with a drop set
reports a different `roundIndex` than a member without one at the same logical
point, so rest can start or be suppressed incorrectly on phone and Watch.

## Confirmed trigger

`supersetRoundIndex(for:in:)` returns the raw `index` of the set for any
non-drop set and, for a drop set, the last non-drop index before it
(`ForgeFit/Workout/ActiveWorkoutLoggerView.swift`, `ForgeFit/Health/WatchLink.swift`).
`setAndDropChainComplete(at:in:)` then walks `index+1` through trailing drop sets
to decide whether that round's chain is complete. When unrelated drop chains
shift raw indices relative to a sibling exercise's rounding, `groupMembers.allSatisfy`
(member `roundIndex < memberSets.count` / `setAndDropChainComplete`) evaluates
the wrong round and starts or withholds rest wrongly.

## User impact

- Rest timer fires (or fails to fire) at the wrong time between superset rounds on the phone.
- Watch shows inconsistent rest behavior compared with the phone for the same logged workout (code is duplicated in both places).
- Coached/relaunched workout rest behavior diverges from a clean start.

## Source evidence

- `ForgeFit/Workout/ActiveWorkoutLoggerView.swift`
  - `handleCompletedSet(_:in:)` — group round completion check (lines ~1358–1377).
  - `hasPendingDropSet(after:in:)` (lines ~1379–1385).
  - `supersetRoundIndex(for:in:)` (lines ~1387–1391) — `guard set.setType == .drop else { return index }`.
  - `setAndDropChainComplete(at:in:)` (lines ~1393+).
- `ForgeFit/Health/WatchLink.swift` — `startRestIfNeeded`, `hasPendingDropSet`, `supersetRoundIndex(for:in:)`, `setAndDropChainComplete(at:in:)` (lines ~1076–1109+), effectively duplicate logic.

## Scope

- Round/chain indexing used by phone (`ActiveWorkoutLoggerView`) and Watch (`WatchLink`) rest-start logic.
- Mapping a set to a logical working-set round independent of drop-chain raw indices.

## Non-goals

- Not changing how drop sets are modeled, stored, or displayed.
- Not redesigning superset grouping; only the round/rest trigger computation.

## High-level fix direction

Introduce a single, tested mapping from a set to its logical working-set round
that is independent of drop-chain raw indices — e.g. derive round from the
count of prior non-drop working sets, or map member exercises onto a shared
round plane — and have both the phone and Watch use that same implementation
(rather than duplicated private methods). The test surface must cover uneven
rounds caused by drop chains present in one member but not its sibling.

## Acceptance criteria

- [ ] A set maps to the correct logical working-set round regardless of intervening drop sets.
- [ ] Rest starts only when all superset members have completed the same logical round (drop chains included).
- [ ] Phone and Watch use one tested round/chain implementation (shared code).
- [ ] An uneven superset (drop chain in one member only) starts/suppresses rest identically on both surfaces and matches a clean-start result for the same logical round.

## Required automated tests

- Unit tests for the extracted round mapper over crafted set arrays with drop chains in one member only.
- Tests asserting rest start/suppression parity between the phone and Watch paths.
- Existing superset orchestration tests still pass.

## Required runtime/hardware validation

- Manual: complete a superset where one exercise has a drop set; confirm rest triggers exactly once at the correct round boundary on both phone and Watch.

## Dependencies

- Shared round implementation must be reachable from both the Watch and iOS targets (confirm module location/visibility before implementation).

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- Round/rest computation proven correct for uneven (drop-chain) supersets.
- Phone and Watch share one tested implementation.
- Acceptance criteria met with automated tests green.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_
