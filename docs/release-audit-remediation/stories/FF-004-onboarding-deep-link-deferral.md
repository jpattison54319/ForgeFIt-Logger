# FF-004 — Onboarding Deep-Link Deferral

**Status:** In Review
**Severity:** P1
**Owner:** DeepSeek V4 Flash 0731 — FF-004
**Source audit date:** 2026-08-10

## Problem

Non-plan deep links (for example a routine, exercise, or history route) can be
routed and begin work behind the onboarding flow, which is not ready to receive
them yet. Independently, `clearStarterSlate` deletes **all** unfinished workouts
at onboarding dismissal, regardless of whether they were seeded starter data or
live user work-in-progress.

## Confirmed trigger

- A deep link arrives while onboarding is on screen.
- The router starts the linked scene under onboarding instead of holding it.
- On dismissal, `clearStarterSlate` runs and deletes every unfinished workout,
  including any real, user-created in-progress workout that must survive
  onboarding.

## User impact

Deep links can open the wrong state or open behind onboarding and be lost, while
the cleanup step can silently destroy an athlete's unsaved workout. The user sees
either a broken landing or a vanished in-progress routine.

## Source evidence

- Deep-link router (audited 2026-08-10): routes non-plan links immediately rather
  than deferring while onboarding is active.
- `clearStarterSlate` (audited 2026-08-10): at onboarding dismissal it deletes
  unfinished workouts without distinguishing seeded starter data from real user
  work.

## Scope

- In scope: queuing/deferring routes while onboarding is active, replaying them
  safely after dismissal, and narrowing the cleanup to seeded data only.
- Out of scope: redesigning the whole onboarding flow or the deep-link scheme.

## Non-goals

- Not applying the fix to plan-bearing links already handled correctly today.
- Not adding new route types.

## High-level fix direction

Separate routing and cleanup timing from onboarding:
- While onboarding is presenting, queue incoming non-plan deep links instead of
  routing them immediately.
- After onboarding is dismissed, replay the queued routes against the now-ready
  app state, safely (no started work on a half-initialized stack).
- Change the dismissal cleanup so it removes only seeded starter data (tracked/
  identifiable as seeded), leaving real unfinished user workouts intact.

## Acceptance criteria

- [x] A non-plan deep link arriving during onboarding is queued, not routed. *(OnboardingDeepLinkDeferralTests — passing)*
- [x] The queued link is replayed correctly after onboarding dismissal. *(OnboardingDeepLinkDeferralTests FIFO + guard — passing)*
- [x] `clearStarterSlate` deletes seeded starter data only. *(StarterSlateCleanupTests — passing)*
- [x] Real, user-created unfinished workouts survive onboarding dismissal. *(StarterSlateCleanupTests — passing)*

## Required automated tests

- [x] UI/state test: deep link arrives during onboarding → queued → replayed after
      dismissal to the correct scene. *(state-level: OnboardingDeepLinkDeferralTests, passing — no mounted-ContentView UI run)*
