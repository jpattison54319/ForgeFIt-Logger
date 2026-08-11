# FF-017 — Relative history filter midnight invalidation

- **ID:** FF-017
- **Title:** Relative history filter midnight invalidation
- **Status:** In Review
- **Severity:** P3
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

The WorkoutHistory relative filter's memo key omits the current calendar day.
Because the memo key only includes the query's static components and the
history fingerprint, a 7/30/90-day (and this-year) window is computed against
a stale `Date()` and stays frozen across midnight until the fingerprint or
query changes.

## Confirmed trigger

`ForgeFit/Profile/WorkoutHistoryView.swift` builds the memo key (line ~35) as
`fingerprint|searchText|kind|date.title|muscle|exercise|source|prsOnly|sort`.
`WorkoutHistoryQueryEngine.apply(_:to:now:calendar:)` defaults `now = Date()`
and `WorkoutHistoryQuery.DateFilter.trailing(days:now:)` computes the window
from that single `now`. If the user leaves the History screen open across
midnight with a relative filter set, the memoized result keeps using the prior
day's window because nothing in the key changes.

## User impact

The 7/30/90-day (and This year) History counts/list stay stale overnight;
workouts from the newest day (and the boundaries between windows) are
misreported until the user changes a filter or re-enters the screen. Users with
the History screen open see stale relative windows across midnight; daily
boundary dates are miscounted (duplicated or missing) in 7/30/90-day filters.

## Source evidence

- `ForgeFit/Profile/WorkoutHistoryView.swift` — `filtered` memo key (line ~35) and `Memo<String, [WorkoutHistoryEntry]>` (`filteredMemo`, line ~26).
- `ForgeFit/Profile/WorkoutHistorySearch.swift` —
  - `WorkoutHistoryQueryEngine.apply(_:to:now:calendar:)` default `now = Date()` (lines ~453–462).
  - `WorkoutHistoryQuery.DateFilter.interval(now:calendar:)` and `trailing(days:now:calendar:)` (lines ~366–394).

## Scope

- The relative-date memoization in `ForgeFit/Profile/WorkoutHistoryView.swift` and its interaction with `WorkoutHistoryQueryEngine.apply`.

## Non-goals

- Not disabling memoization generally; only making it day-aware.
- Not changing the meaning of the relative windows themselves.

## High-level fix direction

Make the memo key day-aware for relative date filters without turning off the
useful memoization — e.g. include `calendar.startOfDay(for: now)` (or the
computed window interval) in the key only when `query.date` is relative
(`last7Days`/`last30Days`/`last90Days`/`thisYear`), leaving static filters
unaffected. Use an injected clock (`now`)/calendar so the behavior is
deterministically testable across a simulated midnight transition.

## Acceptance criteria

- [ ] The relative filter recomputes after the calendar day changes while the view stays alive.
- [ ] Static filters keep their memoization unchanged.
- [ ] No recompute on unrelated interactions that change nothing (still memoized within a day).
- [ ] 7/30/90-day and This year windows include/exclude workouts at the new day boundary correctly.

## Required automated tests

- Injected-clock test simulating a view living across midnight: assert the filtered result changes to reflect the new day without any query/fingerprint change.
- Test asserting static filters still hit the memo within a day.

## Required runtime/hardware validation

- Manual: open History with Last 7 days, change the system clock past midnight (or wait), confirm the count updates on its own.

## Dependencies

- None blocking.

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- 2026-08-11 — DeepSeek V4 Flash 0731 — FF-017: Claimed (Planned → In Progress) and
  implemented over two sessions. Day-aware relative-filter memoization behind an
  injected now/calendar policy plus a real midnight state tick in the view. Tests are
  authored but were NOT executed (file-edits-only sessions: no shell/test/build/git).
  Not verified; not Done — awaiting review.

  Files changed:

  - `ForgeFit/Profile/WorkoutHistorySearch.swift` — added
    `WorkoutHistoryQuery.DateFilter.isRelativeToNow` (true only for
    last7Days/last30Days/last90Days/thisYear),
    `WorkoutHistoryQueryEngine.memoKey(fingerprint:query:now:calendar:)` (appends
    `calendar.startOfDay(for: now)` to the memo key ONLY for relative filters;
    `all`/`month`/`custom` keep the byte-identical legacy key, so static memoization
    never churns), and
    `WorkoutHistoryQueryEngine.nextDayBoundary(after:calendar:)` (calendar-anchored
    next local midnight, DST/timezone-correct, for the tick).
  - `ForgeFit/Profile/WorkoutHistoryView.swift` — `filtered` now keys the memo via
    `memoKey` and runs the engine with the SAME injected `now` (`@State`) and
    `Calendar.autoupdatingCurrent`, so key and value share one instant. A
    cancellation-safe `.task` loop sleeps to the exact next local midnight
    (re-anchoring each iteration, checking `Task.isCancelled` before every sleep and
    after it — no post-cancel write, no rescheduled sleep) and refreshes `now`,
    re-running the body so the day-aware key is re-derived AT the boundary. A second
    `.onChange(of: scenePhase)` handler refreshes `now` on every return to `.active`,
    covering a midnight, timezone, or clock change that happened while the app was
    suspended.
  - `ForgeFitTests/WorkoutHistorySearchTests.swift` — new "Relative-window memo
    policy (FF-017)" section with 9 deterministic, injected-clock tests: relative
    memo keys shift at midnight but not within a day (all four relative filters);
    static keys are clock-independent (all/month/custom); next-local-midnight;
    nextDayBoundary across the US DST fall-back; relative filter recomputes across
    midnight with zero query/fingerprint change (via a `Memo` mirroring the view);
    static custom filter memo holds across body re-evaluations AND midnight (one
    compute); relative filter stays memoized within a calendar day; 30/90-day window
    boundary include/exclude semantics; this-year window across the year boundary.

  Tests explicitly NOT run (cannot claim green): the entire
  `ForgeFitTests/WorkoutHistorySearchTests` suite (9 new + existing) — no
  shell/test/build was permitted in these sessions. Run it on a simulator pinned to
  OS=26.5 (see AGENTS.md) before review.

  Residual timezone/DST risks (accepted, behavioral):
  - The tick re-anchors to `Calendar.autoupdatingCurrent` each iteration, but the
    sleep itself is a fixed-duration `Task.sleep`; after a fall-back DST transition
    the next wake can land up to ~23h after the boundary (the following midnight
    re-syncs it).
  - A timezone change while the user stays in the foreground is only reflected at
    the next body re-evaluation (autoupdatingCurrent is read live; the scenePhase
    refresh only runs when the app re-activates).
  - A manual clock change while remaining in the foreground waits for the next
    scheduled wake (up to ~24h worst case); on return from background it is caught
    immediately by the scenePhase handler.
  - The four relative windows deliberately keep the pre-fix `[now − N days, now]`
    semantics — changing window meaning was an explicit non-goal.

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- Relative windows stay correct across midnight with memoization intact.
- Acceptance criteria met with automated tests green.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_
