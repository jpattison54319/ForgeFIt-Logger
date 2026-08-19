# FF-003 — Watch Engine Workout Identity

**Status:** In Review
**Severity:** P1
**Owner:** DeepSeek V4 Flash 0731 — FF-003
**Source audit date:** 2026-08-10

## Problem

The Watch workout engine's active session is not bound to a specific workout
identity. During recovery, a stale active snapshot can be resumed under a newer
workout context, so a recovered workout A can stream live data labeled as
workout B.

## Confirmed trigger

- Workout A is active on the Watch and the engine is interrupted/recovered
  (e.g. app relaunch or glacial WCSession state while a mirror is being rebuilt).
- A newer phone workout B is either started or its snapshot is selected as the
  current context.
- The engine resumes/starts streaming under snapshot B while still carrying
  session/workout A's identity — data for A is attributed to B.

## User impact

Heart rate, distance, and activity for workout A can be attributed to workout B,
corrupting both HealthKit workouts and the on-device history. Because this only
surfaces under recovery/relaunch timing, it is hard for users to detect and is
silently wrong data.

## Source evidence

- `WatchWorkoutEngine` active-session state (audited 2026-08-10): the engine
  tracks an active session but does not record which workoutID that session
  belongs to, so recovery re-binds to whatever snapshot is current rather than
  the workout the live session was started for.
- Recovery path: on restart/interruption the engine rebuilds from the current
  mirror snapshot without verifying it matches the session's originating workout.

## Scope

- In scope: recording workout identity on the engine's active session and
  restarting/ending the session when the identity mismatches the current context.
- Out of scope: the phone-side terminal command identity in FF-002 (separate
  story, though it lands first in Wave A).

## Non-goals

- Not reworking the whole recovery model — only adding identity binding and the
  mismatch response.
- Not changing live-workout streaming semantics for the correct-identity case.

## High-level fix direction

Record the workout identity at the moment the engine starts a live session, and
carry it through interrupts:
- The engine stores the originating workoutID alongside the active session.
- On recovery, the engine compares the originating identity to the current mirror
  snapshot/context; if they differ, it restarts or ends the session bound to the
  wrong identity rather than streaming under the new one.
- Data is only attributed to a workout when the identity matches.

## Acceptance criteria

- [ ] Active engine session records the workoutID it was started for.
- [ ] On recovery with a mismatched snapshot, the engine restarts or ends the
      stale session instead of streaming under the newer identity.
- [ ] On recovery with a matching identity, streaming resumes normally.
- [ ] No live data is attributed to a workout the session was not started for.

## Required automated tests

- [ ] Recovery/context test: recover engine against snapshot B while the active
      session belongs to A; assert the session is restarted/ended, not resumed
      under B.
- [ ] Context test: matching identity recovers and resumes without restart.

## Required runtime / hardware validation

- [ ] Hardware A-to-B validation on real Apple Watch + iPhone: start A, force a
      recovery/interrupt, start B, and confirm the recovered session is ended not
      misattributed; capture real HKWorkoutSession/HealthKit records for both A
      and B.

## Dependencies

- **Depends on FF-002** (Wave A, order FF-002 → FF-003) for the wire contract the
  engine interacts with.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-003 | Claimed. Realized FF-002's Review status and landed wire contract (`workoutID` on terminal commands, `WatchTerminalCommandPolicy` in ForgeCore). Approach: (1) engine records the originating `workoutID` on every session it starts and persists it durably (UserDefaults — a UUID, no health data, never leaves the watch) so watchOS relaunch/recovery can re-read whose session it reattached to; (2) a pure ForgeCore `WatchEngineIdentityPolicy` decides start/keep/end/end+start from (hasSession, sessionWorkoutID, contextWorkoutID) and gates live-metrics emission on a verified identity match — deterministic tests live in ForgeCore because the Watch target has no unit-test target (same constraint FF-002 recorded); (3) WatchStore reconciles on both authoritative snapshot apply and post-recovery bootstrap; mismatched/unverifiable sessions are ended without saving and the engine starts a fresh session bound to the current workout; matching identity keeps the session untouched; metrics from a session whose identity is not the current workout are never sent to the phone; (4) the phone-started handoff placeholder (FF-002) binds the handoff session to the placeholder and apply() re-binds it to the real workout when the authoritative snapshot lands — nothing was ever recorded against the placeholder, so re-labelling cannot misattribute. No wire or schema changes. Tests requested, NOT run this session (file-edit-only worker) — see Tests requested / run. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-003 | Implementation and tests submitted. Incorporated manager corrections: (1) policy now distinguishes NO authoritative context yet (`.awaitContext` quarantine — keep the session, never stream, never cancel for slow WCSession) from an authoritative nil-workout context (`.endSession`); `WatchStore.hasReceivedAuthoritativeContext` tracks the distinction. (2) Phone-start handoff starts with `workoutID: nil` (NOT the fabricated placeholder UUID); live metrics are blocked while `isAwaitingWorkoutIdentity`; the first authoritative workout snapshot explicitly `rebindSessionWorkoutID(to:)`s the pending session to the real workoutID instead of tearing it down. (3) Authoritative A-to-B mismatch cancels stale A without saving and starts B. (4) `cancel`/`finish`/start-creation-failure clear in-memory AND durable identity even when session/builder is nil; identity is preserved ONLY across the engine-internal failure restart. (5) Recovery loads persisted identity before the async HealthKit call and avoids clearing a newer in-memory session on stale completion; route-collection behavior left to FF-010. (6) All start call sites pass identity; metrics gated. Added exhaustive ForgeCore tests (quarantine, authoritative-nil end, pending-handoff no-stream, match keep, A-to-B restart, idle/start, and `WatchSessionIdentityStore` save/load/clear on an isolated always-cleaned UserDefaults suite). Tests authored but NOT run (file-edit-only worker) — see Tests requested / run. |

