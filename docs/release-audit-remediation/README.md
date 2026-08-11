# Release Audit Remediation — Master Board

> Master board and operating rules for the 2026-08-10 release audit remediation.
> This is a **documentation-only** space: no production code, tests, docs, or git
> state is edited here beyond these Markdown files. One row per story, FF-001
> through FF-020. Each story lives in `stories/FF-###-*.md` and is independently
> trackable.

---

## Severity definitions

- **P1** — Data corruption or wrong-data risk, or an action that can run against
  the wrong entity across a boundary (Watch/phone, session/DB). Blocks release.
- **P1-risk** — High likelihood an adjacent code path can turn a P1 into reality
  under realistic user behavior; treated as a P1 for release gating.
- **P2** — Significant correctness or UX defect but bounded corruption; should
  ship this cycle.
- **P3** — Polish / low impact, and therefore lower priority and later in the
  sequence, but still **mandatory before this release** — it does not slide.

## Workflow states

| State | Meaning | Set by |
|-------|---------|--------|
| Planned | Filed, not started. | Manager (on filing) |
| In Progress | A worker owns it and is editing implementation/tests. | Worker |
| In Review | Implementation + tests submitted for review. | Worker |
| Changes Requested | Review found defects; back to worker. | Reviewer |
| Verified | Technically verified (tests + runtime evidence recorded). | Reviewer |
| Done | All Definition of Done items met; closed by manager. | **Manager only** |
| Blocked | Cannot proceed (dependency, schema decision, hardware). | Worker / Manager |

> **Rule:** Workers update `Status`, `Owner`, work log, files changed, tests
> requested/run, and residual risks. **Only the manager sets `Done` and signs off.**

## Update protocol

1. Workers claim a story by setting `Owner` and moving `Status` to `In Progress`,
   and record the claim in the work log. One owner per story at a time.
2. On each step, edit the story file's status line, add a dated work-log row, and
   keep `Files changed`, `Tests requested / run`, and `Residual risks` current.
3. When implementation and tests are done, set `Status: In Review` and add a
   reviewer log invitation. A reviewer then explicitly and independently
   verifies evidence.
4. Reviewer moves the story to `Verified` only with concrete checked evidence:
   a named test passing and named runtime/hardware validation recorded. Anything
   less is `Changes Requested` with the gap documented.
5. **Manager alone** moves `Verified` → `Done`, clears `Owner`, and signs the
   `Final sign-off` block. No worker may mark `Done` or sign off.

## Evidence boundaries

Evidence must be collected, and recorded, separately at each layer. A result
from one layer never substitutes for another.

| Layer | Evidence required | How recorded |
|-------|-------------------|--------------|
| **Source review** | Static reading of code, no execution. | Reviewer log / work log note "source review only". |
| **Tests** | `make test` (ForgeCore/ForgeData) and/or named `xcodebuild test` suite, capturing exit code from a log file (per AGENTS.md). | Log file path + `** TEST SUCCEEDED/FAILED **` + exit code. |
| **Simulator** | App/watch behavior on a pinned release OS simulator (`OS=26.5`), name-based iOS or UDID-based watch. | Simulation description + simulator name/OS. |
| **Hardware** | Real iPhone + Apple Watch run of the affected flow. | Device models + OS + observed result. |
| **Archive** | `make build-ios` / `make build-watch` succeed. | Command + exit code. |
| **Upload** | App Store Connect upload (xcodebuild archive + export/altool) succeeds. | Upload id + tool exit code. |
| **Processing** | App Store Connect processing of the uploaded build completes. | ASC build processing status. |
| **App Review** | Release / TestFlight build passes App Review for the changed platform. | Review decision + notes. |

> These boundaries exist so "unit test passes" is never mistaken for "works on a
> real watch". A story's Definition of Done only needs the layers its acceptance
> criteria actually implicate; the board rows track all rows that were run.

## Conflict-safe implementation waves

Stories touching the same area must not edit the same production file
concurrently. Wave assignments (a story may not start until its predecessors
have landed). Shared-file areas are explicitly sequenced below.

- **Wave A — watch & wire contract:** FF-002 → FF-003, FF-010, FF-016. **FF-002
  lands first** because it changes the wire contract FF-003 depends on; FF-002
  and FF-016 can both touch `WatchLink`, so FF-016 runs only after FF-002.
  FF-003 (engine workout identity) and FF-010 (watch route recovery) follow
  FF-002.
- **Wave B — strength parsing & idempotent finish:** FF-001, FF-006 → FF-012.
  FF-001 and FF-006 are file-independent and may run in parallel; **FF-006
  lands before FF-012** (deferred HealthKit fills).
- **Wave C — routing/lifecycle:** FF-004 (onboarding + deep-link), FF-005 (outdoor
  completion). Independent files; may proceed in parallel and alongside other
  waves.
- **Wave D — backup/restore:** FF-007 (backup deletion), FF-008 (restore
  rollback), FF-018 (rotation atomicity), FF-019 (allowed-key test guard), FF-020
  (release boundary). **FF-007 lands before FF-018 and FF-020.**
- **Wave E — health:** FF-009 → FF-011. Both touch `HealthService`, so **FF-009
  (aggregation performance) lands before FF-011** (authorization recovery).
- **Wave F — yoga:** FF-013 → FF-014, FF-015. **FF-013 (partial-hold completion)
  lands before FF-014** (finished-flow resume idempotency) and **FF-015**
  (pose-count semantics).

