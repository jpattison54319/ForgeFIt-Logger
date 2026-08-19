# FF-013 — Completing mid-yoga-hold does not record the current partial hold

- **Status:** In Review
- **Severity:** P2
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

Complete mid-yoga-hold stops the runner without recording the current partial
hold, whereas Skip records it. This yields inconsistent partial-credit semantics
across splits, pose count, exposure, and history, depending on how the workout
ends.

## Confirmed trigger

Ending a yoga session mid-hold via **Complete** does not record the current
partial hold, while ending via **Skip** does. The two exit paths therefore
aggregate different numbers of poses/holds into splits, pose count, exposure,
and history.

## User impact

Pose count, splits, exposure, and history differ depending on whether the user
ends the current hold with Complete or Skip. The partial-credit semantics are
inconsistent and not communicated by the UI.

## Source evidence

Repository-relative paths and symbols:

- Yoga Complete path — stops the runner without recording the current partial
  hold (in `ForgeFit/` yoga session sources).
- Yoga Skip path — records the current partial hold.

## Scope

- Yoga Complete vs Skip partial-hold handling.
- Aggregation across splits, pose count, exposure, and history.

## Non-goals

- No change to the yoga pose catalog or coaching dose.

## High-level fix direction

- Choose and apply one consistent partial-credit semantic across both Complete
  and Skip paths, and make splits, pose count, exposure, and history use it
  uniformly.
- Test the Complete, Skip, and background exit paths.

## Acceptance criteria

- [ ] Complete and Skip apply the same partial-hold semantics.
- [ ] Splits, pose count, exposure, and history all derive from the chosen
      semantic consistently.
- [ ] The Complete, Skip, and background paths converge on identical aggregate
      results for an equivalent mid-hold ending.
- [ ] UI communicates the partial-credit behavior.

## Required automated tests

- Complete mid-hold → current partial hold recorded.
- Skip mid-hold → matches Complete for an equivalent session.
- Background/termination exit path → consistent semantics.
- Split/pose-count/exposure/history aggregation equivalence across exit paths.

## Required runtime/hardware validation

- Manual watch run: end the same mid-hold yoga session via Complete and via
  Skip; confirm identical pose count, splits, exposure, and history.

## Dependencies

- Yoga session runner Complete/Skip/background exit paths.
- Splits, pose count, exposure, and history aggregation.

## Worker work log

_Workers: update Status, Owner, work log, files changed, tests
requested/run, and residual risks. The manager alone sets Done and signs off._

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-013 | Claimed FF-013. Traced Complete (YogaBlockCard/YogaViews/WatchLink completeCardio + completeWorkoutBlock/WorkoutFinisher), Skip (`YogaFlowRunner.skip()`), background termination (relaunch resume from persisted splits; watch-finished workout with no live runner), and the splits / pose-count / exposure / history aggregates. Chose the story-directed semantic: stopping a class mid-hold (Complete, Skip, or termination) credits the hold in progress with the seconds actually held as a recorded split, and all four aggregates derive from the recorded splits. Implemented `YogaFlowRunner.complete()` (Skip-parity, pause-aware recording, no advance), `YogaFlowRunnerHub.complete(for:)`, and a no-live-runner backstop `YogaSessionCompletion.recordInterruptedHold` that reconciles the interrupted hold from the persisted split timeline (never more than the supported wall-clock gap; ≥1 s minimum gap; `posesCompleted`-nil idempotency guard). Switched all five mid-hold completion call sites from `stop(for:)` to `complete(for:)`; deletion/cancel paths keep stop-without-credit. Added consequence copy under both Complete buttons. Added deterministic state/model tests for all required exit paths and aggregate equivalence. Tests requested but NOT run — this worker session is file-edits only (no shell/build/git). |

### Files changed

- `ForgeFit/Yoga/YogaFlowRunner.swift` — `YogaFlowRunner.complete()`, `YogaFlowRunnerHub.complete(for:)`.
- `ForgeFit/Yoga/YogaSupport.swift` — `YogaSessionCompletion` restructured; `recordInterruptedHold` backstop.
- `ForgeFit/Yoga/YogaBlockCard.swift` — Complete records the partial hold; consequence copy under the button.
- `ForgeFit/Yoga/YogaViews.swift` — Complete records the partial hold; consequence copy under the button.
- `ForgeFit/Health/WatchLink.swift` — watch Complete paths (block + cardio-yoga) record the partial hold.
- `ForgeFit/Workout/WorkoutFinisher.swift` — finish loop records the partial hold for live classes.
- `ForgeFitTests/YogaPartialHoldCompletionTests.swift` — new deterministic suite (8 tests, 11 scenarios).

WatchWorkoutEngine / WatchStore / ForgeData schema / README / other stories: untouched. FF-003 remains active.

### Tests requested / run

Requested — exist in `ForgeFitTests/YogaPartialHoldCompletionTests.swift`. **NONE run in this worker session** (file-edits-only constraint; no shell/builds, so every behavior claim below is unverified until the named commands pass):

- Complete mid-hold (runner alive) → current partial hold recorded; pipeline idempotent; pose count / exposure / history derived.
- Complete while paused → credits exactly the seconds held before pause (pause-exact, no wall-clock dependence).
- Skip mid-hold → same partial-credit shape as Complete for the in-progress hold.
- Background termination (no runner) → reconcile matches Skip+Complete aggregates exactly (splits, pose count, history, exposure) for an equivalent mid-hold ending.
- Termination inside the first hold (no splits at all) → partial from live start.
- Bilateral left-only termination → single-side history row, folded exposure, no phantom Right.
- No double split: natural finish with post-finish linger, and runner-recorded final hold.
- Conservative timestamps: negative wall-clock gap → no fabricated credit.
- Manual log → no interrupted-hold splits; plan-scaled exposure unchanged.
- Stop-without-credit: deletion/cancel paths (hub `stop(for:)`) never leave partial credit.

Suggested run (from repo root, app-suite host): `xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:ForgeFitTests/YogaPartialHoldCompletionTests`, then the ForgeData package guard `make test` (CloudKitCompatTests) — no schema change was made, but splits are written and the guard is the invariant.

### Residual risks

- **Resume after termination (FF-014 territory):** a terminated class that is later resumed replays the interrupted hold from zero; the pre-termination partial merges into the restarted hold and is not separately credited. Deliberately not changed here — resume semantics belong to FF-014.
- **Back-tracking:** a hold re-run via Back that never recorded a split is not retroactively credited by the no-runner backstop (forward-moving sessions reconcile exactly). Conservative by design; documented in `recordInterruptedHold`.
- **Terminated while paused:** pause state is not durable; the no-runner backstop credits the wall-clock gap, which includes paused time. The runner-alive paths (Complete/Skip/finish-with-live-runner) are pause-exact.
- **Manual watch/hardware validation** (end the same mid-hold session via Complete and via Skip on a watch; confirm identical pose count, splits, exposure, history) was NOT performed — no hardware in this session.
- **Tests not executed** in this worker session — see "Tests requested / run"; the suite compiles-unverified and every behavior claim above is a claim, not a result.

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