### Files changed

- `Packages/ForgeCore/Sources/ForgeCore/WatchSync.swift` — added `WatchEngineIdentityPolicy` (pure decision surface: `resolve(engineHasSession:sessionWorkoutID:hasAuthoritativeContext:contextWorkoutID:)` returning `.idle`/`.startSession`/`.awaitContext`/`.keepStreaming`/`.endSession`/`.endSessionAndStartCurrent`, and `mayStreamMetrics(sessionWorkoutID:isAwaitingAuthoritativeIdentity:contextWorkoutID:)`); added `WatchSessionIdentityStore` (durable, injectable-`defaults` clear/persist seam, hosted in ForgeCore like `ForgeFitWidgetSnapshotStore`). No wire or SwiftData schema change.
- `ForgeFitWatch Watch App/WatchWorkoutEngine.swift` — `start(...)` accepts `workoutID: UUID? = nil` and binds it synchronously; `beginSession` persists identity and its creation-failure `catch` clears it; `recoverSessionIfNeeded` loads persisted identity before the async HealthKit call and clears it on "nothing recovered" only when no newer in-memory session/start claimed the engine; `clearSession` clears in-memory + durable identity; `finish`/`cancel` clear identity even when session/builder is nil; `restartSession` preserves identity only across the engine-internal failure restart; added `rebindSessionWorkoutID(to:)` for the pending-handoff bind.
- `ForgeFitWatch Watch App/WatchStore.swift` — added `hasReceivedAuthoritativeContext`; `activate()` gates `engine.onMetrics` via `mayStreamMetrics` (blocks while `isAwaitingWorkoutIdentity`); `ensureWorkoutSessionRunning` reconciles via `resolve`; `apply(context:)` reconciles (pending-handoff re-bind vs. cancel-stale-A-and-start-B vs. authoritative-nil end with verified-summary gate); `handleWorkoutConfiguration` starts the handoff session with `workoutID: nil`; added `startEngineSession(for:)` helper; all start call sites pass identity.
- `Packages/ForgeCore/Tests/ForgeCoreTests/WatchSyncTests.swift` — added FF-003 policy tests (await-context quarantine incl. placeholder-mirror, authoritative-nil end, unverifiable-session end/end+start, no-session start/idle, match keep, A-to-B restart, metrics-gating matrix, pending-handoff no-stream) and `WatchSessionIdentityStore` save/load/clear lifecycle on an isolated always-cleaned UserDefaults suite.

### Tests requested / run

AUTHORED but NOT RUN in this session (file-edit-only worker; no shell/tests/builds/git/network). Reviewer must execute:

- `DEVELOPER_DIR beta make -e test` — ForgeCore `WatchSyncTests` FF-003 cases: `mismatchedSnapshotRestartsInsteadOfResumingUnderB`, `matchingIdentityKeepsStreaming`, `liveSessionWithNoAuthoritativeContextIsQuarantined`, `liveSessionWithOnlyAPlaceholderMirrorIsQuarantined`, `authoritativeNilWorkoutEndsTheLiveSession`, `unverifiableSessionCannotStreamUnderAnyWorkout`, `noSessionStartsForTheAuthoritativeWorkoutOrIdles`, `metricsStreamOnlyUnderAMatchingResolvedIdentity`, `pendingHandoffNeverStreamsBeforeBinding`, `sessionIdentityStorePersistsClearsAndHandlesMissing`.
- `make build-watch` — Watch target compile gate. The Watch target has no unit-test target of its own (same constraint FF-002 recorded), so the engine/store wiring (identity binding, recovery load, re-bind, metrics gate) is compile-gated only; its behavior is pinned by the ForgeCore policy tests above.
- Targeted iOS 26.5 app run (`OS=26.5`) to confirm no FF-002/FF-003-adjacent regression in `WatchTerminalCommandIdentityTests` / `WatchStructuredSetSyncTests`.

### Residual risks

- **Hardware A-to-B validation outstanding:** the story's Required runtime / hardware validation (start A on real Apple Watch + iPhone, force a recovery/interrupt, start B, confirm the recovered session is ended not misattributed; capture real HKWorkoutSession/HealthKit records for both) has not been executed. `devicectl` reported physical iPhone/Watch unavailable in the FF-002 wave; this remains the only way to confirm the end/restart and re-bind behavior against real HealthKit recovery timing.
- **Mixed-version / upgrade window:** a session started by a pre-FF-003 Watch build records no identity. On upgrade + relaunch + recovery it is treated as unverifiable (nil identity): the first authoritative snapshot ends it and starts a fresh session bound to the current workout (or ends it on an authoritative nil). This is the safe, guarantee-preserving choice but discards the pre-upgrade session's in-flight HealthKit data rather than continuing it. Recorded, not a regression of the fixed path.
- **Pre-existing apply-vs-recovery micro-race (out of scope):** if an authoritative snapshot is applied before `recoverSessionIfNeeded` begins, the engine may start a fresh session while the headless pre-relaunch session is still running; HealthKit's single-primary-session exclusivity governs the outcome. This race predates FF-003 and is not introduced by it; it is the adjacent engine-session timing concern FF-002's review flagged. Not addressed here.
- **Quarantine window:** a recovered session with no authoritative snapshot yet is kept but does not stream (metrics suppressed) until the first snapshot resolves it — a bounded gap in phone-side live metrics during a slow WCSession handoff, the deliberate price of never attributing unverified data.
- **Watch target not unit-tested:** the engine/store identity wiring is compile-gated only (no Watch unit-test target); the deterministic guarantees live in the ForgeCore policy + store tests. Interactive watch-simulator and hardware validation remain the runtime evidence.

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