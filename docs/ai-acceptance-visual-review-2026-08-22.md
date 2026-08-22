# AI acceptance visual review — 2026-08-22

This is the manual/AI-style review of the final simulator evidence. It is
intentionally separate from XCTest status: a test can pass functionally and
still produce a visual suspect.

## Evidence reviewed

- iPhone: `/tmp/forgefit-acceptance/full-run.Q8N2fT`
  - 118 source-inventoried flows: 99 passed, 17 failed, 2 skipped.
  - 55 exported screenshots across 25 flows.
  - 4 deterministic scenario checkpoint manifests.
- Watch: `/tmp/forgefit-acceptance/watch-run.WWzeEj`
  - 4 source-inventoried flows: 4 passed.
  - 7 exported screenshots across 3 flows.
  - 5 deterministic scenario checkpoint artifacts.
- AI review reports: `full-run.Q8N2fT/report-with-judge.md` and
  `watch-run.WWzeEj/report-with-judge.md`.

## Findings

### Reclassified — floating Liquid Glass app bar is intentional

The bottom app bar is intentionally a floating Liquid Glass surface. Its
visual overlap with the lower Home, Workout, Insights, and Profile content is
not a product failure, so the four original chrome-overlap findings are
removed from the fix list. No shared bottom-inset change should be made from
these screenshots.

### Product fix — horizontal chips need a visible scroll affordance

The Home feeling-chip row runs past the right edge without making the
horizontal-scroll affordance obvious in the captured state. The requested
behavior is a deliberate trailing peek: the last word that can fit should be
partially off-screen, with an optional subtle fade/scroll cue. Apply the same
contract to other intentionally horizontal rows only where they share this
interaction pattern.

Acceptance criteria: the row remains scrollable, preserves a minimum trailing
peek at normal text size, does not make the visible label unreadable, and
remains usable with VoiceOver and larger text. Add a screenshot after
horizontal scrolling.

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
