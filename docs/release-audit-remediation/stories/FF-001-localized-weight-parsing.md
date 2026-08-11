# FF-001 — Localized Weight Parsing

**Status:** Planned
**Severity:** P1
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

Weight input typed by the user is not parsed in a locale-safe, deterministic
way. Numeric parsing that naively strips commas misreads the decimal comma used
in many locales, so a legitimate fractional weight is corrupted to a much larger
integer.

## Confirmed trigger

- Set the device region to a locale that uses the comma as the decimal separator
  (for example `de_DE`).
- Type `72,5` into the strength-logging weight field (runner fast set entry) or
  into the quick-increment weight control.
- The entered value is stored/displayed as `725` instead of `72.5`.

## User impact

Strength weight logged or incremented is off by 100× whenever a decimal comma is
used. The athlete silently records the wrong load, which corrupts tonnage,
volume, and estimated 1RM, and can persist to CloudKit and HealthKit workouts.
Because weights are never auto-converted for display, the stored `725` is shown
as-is, and is very hard for the user to notice and correct.

## Source evidence

- `Fmt.loadKilograms` — the shared formatter/parser used by strength logging and
  quick increment. It strips the comma character as grouping noise instead of
  recognizing a decimal comma, per the audit.
- Strength logging runner weight field + quick-increment weight control call
  this parser, so both entry paths inherit the corruption.

## Scope

- In scope: the shared weight parser and both calling entry paths (runner fast
  set entry, quick increment), plus their tests.
- Out of scope: changing how weights are stored or displayed, or any kg↔lb
  conversion.

## Non-goals

- Not converting between display units (kg vs lb) anywhere — the invariant that
  "stored/display weight is already in the selected display unit" is preserved.
- Not redesigning the weight entry UI.
- Not changing the formatting output of `Fmt`, only its input parsing.

## High-level fix direction

Replace the comma-stripping parse with a locale-aware, deterministic parser that:
- accepts a decimal comma and a decimal point interchangeably as the decimal
  separator for a single fractional value,
- still honors valid digit-grouping separators so `1,000` stays `1000` and does
  not become `1.000`,
- produces the same numeric result regardless of device region (no dependence on
  the ambient `Locale.current` for the core identity),
- is unit-agnostic: it returns the numeric value only; display-unit selection
  remains untouched.

The parser must live in the shared formatting layer so both entry paths converge
on one code path. Wire it behind the existing `Fmt` entry points used by strength
logging and quick increment.

## Acceptance criteria

- [ ] `72,5` (decimal comma) parses and stores/display as `72.5` in the selected
      display unit.
- [ ] `72.5` (decimal point) parses to the same `72.5`.
- [ ] `1,000` (digit grouping) still parses to `1000`, not a fractional value.
- [ ] Stored/display weight remains in the user's selected display unit — no
      kg↔lb conversion introduced.
- [ ] Parser yields identical results across representative decimal-comma and
      decimal-point locales.

## Required automated tests

- [ ] Targeted parser tests for decimal comma, decimal point, grouping, and edge
      inputs, pinned to multiple locales (ForgeCore package tests).
- [ ] Live-logger test: entering `72,5` in the runner weight field persists
      `72.5` (app-target or UI test as appropriate).

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`) with a decimal-comma region: strength logging
      and quick increment both record the correct weight for typed `72,5`.
- [ ] Hardware iPhone with the same region: same checks pass on-device.

## Dependencies

- None. Independent of FF-002 through FF-006; proceeds in Wave B.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |

### Files changed

- (pending)

### Tests requested / run

- (pending)

### Residual risks

- (pending)

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| — | — | — | — |

## Definition of Done

- [ ] All acceptance criteria checked.
- [ ] Required automated tests added and passing via the named command.
- [ ] Required runtime / hardware validation executed and results recorded.
- [ ] Worker work log completed (status, owner, files changed, tests,
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