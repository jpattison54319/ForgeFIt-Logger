# FF-009 — Long-range health aggregation performance risk

- **Status:** In Review
- **Severity:** P1 — performance risk for release gate
- **Owner:** Codex direct remediation
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

- **2026-08-11 — DeepSeek V4 Flash 0731 — FF-009 (worker):** Claimed;
  Status → In Progress. Implemented the whole fix and added the required
  tests; all edits are file-only and **no test, build, or benchmark has been
  run in this session** — verification is explicitly deferred (see "Tests
  requested — NOT run" below). Manager alone may set Verified/Done.

### Files changed (this claim)

- `ForgeFit/Health/NocturnalAggregator.swift` — added `SleepWindowIndex`
  (sorted-window binary search, inclusive bounds), rewrote `nightly` to use
  it, added `sourcesByDay` one-pass prebucket, made `SleepWindow` and
  `NightlyMetric` `Sendable`.
- `ForgeFit/Health/CancellableDetachedWork.swift` (new) — explicit
  cancellable `Task.detached` utility with caller-cancellation forwarding.
- `ForgeFit/Health/RecoveryDailyAggregator.swift` (new) — pure,
  HealthKit-free per-day recovery bucketing extracted from
  `HealthService.dailyMetrics`, with prebucketed sleeping-HR source
  attribution.
- `ForgeFit/Health/HealthService.swift` — bounded + cancellable sample
  queries (`HealthQueryBounds`, `runSampleQuery` with `HKHealthStore.stop`
  on cancellation and truncation detection), capped long-range fetches,
  `dailyMetrics` now runs the CPU aggregation through
  `CancellableDetachedWork`.
- `ForgeFit/Analytics/RecoveryEngine.swift` — `DailyHealthMetric` now
  `Equatable` (equivalence tests compare old vs new output). No field or
  semantic change.
- `ForgeFitTests/RecoveryDailyAggregatorTests.swift` (new) — equivalence vs
  a verbatim legacy reference, index/bounds/cancellation/isolation tests,
  and the deterministic 730-day benchmark.
- This story file.

### Tests requested — NOT run

Not run in this session (file-edit-only constraint). Run with
`make test-app` or the targeted suite
(`-only-testing:ForgeFitTests/RecoveryDailyAggregatorTests`):

- Equivalence: prebucketed aggregation == legacy day×sample×window scan on
  a fixed synthetic dataset (includes window-boundary samples, `bpm == 0`
  source attribution, multi-window nights, sources with ties-free counts).
- Bounds: `HealthQueryBounds.sleepHRQueryCap` / `allDayChannelCap` /
  `isTruncated` unit tests; `CancellableDetachedWork` forwards parent
  cancellation; a cancelled parent stops the 730-day aggregation promptly.
- Isolation: aggregation through `CancellableDetachedWork` never executes on
  the main thread (asserted from a `@MainActor` test).
- Benchmark: deterministic 730-night dataset (~1 M samples) completes under
  5 s with 730 output days; the legacy scan at this size would need
  ~10^11 comparisons (minutes).

### Measured expectations (to confirm when run)

- New aggregation at 730-night scale: linear-ish, ~0.5–2 s in a debug test
  build; well under the 5 s bound even on loaded CI.
- Legacy reference at the small equivalence scale (30 nights): tens of ms.
- `sleepHRQueryCap` for an 8 h night = 86 400 (1 Hz × 3 device slack).

### HealthKit limits that cannot be truthfully unit-tested

- Executing an `HKSampleQuery`, `HKHealthStore.stop(_:)`, and real
  truncation require a live HealthKit store with authorized data — unit
  tests have neither. The cancellation *coordination* (`InFlightHealthQuery`
  once-only resume, stop-on-cancel race) and the truncation *decision*
  (`isTruncated`) are pure and tested; the store interaction itself is not.
- HealthKit offers no streaming/pagination cursor, so "bounded" is enforced
  as a cap above physical maxima plus detection-and-degrade on hit.
- `HKStatisticsCollectionQuery` aggregation was considered and rejected: it
  deduplicates overlapping same-type samples across sources (HealthKit picks
  the higher-priority source), which changes per-day means and source
  attribution versus the raw-sample enumeration the app currently displays.
  Switching would violate the "no displayed-result change" non-goal.

### Residual risks

- **Truncation false positive:** if a channel ever had *exactly*
  `allDayChannelCap` (2 000 000) samples, the fetch is discarded (metrics
  for that channel go empty) rather than truncated. Astronomically unlikely
  for a wearable-fed dataset; events are logged via
  `HealthService.queryBoundsLogger`.
- **Multi-device HR in one night:** the sleep-HR cap assumes ≤ 3 concurrent
  sources at 1 Hz. A fourth concurrent high-rate source could hit the cap
  and drop that channel for the night (degrade, never wrong numbers).
- **Threading:** HealthKit *adaptation* (unit conversion, source extraction,
  sleep filtering) still runs on the caller's executor — cheap mapping only.
  The heavy bucketing/binning/dominance pass is guaranteed detached.
- **`sleepHistory` remains unbounded** (`sleepSamples(from: nil, ...)`) by
  design — it is the screen-scoped full-history load, not the audited
  730-day readiness path; left untouched for a minimal diff.
- Real-device Time Profiler / memory measurement on a 730-day dataset is
  still required (Definition of Done, runtime validation) — the automated
  benchmark proves algorithmic bounds, not wall-clock on-device behaviour.

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