- [x] UI/state test: dismissal cleanup preserves a user-created unfinished
      workout while removing seeded data. *(StarterSlateCleanupTests, passing)*

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`): trigger a deep link during onboarding and
      confirm correct post-dismissal landing and no loss of real in-progress
      workouts. *(not executed — no mounted-ContentView deep-link-through-onboarding UI run)*
- [ ] Hardware iPhone: same flow on-device with a real launch-from-link.
      *(not executed — devicectl shows physical devices unavailable)*

## Dependencies

- None new. Independent of FF-001/002/003/005/006; proceeds in Wave C.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-004 | Worker claimed. Implemented deep-link deferral queue + replay and narrowed `clearStarterSlate` to seeded starter data via existing `WorkoutModel.routineID` provenance (no schema change). Tests authored but NOT run (file-edit worker). |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-004 | Manager static-review blockers fixed: (1) `WorkoutFinisher.cancelLiveRuntime()` now runs only when the currently active workout is the seeded starter workout being deleted (`StarterSlatePolicy.cancelsLiveRuntimeForDeletion`); (2) note cleanup narrowed to the fixed seeded note ID (`ForgeFitDemo.machinePressNoteID`) so user-authored pinned notes survive; (3) regression coverage added for both. Tests still authored but NOT run (file-edit worker). Ready for manager review. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-004 | Manager executable review: combined targeted app suite FAILED — `xcodebuild` exit 65, build failed before any tests ran because `ForgeFit/Onboarding/StarterSlateCleanup.swift:49` and `:60` report "no macro named Predicate" (file used `#Predicate` without `import Foundation`). Log: `/tmp/forgefit-wave1-targeted.log`; result bundle: `/tmp/forgefit-wave1-dd.iAR06y/ForgeFitWave1.xcresult`. Fix applied: added the missing `import Foundation` to `StarterSlateCleanup.swift`. Whether the build now succeeds is NOT established — rerun required; this worker cannot claim the failure persists after the edit, and cannot claim a pass. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-004 | Adversarial static review (manager): requested that `cleanupRemovesSeededStarterContentAndPreservesUserWorkInProgress` in `ForgeFitTests/StarterSlateCleanupTests.swift` be made `throws` because "uses bare try several times but its @Test signature is not throws". Worker re-inspected the current checkout: the function ALREADY declares `throws` (line 43) and always has; full-file scan of all five `@Test` functions shows the only two without `throws` (`seededStarterWorkoutPredicateUsesRoutineProvenanceOnly`, `runtimeCancellationTargetsOnlyTheActiveStarterDerivedWorkout`) contain no `try` expressions, so no bare-try compile-shape error exists in the file. The review finding does not reproduce against the current checkout; NO code change was made. No pass claimed; rerun still required. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-004 | Manager execution evidence recorded (no code changes). ALL PASSES: package run `DEVELOPER_DIR beta make -e test` exit 0 (log `/tmp/forgefit-wave1-make-test-final.log`; ForgeCore 400 + ForgeData 87 tests passed plus support builds); targeted iOS 26.5 clean-simulator run exit 0 — 39 tests in 7 suites including all `OnboardingDeepLinkDeferralTests` and `StarterSlateCleanupTests` (log `/tmp/forgefit-wave1-targeted-clean-sim.log`, result bundle `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`); iPhone simulator build exit 0 after an earlier no-space infrastructure failure (log `/tmp/forgefit-wave1-build-ios-rerun.log`); Watch build exit 0 (log `/tmp/forgefit-wave1-build-watch.log`). REMAINING GAPS (unexecuted, recorded honestly): no mounted-ContentView deep-link-through-onboarding UI run and no physical-device runtime; devicectl shows physical devices unavailable. Automated tests prove FIFO deferral policy and selective starter cleanup; the runtime/hardware boxes stay unchecked. |

### Files changed

Production:

- `ForgeFit/Onboarding/OnboardingDeepLinkDeferral.swift` (new) — `DeepLinkDeferralPolicy`
  (defer decision for non-plan `forgefit://` links while onboarding is up;
  replay gate = launch tasks finished AND onboarding dismissed) and
  `PendingDeepLinkQueue` (FIFO defer/drain).
- `ForgeFit/Onboarding/StarterSlateCleanup.swift` (new) — `StarterSlatePolicy`
  (`isSeededStarterWorkout` via `routineID` provenance + no schema change;
  `cancelsLiveRuntimeForDeletion` runtime-cancellation guard) and
  `StarterSlateCleanup` (deletes seeded starter workouts, starter routine, and
  the seeded setup note by fixed ID `ForgeFitDemo.machinePressNoteID`).
- `ForgeFit/ContentView.swift` — `handleDeepLink` defers non-plan links while
  onboarding is presented; `handleOnboardingPresentationChange` replays held
  links on dismissal (slate-cleanup gate unchanged); new
  `replayPendingDeepLinks()` guarded by `canReplay`, re-invoked after launch
  tasks finish in `runLaunchTasksIfNeeded`; `clearStarterSlate()` delegates to
  `StarterSlateCleanup.run` and calls `WorkoutFinisher.cancelLiveRuntime()` only
  when the active workout is the seeded starter workout being deleted.

Tests:

- `ForgeFitTests/OnboardingDeepLinkDeferralTests.swift` (new)
- `ForgeFitTests/StarterSlateCleanupTests.swift` (new)

### Tests requested / run

Worker executed no tests (file-edit-only worker; no shell/build/test
invocation).

Manager executable review — ACTUAL RUN, FAILED (recorded 2026-08-11):

```bash
xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:ForgeFitTests/OnboardingDeepLinkDeferralTests \
  -only-testing:ForgeFitTests/StarterSlateCleanupTests
```

- Result: exit 65; testing cancelled. Build failed before any tests ran.
- Cause: `ForgeFit/Onboarding/StarterSlateCleanup.swift:49` and `:60` —
  "no macro named Predicate" — the file used `#Predicate` without importing
  `Foundation`.
- Log: `/tmp/forgefit-wave1-targeted.log`; result bundle:
  `/tmp/forgefit-wave1-dd.iAR06y/ForgeFitWave1.xcresult`.
- Fix applied: added `import Foundation` to `StarterSlateCleanup.swift`.
- Rerun is required. It is NOT established whether the build now succeeds:
  this worker did not (and cannot) run the suite again, so neither "failure
  persists" nor "passes" is claimed.

