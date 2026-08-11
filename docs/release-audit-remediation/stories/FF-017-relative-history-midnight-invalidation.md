# FF-017 — Relative history filter midnight invalidation

- **ID:** FF-017
- **Title:** Relative history filter midnight invalidation
- **Status:** Planned
- **Severity:** P3
- **Owner:** Unassigned
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

- (empty — planned only; no work performed)

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