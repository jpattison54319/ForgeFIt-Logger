# AI acceptance visual review — 2026-08-22

This is the manual/AI-style review of the final simulator evidence. It is
intentionally separate from XCTest status: a test can pass functionally and
still produce a visual suspect.

## Evidence reviewed

- Historical iPhone baseline: 118 source-inventoried flows: 99 passed, 17
  failed, 2 skipped. Its temporary bundle was cleaned after storage pressure.
- Current iPhone action evidence:
  `/tmp/forgefit-acceptance/ios-focused-current/judge-request.json`
  - 6 complete deterministic action sequences and 79 ordered checkpoints.
- Watch: `/tmp/forgefit-acceptance/watch-run.ndLkwv`
  - five UI tests passed; action-level evidence was regenerated for the
    current run.

Additional release/1.2 targeted visual evidence was captured for the Myo
stepper, cardio-goal card, check-in-chip row, and tab reselect behavior under
`/tmp/forgefit-acceptance/action-evidence`.

## Corrective action-level replay

The two disputed iPhone flows were rerun with a screenshot and accessibility
tree after every user action:

- `testExerciseHistoryRowOpensCompletedWorkout`: 9 ordered checkpoints. The
  detail screen initially showed the honest empty state while launch seeding
  was still becoming observable; after the explicit chart-readiness wait, the
  next screenshot showed the full trend line, and the following two showed
  the long-press tooltip and drag-selected point. The chart interaction is
  therefore not a product failure.
- `testRoutineEditorMenuParityAndSharedSupersetIdentity`: 18 ordered
  checkpoints. The post-`Add Warm-up Ramp` screenshot showed three `W` rows
  followed by one working row in the viewport. The earlier count of 12 was
  three accessibility nodes per visible weight control, not 12 rendered rows.

The Watch active-workout replay also produced 8 post-action checkpoints and
confirmed a simulator visual concern: the set-list exercise title is clipped
behind the top REST/navigation chrome. This remains a Watch layout suspect,
separate from the iPhone chart and warm-up findings and from the physical-face
validation boundary.

The current focused iPhone judge request is
`/tmp/forgefit-acceptance/ios-focused-current/judge-request.json`; its six
action sequences are complete and contain 79 ordered checkpoints. The current
Watch run is `/tmp/forgefit-acceptance/watch-run.ndLkwv`, where all five UI
tests passed and the action-level Watch evidence was regenerated.

The interrupted full matrix also exposed a separate reliability suspect in
the seeded active logger: after the upward scroll action, the app process held
roughly 99% CPU and stopped servicing the main run loop. XCUITest recorded the
pre-swipe logger state, then failed to obtain a post-swipe snapshot. This is a
behavioral/performance finding, not a visual pass or a selector-only failure;
it belongs on the fix list until reproduced with a main-thread sample.

## Findings

### Reclassified — floating Liquid Glass app bar is intentional

The bottom app bar is intentionally a floating Liquid Glass surface. Its
visual overlap with the lower Home, Workout, Insights, and Profile content is
not a product failure, so the four original chrome-overlap findings are
removed from the fix list. No shared bottom-inset change should be made from
these screenshots.

### Verified product fix — horizontal chips have a visible scroll affordance

The release/1.2 replay shows the Home feeling-chip row running past the right
edge with a deliberate trailing peek and a subtle fade. The row remains
scrollable, and the cut chip becomes fully reachable after the swipe.

The captured default-size screenshots preserve the visible label and the
post-scroll state. Larger text, RTL, and VoiceOver-specific review remain
follow-up coverage.

### Verified product fix — Myo stepper touch targets

The release/1.2 screenshots show 56×56 weight and rep tiles with the icon,
background, and tappable region aligned. Edge-tap UI tests confirmed all four
controls meet the 44×44 minimum and apply kg/lb and rep increments once.

### Verified product fix — saved cardio goal presentation

The saved routine screenshot visibly changes the action from `Add goal` to
`Edit goal` and places `30min goal` directly below it. The detail screenshot
also shows the 30-minute goal at a glance; the replay then reopened the editor
and verified the persisted field was hydrated.

### Verified product fix — reselecting the current tab

The replay screenshots show Home and Profile back at their root headers after
the selected tab is tapped again. The companion preservation test confirms
that switching away and back does not reset scroll position.

### Major suspect — Watch set-list title truncates at the viewport edge

On the Apple Watch simulator, the final set-list screen shows only the tail of
the seeded `Barbell Bench Press` title under the top navigation/REST chrome.
The exercise page itself is readable, so this appears specific to the set-list
title layout.

Recommended action: constrain the title with an intentional ellipsis or
adaptive font/layout that leaves the back control and REST banner clear; review
40/41/45/49 mm widths and Dynamic Type.

### Minor suspect — long exercise names lose context in workout chrome

The iPhone logger and active-workout relay shorten names such as “Barbell Bench
Press - Medium Grip” and “Incline Dumbbell Press.” Some truncation is expected
in compact controls, but the user needs enough identity to distinguish
exercises while logging.

Recommended action: preserve the exercise name in the expanded card/detail and
use a predictable, accessible full label for the compact representation.

### Source-linked AI review outcome

The original iPhone judge response contained five findings: four chrome-overlap
findings and one chip-clipping/accessibility finding. User review reclassified
the four Liquid Glass findings as intentional and retained the chip behavior as
a product fix. The Watch response contains one major set-list finding and one
minor accessible-identity finding; those remain separate from the iPhone fix
list until the Watch layout is reviewed across device sizes and the physical
Watch boundary is exercised.

## What is not a confirmed defect from these screenshots

The dark theme, primary hierarchy, contrast, onboarding flow, recovery/sleep
cards, theme gallery, typed decimal state, and standard logger controls were
visually coherent in the reviewed captures. Simulator screenshots do not prove
physical iPhone rendering, HealthKit permission behavior, WatchConnectivity,
App Group delivery, WidgetKit timeline scheduling, or the complication rendered
on a physical Watch face.
