# FF-012 — Deferred HealthKit fills can resume after reset deletes their models

- **Status:** In Review
- **Severity:** P2
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

Deferred HealthKit fills capture SwiftData models and can resume after an
account reset hard-deletes those models. A background/finisher task holding a
reference to a now-deleted model can resume and mutate stale state, racing the
reset's soft/hard delete.

## Confirmed trigger

A workout finisher defers a HealthKit fill that captures SwiftData model
references. An account reset (which soft- or hard-deletes models) runs before
the deferred fill resumes. The resumed task then operates on deleted/stale
models, causing a race and potential mutation of deleted data.

## User impact

After a reset, stale deferred tasks can resurrect or mutate deleted models,
leaving inconsistent state. The user may see data re-appear after confirming a
reset.

## Source evidence

Repository-relative paths and symbols:

- Workout finisher deferred HealthKit fill — captures SwiftData models into
  background tasks.
- Reset hard-delete path — deletes those models.
- Deferred task resume logic — has no lifetime guard.

## Scope

- Deferred HealthKit fill task lifecycle and model capture.
- Reset soft/hard-delete interaction with in-flight deferred tasks.

## Non-goals

- No change to the reset confirmation semantics.

## High-level fix direction

- Track and cancel deferred tasks on reset, or capture IDs/value snapshots and
  refetch before mutation so the task never holds a raw model reference across
  a delete.
- Handle reset/soft-delete races and container lifetime with tests.

## Acceptance criteria

- [ ] Deferred fills no longer capture raw models that survive a reset.
- [ ] Tasks are either cancelled on reset or refetch models by ID before
      mutation (with a staleness guard).
- [ ] No deferred fill can mutate a deleted/stale model after reset.
- [ ] Reset/soft-delete race and container-lifetime tests pass.

## Required automated tests

- Deferred fill resumes after reset → does not mutate deleted models.
- Cancel-on-reset path cancels in-flight deferred fills.
- Refetch-by-ID path detects and abandons stale/deleted models.
- Soft-delete race test.

## Required runtime/hardware validation

- Manual watch run: start workout with deferred HealthKit fill, trigger reset
  while a fill is deferred, confirm no stale data reappears.

## Dependencies

- Workout finisher deferred task infrastructure.
- Reset soft/hard-delete semantics.

## Worker work log

_Workers: update Status, Owner, work log, files changed, tests
requested/run, and residual risks. The manager alone sets Done and signs off._

- (empty — no work claimed)

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
