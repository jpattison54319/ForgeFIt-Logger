# FF-005 — Outdoor Interval Split Preservation

**Status:** In Review
**Severity:** P1
**Owner:** DeepSeek V4 Flash 0731 — FF-005
**Source audit date:** 2026-08-10

## Problem

Completing an outdoor GPS workout deletes the athlete's manually labeled interval
splits and replaces them with auto-generated distance splits. Manual interval
structuring — work/rest or zone labels the user created deliberately — is
destroyed at completion.

## Confirmed trigger

- Start an outdoor GPS workout on a route that includes interval splits.
- The user labels interval splits manually during the session.
- Complete the workout.
- The completion path drops all labeled interval splits and substitutes distance
  splits.

## User impact

The athlete loses their manual interval segmentation and sees a distance-based
split list instead. The labeled structure they relied on for review is gone,
which undermines the whole point of interval workouts and corrupts the recorded
history.

## Source evidence

- Outdoor GPS completion path (audited 2026-08-10): on completion it replaces
  all labeled interval splits with derived distance splits.
- History rendering of the completed workout shows the distance splits instead of
  the manual interval labels.

## Scope

- In scope: preserving manual interval splits through outdoor completion while
  still recording route and distance information.
- Out of scope: changing how GPS routes are captured or stored.

## Non-goals

- Not removing distance-split storage — route/distance info must still be
  recorded.
- Not redesigning the split UI.
- Not altering interval capture during the active session.

## High-level fix direction

Make completion additive rather than destructive for manual intervals:
- Keep the athlete's manual interval splits across all completion routes.
- Store distance/route information alongside rather than replacing the interval
  data.
- Ensure history renders the preserved manual intervals and can still access the
  recorded distance/route.

## Acceptance criteria

- [x] Completing an outdoor GPS workout preserves all manually labeled interval
      splits.
- [x] Route and distance information is still stored from the same completion.
- [ ] History shows the preserved manual interval splits (not distance splits
      substituted for them).
- [x] All outdoor completion routes behave identically with respect to splits.

## Required automated tests

- [x] Tests across all completion routes (outdoor/aerobic variants): manual
      interval splits are preserved and distance info still present.
- [ ] History test: completed GPS workout renders manual interval labels with
      route/distance data available.

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`): complete a simulated GPS workout and confirm
      manual interval labels survive in history.
- [ ] Hardware iPhone (and Watch if applicable): real outdoor completion preserves
      labeled intervals on-device.

## Dependencies

- None new. Independent of FF-001/002/003/004/006; proceeds in Wave C.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-005 | Claimed. Auditing outdoor/aerobic completion paths and history reader for split replacement. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-005 | Implemented: `CardioRouteMath.replaceSplits` preserves manual interval splits (labeled, non-auto-detected) instead of substituting distance splits; free-form runs still get distance splits. Added `CardioRouteSplitPreservationTests` covering both shared completion primitives (`replaceSplits`, `replaceRoute`) and the revert path. Tests were NOT run (file-edit worker). |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-005 | Static-review follow-up: stored manual splits now independently suppress auto-detection. `CardioRouteMath.isManualIntervalSplit` is the shared predicate; `CardioSeriesService.finalize` and `applyDetectedIntervals` both skip replacement when stored manual splits exist, even with `hadManualIntervalPlan` false. Added 2 deterministic detection-invariant tests (no HealthKit). Tests NOT run. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-005 | Manager-executed verification recorded: package run, targeted iOS 26.5 clean-simulator run (39 tests in 7 suites), iPhone simulator build, and Watch simulator build all exit 0 — see "Tests requested / run" for logs and result bundles. No live outdoor GPS/route UI run or physical-device workout was executed. |

### Files changed

- `ForgeFit/Cardio/CardioRouteSupport.swift` — `replaceSplits` now preserves
  manual interval splits; only derived splits (distance laps, auto-detected
  laps) are deleted, and distance-split generation still runs for free-form
  runs. Added `CardioRouteMath.isManualIntervalSplit` as the shared predicate.
  Every outdoor/aerobic completion route funnels through this primitive (phone
  card `CardioViews.complete`, Watch `completeCardio`, `WorkoutFinisher`,
  `HealthWorkoutImporter`, GPX import), so all behave identically.
- `ForgeFit/Cardio/CardioSeriesService.swift` — `finalize` and
  `applyDetectedIntervals` both skip auto-detection when stored manual splits
  exist (independent of the `hadManualIntervalPlan` caller flag); the guarded
  free-form detection/revert behavior is unchanged.
- `ForgeFitTests/CardioRouteSplitPreservationTests.swift` — regression suite:
  4 preserve-manual completion cases, 2 free-form regression guards, the
  auto-interval revert path, and 2 detection-invariant tests.
- `docs/release-audit-remediation/stories/FF-005-outdoor-interval-split-preservation.md`
  — status/work log updated.

No schema change (CloudKit-compatible; no production migration).

### Tests requested / run

Requested by the worker; RUN by the manager, passes recorded 2026-08-11 (the
file-edit worker executed none of these):

- Package run: `DEVELOPER_DIR <beta> make -e test` — exit 0. ForgeCore 400
  tests and ForgeData 87 tests passed plus support builds. Log:
  `/tmp/forgefit-wave1-make-test-final.log`.
- Targeted iOS 26.5 clean-simulator run — exit 0; 39 tests in 7 suites,
  including all `CardioRouteSplitPreservationTests` and
  `IntervalRunnerDistanceTests`. Log: `/tmp/forgefit-wave1-targeted-clean-sim.log`;
  result bundle: `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`.
- iPhone simulator build — exit 0. Log: `/tmp/forgefit-wave1-build-ios-rerun.log`
  (an earlier no-space infrastructure failure preceded the successful rerun).
- Watch simulator build — explicit build, exit 0. Log:
  `/tmp/forgefit-wave1-build-watch.log`.

Automated coverage therefore proves manual split preservation through
`replaceSplits`, `replaceRoute`, the detection guard, the no-GPS completion
path, free-form distance-split generation, and `revertAutoIntervals`.

### Residual risks

- No live outdoor GPS/route UI completion was executed — a simulated GPS
  workout was never completed and reviewed in the real history UI, and no route
  map was displayed for a preserved-interval session. Model-level preservation
  is proven by the passing automated suite; the visual history flow is not.
- No physical iPhone or Watch workout was executed; `devicectl` reports
  physical devices unavailable, so on-device preservation of labeled intervals
  is unverified.
- History rendering (`WorkoutDetailView.splitsTable`) was not changed and is
  only covered at the data level (preserved labels + route/distance present on
  the model); view-level confirmation under the route map still requires a live
  run.

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| 2026-08-11 | Manager (static review) | Changes Requested | `replaceSplits` directionally correct; manual interval splits must independently suppress `applyDetectedIntervals` even when the caller flag is false. Addressed in code (`CardioSeriesService.finalize` + `applyDetectedIntervals` via shared `CardioRouteMath.isManualIntervalSplit`); regression tests added, not yet run. |

## Definition of Done

- [ ] All acceptance criteria checked.
- [x] Required automated tests added and passing via the named command.
- [ ] Required runtime / hardware validation executed and results recorded.
- [x] Worker work log completed (status, owner, files changed, tests,
      residual risks).
- [ ] `Status` moved through Planned → In Progress → In Review → Changes
      Requested / Verified → Done.

## Final sign-off

> **Done and sign-off are set by the manager alone.** Workers never mark a story
> Done or sign it off.

- **Verified by (technically):**
- **Done set by (manager):**
- **Date:**
- **Release gate:** this story is / is not a blocker for the remediation release.