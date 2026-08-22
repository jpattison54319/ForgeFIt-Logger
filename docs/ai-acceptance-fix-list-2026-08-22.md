# AI acceptance fix list — 2026-08-22

This list reconciles the simulator acceptance run with the product review. It
separates user-confirmed improvements from failures that only prove an
acceptance precondition or fixture did not line up. A failed UI assertion is
not called a product defect until the same behavior is reproduced with a
known-good fixture or on-device.

Evidence baseline: iPhone run `/tmp/forgefit-acceptance/full-run.Q8N2fT`.
The run reported 99 passed, 17 failed, and 2 skipped flows from 118 inventoried
iPhone flows. The original visual judge response also included four findings
about the floating bottom app bar; those are explicitly reclassified below.

## Next product fixes

### P1 — Make Myo weight and rep controls reliably tappable

User-confirmed issue: taps on the Myo increment controls sometimes do not
register.

The acceptance flow found the effective accessibility frame for `Increase
activation weight` below the expected 44×44 point minimum in
`ForgeFitUITests/ForgeFitUITests.swift:727-735`. The production stepper uses a
56×56 visual button in `ForgeFit/Workout/MyoRepWeightStepper.swift`, but the
icon-only control does not currently establish an explicit content shape or
minimum hit region. The reps assertion at lines 744-749 was not reached after
the weight assertion failed.

Fix and verify:

- Give both weight and reps increment/decrement controls an explicit, hittable
  accessibility frame of at least 44×44 points, independent of icon bounds.
- Exercise repeated taps on weight and reps in both kg and lb modes, including
  taps near the edge of the target, and verify every increment is applied once.
- Keep the visible control and the accessible label aligned with the value that
  changed; add a regression assertion for the effective frame and the final
  value.

### P1 — Make saved cardio goals visible on the routine card

User-confirmed issue: after setting a treadmill/cardio goal, the routine card
still says `Add goal` and gives no quick-glance indication of the saved target.

`RoutineEditorView` currently renders the `routine-cardio-goal` action with the
`Add goal` label. The requested state is:

- no persisted goal: `Add goal`;
- persisted goal: `Edit goal` plus a compact summary such as `30 min`, target
  distance/calories, zone, or interval information as applicable;
- the summary must have a clear accessible value and remain visible without
  opening the editor.

The same acceptance flow also opened the goal sheet but could not find the
expected `cardio-goal-minutes` field at
`ForgeFitUITests/ForgeFitUITests.swift:1374-1379`. Verify the sheet renders its
default/current value and, after a goal is saved, hydrates the persisted
`intervalPlanJSON` rather than only changing the card label.

Regression path: create a 30-minute goal, save it, confirm the card changes to
`Edit goal` with a summary, reopen it, edit it, save, and verify the result from
a fresh launch/context.

### P1 — Add a deliberate horizontal-scroll affordance

The Home feeling-chip row needs to communicate that more content exists to the
right. The last word that fits should be intentionally half off-screen (or
otherwise leave a clear trailing peek), optionally supported by a subtle fade
or scroll cue. Do not rely on the user guessing that the row scrolls.

Verify normal and larger text sizes, right-to-left layout if supported, VoiceOver
navigation, and the post-scroll screenshot. Apply the same rule to other rows
only when they are intentionally horizontally scrollable.

### P1 — Reselecting the current tab should scroll its root to the top

This is a requested UX enhancement, not a confirmed current navigation bug.
When the user is already on Home, Workout, Insights, or Profile and has
scrolled down, tapping that selected tab should scroll that tab's root content
to the top. Preserve the existing behavior that switching tabs returns to the
selected tab's root.

Add a per-tab scroll-to-top signal/ownership mechanism and verify each tab after
scrolling. Also retain a deep-navigation test so the new behavior does not
break cross-tab root return.

## Acceptance failures to reproduce before changing product behavior

### P2 — Saved workouts and Recents: distinguish persistence from a test query

Two flows did not establish the same defect:

- `testQuickCardioCanBeSavedToRecents` failed before saving, because
  `start-cardio-row` was not found at line 302. It never reached the Recents
  assertion at line 343.
- `WorkoutHeartsUITests` saved the workout and then failed to find a
  `home-workout-*` element after waiting 10 seconds. There was no save error in
  the log, but the test did not verify the underlying persisted record from a
  fresh model context.

Do not mark “saved workouts disappear from Recents” as a product defect yet.
Make the focused flow wait for the app-ready/root state, capture the
post-save accessibility tree, query persistence from a fresh model context,
then relaunch and verify the Home Recents query. If the record exists but the
accessibility element does not, fix the fixture/query/selector rather than
workout persistence.

### Resolved as an acceptance-fixture issue — exercise history chart

The chart is the progress/trend line chart on the exercise detail screen, not
the workout-history list. The user-visible chart is interactable; the focused
human-like replay now confirms that the earlier empty state came from the
deterministic fixture, not from a chart product failure. The flow is:

`Profile → Exercises → Smith Machine Squat → exercise detail → progress chart`.

The expected accessibility identifier is `exercise-progress-chart`, defined by
`InteractiveLineTrendChart`. The original failure happened before the later
long-press/drag selection because `seedHistoryFixtures()` created raw
weight/reps sets without recomputing the persisted `estimated1RM` values that
the chart series reads. The action screenshot showed the honest empty-state
copy: `Log this exercise across multiple sessions to chart this metric.`