Hard rule everywhere: no two `In Progress` stories may modify the same
production file. Before claiming, a worker must confirm no `In Progress`
story has listed that file in its `Files changed`. The wave order above is the
minimum sequencing; the hard rule may further serialize within a wave.

## Release Definition of Done

The remediation release may ship only when:

- [ ] **Every** story FF-001 … FF-020 is `Done` (manager-set). P3 means lower
      priority and later in the sequence — **not** deferrable past this release.
- [ ] Each `Done` is signed by the manager in the story file's `Final sign-off`
      block; no worker marks a story Done.
- [ ] Each story's `Definition of Done` checklist is checked and its `Final sign-off` block is signed.
- [ ] Evidence boundaries for each Release block applicable to the changed platforms are recorded (tests, simulator, hardware, archive, upload, processing, App Review).
- [ ] Master board rows below reflect the true final status — no row marked Done without a signed story file.

> Nothing in this file claims any defect is fixed. "Done" is a future state set
> by the manager after workers record verified evidence; as of 2026-08-10 all
> stories are `Planned` and `Owner: Unassigned`.

---

## Board

Legend — `Deps`: upstream story/WA (blocking), `Own`: current owner, `Impl
commit`: commit that implements, `Targeted`: targeted test command, `Full`:
full-suite test result, `Runtime`: runtime/hardware validation result, `Rev`:
reviewer sign-off.

| ID | Title | Sev | Status | Deps | Own | Impl commit | Targeted | Full | Runtime | Rev |
|----|-------|-----|--------|------|-----|-------------|----------|------|---------|-----|
| FF-001 | [Localized weight parsing](stories/FF-001-localized-weight-parsing.md) | P1 | Planned | — | Unassigned | — | ForgeCore parser + live-logger tests | — | — | — |
| FF-002 | [Watch terminal command identity](stories/FF-002-watch-terminal-command-identity.md) | P1 | Planned | — | Unassigned | — | Protocol + handler tests | — | — | — |
| FF-003 | [Watch engine workout identity](stories/FF-003-watch-engine-workout-identity.md) | P1 | Planned | FF-002 | Unassigned | — | Recovery/context tests + A-to-B hardware | — | — | — |
| FF-004 | [Onboarding deep-link deferral](stories/FF-004-onboarding-deep-link-deferral.md) | P1 | Planned | — | Unassigned | — | UI/state tests | — | — | — |
| FF-005 | [Outdoor interval split preservation](stories/FF-005-outdoor-interval-split-preservation.md) | P1 | Planned | — | Unassigned | — | Completion routes + history tests | — | — | — |
| FF-006 | [Workout finish idempotency](stories/FF-006-workout-finish-idempotency.md) | P1-risk | Planned | — | Unassigned | — | exactly-once HealthKit/Watch/XP tests | — | — | — |
| FF-007 | [Reset backup deletion can fail silently](stories/FF-007-reset-backup-deletion.md) | P1 | Planned | — | Unassigned | — | — | — | — | — |
| FF-008 | [Backup restore lacks rollback](stories/FF-008-restore-rollback-atomicity.md) | P1 | Planned | — | Unassigned | — | — | — | — | — |
| FF-009 | [Long-range health aggregation performance risk](stories/FF-009-long-range-health-aggregation-performance.md) | P1 | Planned | — | Unassigned | — | — | — | — | — |
| FF-010 | [Recovered outdoor session doesn't restart route collection](stories/FF-010-watch-route-recovery.md) | P2 | Planned | FF-002 | Unassigned | — | — | — | — | — |
| FF-011 | [Health authorization denial/stalled requests no-op silently](stories/FF-011-health-authorization-recovery.md) | P2 | Planned | FF-009 | Unassigned | — | — | — | — | — |
| FF-012 | [Deferred HealthKit fills resume after reset](stories/FF-012-workout-finisher-deferred-lifetime.md) | P2 | Planned | FF-006 | Unassigned | — | — | — | — | — |
| FF-013 | [Completing mid-yoga-hold doesn't record partial hold](stories/FF-013-yoga-partial-hold-completion.md) | P2 | Planned | — | Unassigned | — | — | — | — | — |
| FF-014 | [Yoga finished-flow resume idempotency](stories/FF-014-yoga-finished-resume-idempotency.md) | P2 | Planned | FF-013 | Unassigned | — | — | — | — | — |
| FF-015 | [Yoga pose-count semantics](stories/FF-015-yoga-pose-count-semantics.md) | P2 | Planned | FF-013 | Unassigned | — | — | — | — | — |
| FF-016 | [Superset drop-set round indexing](stories/FF-016-superset-drop-round-indexing.md) | P2 | Planned | FF-002 | Unassigned | — | — | — | — | — |
| FF-017 | [Relative history filter midnight invalidation](stories/FF-017-relative-history-midnight-invalidation.md) | P3 | Planned | — | Unassigned | — | — | — | — | — |
| FF-018 | [Backup rotation atomicity](stories/FF-018-backup-rotation-atomicity.md) | P3 | Planned | FF-007 | Unassigned | — | — | — | — | — |
| FF-019 | [Backup allowed-key coverage (test integrity)](stories/FF-019-backup-allowed-key-coverage.md) | P3 | Planned | — | Unassigned | — | — | — | — | — |
| FF-020 | [Automatic backup release boundary](stories/FF-020-automatic-backup-release-boundary.md) | P1 | Planned | FF-007 | Unassigned | — | — | — | — | — |