Rerun command (same as above), plus `make test` (ForgeData/ForgeCore suites;
`CloudKitCompatTests` is expected unaffected — no schema field or attribute
was added or changed).

Manager execution — ACTUAL RUNS, ALL PASSING (recorded 2026-08-11, manager
executed; worker did not run anything):

1. Package run — `DEVELOPER_DIR beta make -e test` — **exit 0**. Log:
   `/tmp/forgefit-wave1-make-test-final.log`. ForgeCore 400 tests passed and
   ForgeData 87 tests passed, plus support builds. (Covers
   `CloudKitCompatTests` — no schema change, unaffected.)
2. Targeted iOS 26.5 clean-simulator run (the rerun of the previously failed
   command) — **exit 0**, **39 tests in 7 suites**, including ALL
   `OnboardingDeepLinkDeferralTests` and `StarterSlateCleanupTests` tests. Log:
   `/tmp/forgefit-wave1-targeted-clean-sim.log`; result bundle:
   `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`.
3. iPhone simulator app build — **exit 0**. Log:
   `/tmp/forgefit-wave1-build-ios-rerun.log`. (An earlier run failed on a
   no-space infrastructure issue, not a code failure; the rerun passed.)
4. Watch app build — **exit 0**. Log: `/tmp/forgefit-wave1-build-watch.log`.

These automated tests prove the FIFO deferral policy (queued, not routed;
replayed in arrival order after dismissal; idempotent drain; replay guard) and
the selective starter cleanup (seeded starter routine/workouts/note removed;
user-created unfinished workouts and user-authored notes preserved;
runtime-cancellation guard). They do NOT exercise a mounted ContentView
deep-link-through-onboarding UI run or any physical-device flow (devicectl
shows no physical devices available).

### Residual risks

- **Resolved by manager-run evidence:** the earlier `import Foundation` compile
  failure and subsequent rerun — package tests (ForgeCore 400, ForgeData 87)
  and the targeted iOS 26.5 clean-simulator suite (39 tests / 7 suites, exit 0)
  passed, and iPhone simulator + Watch builds succeeded. The adversarial
  static-review `throws` finding was confirmed not to reproduce (function
  already `throws`).
- **Still open — no mounted-ContentView UI run:** automated tests cover the
  deferral/cleanup state machines, but a full deep-link-through-onboarding run
  against the mounted `ContentView` (onOpenURL → dismissal → replay → landing
  scene) was NOT executed on the simulator.
- **Still open — no physical runtime:** no hardware iPhone launch-from-link was
  executed; devicectl reports physical devices unavailable.
- `WorkoutFinisher.cancelLiveRuntime()` sits on the preserved-workout survival
  path only at the policy level; runtime teardown for a starter-derived active
  workout is covered by a policy test but not exercised end-to-end with live
  timers/GPS/HR/Live Activity.
- `forgefit://experiment` replay re-writes `UserDefaults` and re-posts its
  notification on dismissal; double-presentation behavior of the experiment
  route consumer is untested.

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| 2026-08-11 | Manager (executable review) | Changes requested | Combined targeted suite failed: exit 65, "no macro named Predicate" at `StarterSlateCleanup.swift:49`/`:60` (missing `import Foundation`). Log `/tmp/forgefit-wave1-targeted.log`, result bundle `/tmp/forgefit-wave1-dd.iAR06y/ForgeFitWave1.xcresult`. Fix applied by worker; rerun required — no pass claimed. |
| 2026-08-11 | Manager (adversarial static review) | Changes requested (does not reproduce) | Requested a `throws` fix on `cleanupRemovesSeededStarterContentAndPreservesUserWorkInProgress`. Worker re-inspected the current checkout: the function already declares `throws` (line 43); scan of the other four `@Test` functions found no `try` without `throws`. No code change was made. Rerun required — no pass claimed. |

## Definition of Done

- [x] All acceptance criteria checked. *(via passing automated tests: FIFO deferral + selective starter cleanup)*
- [x] Required automated tests added and passing via the named command. *(iOS 26.5 clean-simulator: exit 0, 39 tests / 7 suites)*
- [ ] Required runtime / hardware validation executed and results recorded.
      *(not executed — no mounted-ContentView UI run; devicectl: no physical devices)*
- [x] Worker work log completed (status, owner, files changed, tests,
      residual risks).
- [ ] `Status` moved through Planned → In Progress → In Review → Changes
      Requested / Verified → Done. *(Verified → Done are manager-only, set at sign-off)*

## Final sign-off

> **Done and sign-off are set by the manager alone.** Workers never mark a story
> Done or sign it off.

- **Verified by (technically):**
- **Done set by (manager):**
- **Date:**
- **Release gate:** this story is / is not a blocker for the remediation release.