# FF-014 — Yoga finished-flow resume idempotency

- **ID:** FF-014
- **Title:** Yoga finished-flow resume idempotency
- **Status:** Planned
- **Severity:** P2
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

Relaunching or resuming a yoga flow whose splits already cover every step
re-enters `finishFlow`, which replays the completion audio clip and re-records
guidance history for an already-finished session. The flow uses the guidance
runner's guard state plus the `recordedGuidanceHistory` flag to try to make
finish side effects idempotent, but the resume path reaches `finishFlow`
without that state being durable across a relaunch, so a finished-but-not-
committed session is finished a second time.

## Confirmed trigger

`beginStep` and `beginPausedStep`, when advancing past the final step
(`index >= steps.count`), route to `finishFlow()`. On resume/relaunch of a
flow whose splits already cover every step, this guard is re-hit and
`finishFlow()` runs again: it replays `YogaGuidancePlanner.completionClip`
audio and calls `YogaGuidanceHistory.record(...)` (guarded only by the
in-memory `recordedGuidanceHistory` flag, which is reset on relaunch).

## User impact

Users hear a second completion chime and see guidance-history double-recording
when they reopen or resume a yoga session that was already fully completed but
not yet committed. This inflates guidance history and is jarring across a
relaunch.

## Source evidence

- `ForgeFit/Yoga/YogaFlowRunner.swift`
  - `beginStep(at:announceEntry:)` — `guard index < steps.count else { finishFlow(); return }` (line ~222).
  - `beginPausedStep(at:)` — `guard index < steps.count else { finishFlow(); return }` (line ~240).
  - `finishFlow()` (line ~294) — sets `session.posesCompleted = steps.count`, `try? context.save()`, plays `YogaGuidancePlanner.completionClip(...)`, and calls `YogaGuidanceHistory.record(Array(playedGuidanceIDs))` supervised only by the in-memory `recordedGuidanceHistory` flag.
  - `stop()`/`resume`/`relaunch` paths that restore a partially-run flow from persisted splits.

## Scope

- The yoga flow runner's finish/resume lifecycle in `ForgeFit/Yoga/YogaFlowRunner.swift`, including how a relaunched runner determines whether a session is already fully finished.
- Any UI in `ForgeFit/Yoga/` that constructs a runner from an in-progress session's splits.

## Non-goals

- Not changing `posesCompleted` semantics (that is FF-015).
- Not changing guidance audio content or guidance-history behavior for genuinely fresh flows.
- Not altering commit/finish of the parent workout flow.

## High-level fix direction

Make the terminal/finish transition idempotent and durable: a runner that is
relaunched with splits already covering every step must transition straight to
a finished state without replaying completion audio or re-recording guidance
history. Prefer deriving "finished" from persisted session state (the
splits that cover all steps, or a persisted terminal marker) rather than from
an in-memory flag alone. Add tests around fully-finished-but-uncommitted
sessions across fake relaunch/resume.

## Acceptance criteria

- [ ] Relaunching/resuming a yoga flow whose splits already cover every step does not re-run `finishFlow` completion side effects.
- [ ] Completion audio is played at most once for a given finished session.
- [ ] Guidance history is recorded at most once for a given finished session.
- [ ] A genuinely incomplete flow still finishes normally on its last step.
- [ ] No double `context.save()` or duplicate `posesCompleted` writes for an already-finished session.

## Required automated tests

- Swift Testing suite driving `YogaFlowRunner` (or its extracted finish state) through a fake relaunch where all splits are already recorded.
- Assert completion audio and guidance-history record each fire exactly once.
- Assert an incomplete session still completes on the final step.

## Required runtime/hardware validation

- Manual: run a short yoga flow to completion, kill the app before commit, relaunch and reopen the session; confirm no second completion chime and no duplicate guidance-history.

## Dependencies

- None blocking. Verify any shared `YogaGuidanceHistory`/`YogaGuidancePlanner` helpers are safe to call from the chosen fixed path.

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- Acceptance criteria above all satisfied with automated tests green.
- Completion audio and guidance-history effects proven idempotent across relaunch.
- No changes outside the yoga finish/resume path.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_