The fixture now recomputes derived metrics for each seeded strength set. Verify
the post-search and post-scroll action screenshots show the actual trend chart,
then exercise the chart selection gesture. Do not file a chart UI bug from an
empty chart when the seeded data contract is missing its derived points.

### Resolved as an acceptance-selector issue — routine editor warm-up ramp

The test creates one squat with 3 initial set-weight rows, taps `Add Warm-up
Ramp`, and expects the default 3-stage ramp to produce 6 total rows. The
human-like action screenshot after the tap visibly showed four rows in the
viewport at that moment: three warm-up rows (`W`, `10`, `6`, `3`) and the
working row. It did not show 12 rows.

The count of 12 came from three accessibility nodes sharing each stable
`routine-set-weight-*` identifier: the weight text field, its `kg` label, and
the load-basis button. The test now counts unique stable row identifiers and
therefore verifies the six-row model contract without treating accessibility
representations as extra visual rows. The production row layout was not
changed.

### P2 — Sleep correction: clarify “delete” and verify relaunch persistence

ForgeFit's sleep-card delete action does not erase an Apple Health sample. The
user path is Home's partial-sleep card → the small question/pencil control →
`Delete`; it marks that night locally as `untracked`, shows `Sleep removed`,
and provides an 8-second Undo. The relevant IDs are
`sleep-integrity-trigger`, `sleep-integrity-delete`, and
`sleep-integrity-undo`.

The relaunch flow deleted the night, relaunched, and still found the trigger at
line 2451. Verify the intended contract first: local exclusion vs actual Health
data deletion. Then use a fresh context and inspect `SleepOverrideStore` state
after relaunch. If local exclusion is intended to persist, fix the repair/seed
interaction or persistence path and assert the excluded state. If it is not
intended to persist, change the test and UI copy so “delete” is not misleading.

### P2 — Wrapped report: verify the presentation after the card tap

The seeded `wrapped-report-available` card existed and the test tapped it, but
the expected `Close report` control did not appear at line 2568. This is a more
direct interaction failure than the missing Home-card preconditions, but it
could still be a presentation timing or accessibility-label mismatch.

Capture the screenshot/tree immediately after the tap, confirm the story is
presented, and make the close action's visible label and accessibility contract
stable.

## Fixture, readiness, and data-contract fixes

These failures occurred before the intended interaction or depended on a
seeded state that did not appear. They should be made diagnostically reliable
before they are used as product verdicts.

### P2 — Add a shared app-ready/root precondition to Home flows

`home-calendar` is present in `HomeView`, and the representative app tour found
it, but the calendar and app-tab flows failed while waiting for that identifier.
The app-tab flow failed before it tested tab behavior. The initial Home route,
fixture state, and accessibility tree need to be captured on failure.

For Home-dependent flows, use an explicit `-initialTab home` where appropriate,
wait for a shared Home/root-ready signal rather than only a fixed timeout, and
save the screenshot plus accessibility tree whenever a required control is
missing. Re-run `testHomeCalendar...`, `testAppBarTabsAlwaysReturnToRoot`, and
the current-tab scroll-to-top tests after this change.

### P2 — Isolate “new user” onboarding state and report the first failure

All three onboarding flows failed at the initial
`onboarding-get-started` assertion in `OnboardingUITests.swift:104`; they did
not reach the setup, health-authorization, or completion steps. This is not
specific evidence that those onboarding steps are broken.

Launch with a clean user-defaults/store state, wait for the onboarding root,
and capture the first screenshot/tree if the welcome button is absent. Then
rerun each path separately and report the first divergent step and observed
labels.

### P2 — Repair seeded Home card and cached-health diagnostics

The partial-sleep card was missing before `SleepTarget` could be tested. The
Home dashboard cache flow also failed to find the seeded `All in range` headline
while other cached cards rendered. For both cases, dump the actual visible
labels and seed payload at the first assertion. Do not infer that the sleep
editor or recovery calculation is broken from a missing seeded card alone.

### P2 — Verify Myo history/prefill fixture separately from tap size

The Myo prefill flow expected the visible `72.5 kg` history suggestion but did
not find it before the control-size checks. Confirm the history seed, unit
conversion, and displayed suggestion from a fresh launch. Keep this separate
from the independently confirmed tap-target issue.

### P2 — Diagnose routine organizer destination fixture

The routine-reordering flow reached the placement action but did not find the
expected `Move to Folder One` destination. Capture the sheet/tree and verify
the seeded folder relationship before changing organizer behavior.

## Coverage follow-ups

The two skipped flows remain coverage gaps rather than product failures:

- `testRoutineStartLogSetCompleteAndShowsSetupNotes` needs a deterministic seed
  hook or an explicitly documented unit-only boundary.
- `testReviewCoachsVersionOpensReviewScreen` needs a launch-argument/test
  hook, or the review screen needs a separate contract test.

## Explicitly removed from the fix list

- The floating bottom app bar overlap is intentional Liquid Glass behavior and
  is not a defect.
- The acceptance run did not prove that ordinary saved workouts fail to appear
  in Recents; one flow failed before saving and the other needs fresh-context
  persistence evidence.
- The app-tab run did not prove that tabs fail to return to root; it failed
  before finding the Home calendar control. The requested reselect-to-top
  behavior is an enhancement.

This follow-up changes the acceptance harness and its DEBUG history fixture;
it does not change user-facing product behavior. The companion visual review
was updated to preserve the Liquid Glass reclassification:
`docs/ai-acceptance-visual-review-2026-08-22.md`.
