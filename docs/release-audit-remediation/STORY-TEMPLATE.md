# Release Audit Remediation — Story Template

> Copy this template for each new remediation story under
> `docs/release-audit-remediation/stories/`. File name convention:
> `FF-###-kebab-case-title.md`. Each story is independently trackable.

---

# FF-### — Story Title

**Status:** Planned
**Severity:** P1 / P2 / P3
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

> What is wrong, stated plainly.

## Confirmed trigger

> The exact sequence of actions that produces the defect.

## User impact

> What a real user loses or experiences because of the defect.

## Source evidence

> Repository-relative paths and symbols (`Type`, `function`, `file:line`) that pin
> the defect to concrete code. Do not edit production code, tests, or docs to
> manufacture evidence — cite only what exists at audit time.

## Scope

- In scope:
- Out of scope:

## Non-goals

> What this story explicitly will NOT do, even though it may seem adjacent.

## High-level fix direction

> Intended shape of the change. Design intent only — no implementation commit here.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Required automated tests

- [ ] Test 1 (target: `ForgeCore` / `ForgeData` / app / watch / UI)
- [ ] Test 2

## Required runtime / hardware validation

- [ ] Simulator validation
- [ ] Hardware validation

## Dependencies

- None / upstream stories / schema decisions pending manager approval.

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