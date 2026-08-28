# ForgeFit iOS Performance Standard

This is the required implementation and review standard for launch, Home,
tab navigation, routine management/editing, and live workouts. Read it before
changing any SwiftUI, SwiftData, UIKit bridge, timer, HealthKit, Watch, widget,
or Live Activity path that can execute while the user is interacting.

## Honest target

ForgeFit must remain responsive within the display's current frame budget:

- 120 Hz: 8.33 ms per frame.
- 60 Hz: 16.67 ms per frame.
- Touch feedback and text entry update in the current interaction turn.

`CADisableMinimumFrameDurationOnPhone` must remain `true` in `AppInfo.plist`
so iPhone ProMotion can use rates above 60 Hz. ProMotion is adaptive: iOS may
lower refresh rate for static content, Low Power Mode, thermal pressure, or
other system policy. The release promise is no app-induced hitches, not an
unverifiable claim of constant 120 FPS.

## Render-path rules

`View.body`, row bodies, gesture updates, `updateUIView`, animations, and
focus changes must not perform work proportional to an unbounded user history
or library. Specifically, never place these operations in a render path:

- SwiftData fetches or saves.
- Full-history scans, nested set scans, sorting, grouping, or graph traversal.
- JSON encode/decode, image decode, filesystem access, HealthKit IPC, Watch
  publishing, widget timeline reloads, or Live Activity writes.
- Rebuilding UIKit menus or other object graphs when their inputs did not
  semantically change.

Use `LazyVStack`/`LazyHStack` for potentially long content. Give rows stable
model identity. Keep high-frequency state at the narrowest owning view; a
heart-rate tick, drag location, text draft, or timer tick must not invalidate
the app shell or every exercise card.

Animations must be local to the pixels that animate. Never wrap a tab/root
selection, large query mutation, fetch, save, or destination construction in a
root animation transaction. Respect Reduce Motion.

## Derived data and caching

Compute an expensive projection once per semantic data revision, then give
rows O(1) lookups or immutable presentation values.

A cache key must include every field read by its projection. Count plus newest
timestamp is usually insufficient: an older workout or routine can change
while another row still owns the maximum. Add a regression test that proves:

1. Repeated body-equivalent calls compute once.
2. Every relevant nested edit invalidates.
3. Unrelated UI state does not invalidate.
4. Cached output remains equal to a full reference calculation.

Do not trade correctness for a faster stale cache. If constructing a deep key
is itself expensive, maintain an explicit semantic revision at the mutation
boundary or build a snapshot outside the render path.

## SwiftData and save ownership

Text fields own local draft strings. They commit model values on submit, blur,
or an explicit action; they do not mutate SwiftData or save per keystroke.

The screen owns one coalesced save coordinator. Child rows request a save but
do not create independent debounce tasks. A lazy row disappearing because the
user scrolled is not a persistence boundary and must never synchronously flush.
Pause the debounce while the enclosing scroll view is tracking, interacting,
decelerating, or animating, then require a fresh quiet window after it becomes
idle; a timer expiring is not proof that a frame-sensitive interaction ended.
Flush at true screen/background/minimize/finish boundaries. Cancellation must
prevent a discarded workout or routine from being saved later.

Use incremental arithmetic for a single set edit. Keep a full scan only as a
tested structural fallback for add/delete/reorder or recovery from an unknown
state. After a persistence change, verify durability through a fresh
`ModelContext`; in-memory assertions do not prove a save survived.

Bulk launch seeding and migrations must be version-gated, idempotent, and
no-ops on clean data. Run them in an isolated context when practical. If model
isolation requires the main actor, split work into measured, bounded chunks
and yield between chunks. Never move `PersistentModel` objects across actor or
context boundaries; return immutable `Sendable` values instead.

## Live workout isolation

While a workout is active:

- Keep a stable history snapshot; background query saves must not replace the
  logger's array identity.
- A set edit updates only that set's derived contribution and aggregate delta.
- Scrolling a card off-screen must not save or rebuild workout-wide metrics.
- Rest timers, haptics, and checkmarks publish local UI feedback first.
- Watch, widget, Live Activity, backup, social, enrichment, and analytics work
  is coalesced, throttled, or deferred outside the interaction turn.
- Drag tracking is isolated to the drag/overlay state and avoids per-frame
  parsing, fetching, persistence, and avoidable allocation.

## Launch and navigation

Production must show its first usable frame without waiting for maintenance,
networking, HealthKit refresh, social sync, or full-history analytics. Work
needed for correctness before interaction must be bounded and measured; other
work starts after the first interaction window and is cancellable.

Keep tabs resident only when retained memory is justified, and mount them
lazily. Switching tabs changes screen visibility synchronously; animate the
small tab indicator locally. First selection and repeat selection both require
measurement because initial construction and cached reveal have different
costs.

## Required regression evidence

For a performance change, run and report these as separate evidence states:

- Focused unit tests for semantic invalidation, computation count,
  incremental/full-scan parity, cancellation, and fresh-context durability.
- Full package tests and app-target tests on the pinned release simulator.
- iOS app build and watch build when shared data or workout behavior changed.
- Deterministic UI acceptance for any changed user flow; seed large fixtures
  before the measured interval.
- Release build on a ProMotion iPhone (iPhone 15 Pro Max or comparable), with
  Low Power Mode off and thermal state nominal. Test cold/warm launch, immediate
  Home scroll, first/repeat tab switches, rapid routine typing/reorder, and an
  8-exercise/30-set live workout.
- Instruments evidence using Animation Hitches, SwiftUI, Time Profiler,
  Allocations, SwiftData/File Activity, and signposts around the measured flow.

Use `XCTApplicationLaunchMetric(waitUntilResponsive: true)` for launch and
scrolling/navigation signpost metrics for interaction. Commit device-specific
XCTest baselines only after repeated stable Release measurements. Never use a
simulator pass, successful build/install/launch, average FPS, or subjective
scrolling alone as proof of hitch-free physical-device frame pacing.

## Review gate

Before handoff, recursively inspect affected callers and downstream consumers
for security/privacy, efficiency, scalability, and regression risk:

- Health and private user data remain local and never enter new logs, fixtures,
  snapshots, sync, or backup payloads.
- Work scales linearly once per semantic change, not once per row or frame.
- Memory growth is bounded and caches have explicit invalidation/lifetime.
- Clean data takes the no-op path; legacy repair is idempotent.
- Accessibility, visible controls, Reduce Motion, and existing UX meaning are
  preserved.

State unresolved profiling gaps plainly. A tester trace can confirm a specific
cause; source inspection can only identify and remove structurally unsafe work.
