# FF-009 — Long-range health aggregation performance risk

- **Status:** Planned
- **Severity:** P1 — performance risk for release gate
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

`HealthService` fetches `HKObjectQueryNoLimit` for windows up to 730 days, and
`sleepingHRSourceBundleID` performs day × sample × window scans. This is
O(days × samples × windows) work with unbounded sample fetches. On large health
datasets this risks excessive memory and CPU, and heavy aggregation could run on
the `MainActor`.

## Confirmed trigger

A user with a long HealthKit history (approaching or exceeding 730 days) and
dense heart-rate/sleep samples triggers the aggregation path. The unbounded
fetch and nested day/sample/window scan produce a disproportionate workload and
can stall the main thread.

## User impact

Slow or blocked UI during readiness/recovery aggregation, high memory use, and
potential app stalls. On a large dataset the work may be effectively unresponsive
and heavy aggregation may run on the main actor.

## Source evidence

Repository-relative paths and symbols:

- `HealthService` — `HKObjectQueryNoLimit` used for fetches up to ~730 days.
- `sleepingHRSourceBundleID` — performs day × sample × window scans.

## Scope

- HealthKit query construction in `HealthService`.
- `sleepingHRSourceBundleID` scan algorithm.
- Where aggregation executes (must remain off the `MainActor`).

## Non-goals

- No change to the health-query semantics or displayed results/equivalence.
- No analyst-visible accuracy regressions.

## High-level fix direction

- Prebucket/index sleep windows and sources instead of scanning day × sample ×
  window repeatedly.
- Use bounded/cancellable queries, or HealthKit aggregation where result
  semantics permit.
- Never move heavy aggregation onto the `MainActor`.
- Add a deterministic large-data benchmark and equivalence tests proving
  unchanged results before and after.

## Acceptance criteria

- [ ] Sleep windows and sources are pre-bucketed/indexed rather than rescanned
      per day × sample × window.
- [ ] Queries used are bounded and cancellable, or HealthKit aggregation where
      semantics permit.
- [ ] No heavy aggregation executes on the `MainActor`.
- [ ] A deterministic large-data benchmark documents the improvement.
- [ ] Equivalence tests confirm results are unchanged versus the old path.

## Required automated tests

- Equivalence test on a fixed synthetic dataset (old vs new algorithm).
- Cancel/bound behavior test when a query must stop.
- Large-data benchmark (deterministic dataset) showing bounded time/memory.
- Main-thread isolation test asserting aggregation does not run on `MainActor`.

## Required runtime/hardware validation

- Build/run on a real or simulaged device with a large 730-day HealthKit history;
  measure Time Profiler / memory during readiness aggregation.

## Dependencies

- HealthKit query APIs and `StatisticsQuery`/aggregation semantics.
- Existing readiness/aggregation call sites.

## Worker work log

_Workers: update Status, Owner, work log, files changed, tests
requested/run, and residual risks. The manager alone sets Done and signs off._

- (empty — no work claimed)

## Reviewer log

- (empty — no review claimed)

## Definition of Done

All acceptance criteria pass; required automated tests exist and pass; required
runtime/hardware validation is documented; reviewer log has a sign-off by the
manager.

## Final sign-off

- **Done set by (manager):** _unset_
- **Date:** _unset_
- **Sign-off notes:** _unset_