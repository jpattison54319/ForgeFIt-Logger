# FF-002 — Watch Terminal Command Identity

**Status:** In Review
**Severity:** P1
**Owner:** DeepSeek V4 Flash 0731 — FF-002
**Source audit date:** 2026-08-10

## Problem

The Watch→phone terminal commands (finish and discard workout) do not carry the
identifier of the workout they are meant to end. Because Watch↔phone messaging is
asynchronous and order is not guaranteed, a delayed `finishWorkout`/`discardWorkout`
userInfo can arrive after the user has already started a different workout on the
phone, and terminate the wrong session.

## Confirmed trigger

- Start workout A on the phone and mirror it on the Watch.
- End A on the phone and immediately start workout B.
- A previously queued/slow-delivered `WatchCommand.finishWorkout` (or
  `discardWorkout`) for A arrives while B is active.
- B is finished/discarded as a result of A's terminal command.

## User impact

A workout can be prematurely ended or discarded without the user asking for it,
losing logged sets and potentially writing a truncated/short workout to HealthKit.
The async delivery on WCSession makes this intermittent and hard to reproduce,
which is precisely why it is dangerous.

## Source evidence

- `WatchCommand.finishWorkout` / `WatchCommand.discardWorkout` — the terminal
  command cases/messages lack a `workoutID` field (audited 2026-08-10).
- The Watch command handler that unpacks these cases applies the terminal action
  to whatever workout is currently active on the phone, with no ID match against
  the starting/active workout.

## Scope

- In scope: making the terminal command carry the target workout identity and
  having the phone handler reject mismatches.
- Out of scope: unrelated watch protocol messages, and the WatchWorkoutEngine
  identity concern tracked separately in FF-003.

## Non-goals

- Not re-architecting WCSession delivery/ordering guarantees.
- Not changing start/pause/resume command shape unless directly required by
  binding the terminal command.

## High-level fix direction

Bind each terminal command to the identity of the workout it is terminating:
- Add a `workoutID` to `WatchCommand.finishWorkout` and `WatchCommand.discardWorkout`.
- The Watch side stamps the ID of the workout it is bound to at the time it emits
  the command.
- The phone handler compares the carried ID to the currently active workout; on
  mismatch it drops the command (does nothing) rather than terminating the newer
  workout.
- Preserve wire compatibility only if the audit determines an old Watch build can
  still be in the field with a new phone build — otherwise the contract is updated
  in lockstep. Deviation from the current wire shape must be an explicit, recorded
  decision, not assumed.

## Acceptance criteria

- [x] `finishWorkout` and `discardWorkout` carry the target workout ID.
- [x] Handler refuses to finish/discard when the carried ID does not match the
      active workout; a newer workout is left untouched.
- [x] Handler still finishes/discards correctly when the ID matches.
- [x] Delayed/misordered delivery of a terminal command for a superseded workout
      has no effect on the active workout.
- [x] Wire compatibility retained (old Watch + new phone) if and only if the
      audit requires it, with the decision recorded; otherwise the contract is
      updated deliberately.

## Required automated tests

- [x] Protocol tests: encoding/decoding of terminal commands carries the workout
      ID over the wire.
- [x] Handler tests: matching ID ends the workout; mismatched ID is rejected and
      the newer workout survives; delayed replay of an old command is a no-op.

## Required runtime / hardware validation

- [ ] Simulator watch↔phone: finish A, immediately start B, replay A's finish
      userInfo — B is unaffected.
- [ ] Hardware Apple Watch + iPhone: same scenario with real WCSession delivery,
      including an artificial delay injection if feasible.

> Status: BOTH OUTSTANDING. Interactive Watch+phone simulation was not executed
> (the pending-identity placeholder flow and the phone's republish-on-refusal
> delivery still need it), and `devicectl` reports no physical iPhone/Watch
> devices, so the hardware delay/replay run has not been performed. See Residual
> risks.

## Dependencies

- None new; **precedes FF-003** (Wave A). FF-003's engine identity handling
  depends on this wire contract change.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-002 | Claimed. Recording wire-compat decision: additive-optional `workoutID` on `finishWorkout`/`discardWorkout`; legacy (nil) IDs decode safely and are refused by the phone handler (no-op), never executed against the active workout. Old-Watch→new-Phone messages stay decodable; new-Watch→old-Phone cannot enforce binding (recorded risk). Implementing enum, Watch producers, phone handler gate, phone→Watch discard direction preserved, protocol + handler tests. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-002 | Implementation and tests submitted. Matching identity preserves prior behavior; nil/mismatched IDs are dropped at the handler (verify: WatchSyncTests + WatchTerminalCommandIdentityTests). Tests NOT run in this session (file-edit-only worker). Reviewer must execute the commands under "Tests requested / run". |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-002 | Static-review correction (manager): `WatchStore.finishWorkout` stamped `workout.id` on the emitted `.finishWorkout`, but the captured value is a `WatchWorkoutSnapshot`, whose identity property is `workoutID` — guaranteed compile error in the Watch target. Corrected to `workout.workoutID`. `discardWorkout` already stamped `activeWorkout?.workoutID` (consistent; reads before `clearWorkoutLocally()`). No test evidence claimed; tests remain unrun. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-002 | Adversarial-review findings implemented: (1) placeholder identity — `showPhoneStartedWorkoutPlaceholder` showed a fabricated `workoutID`; finish/discard during that handoff window could write HealthKit then be refused by the phone. Added `WatchStore.isAwaitingWorkoutIdentity`, set by the placeholder, cleared by any real `WatchAppContext` apply and by local clear; `finishWorkout`/`discardWorkout` now refuse (before engine/HealthKit/wire/local mutation) and `WatchActiveWorkoutView` disables Finish/Discard (+ conditioning Finish control) with "Syncing workout…". (2) iPhone republish on refusal passed through the new shared `WatchTerminalCommandPolicy` (ForgeCore); refused nil/mismatched/active-less terminal commands now `publishState(.immediate)`. Pure policy tests added in ForgeCore; handler no-active refusal test added; republish delivery is NOT unit-observable (WCSession sends bail with no watch app installed) so it is covered by policy tests + simulator/hardware validation, no hooks added. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-002 | Manager final-review correction: independent encoding of the pre-change `.discardWorkout` confirmed the synthesized codec emits the case key with an EMPTY object payload (`{"discardWorkout":{}}`), not null. `legacyDiscardWorkoutNeverDecodesAsABoundCommand` replaced by `legacyDiscardWorkoutDecodesAsUnbound`, which feeds that exact legacy payload and requires `.discardWorkout(workoutID: nil)` — decode failure is no longer an accepted outcome. Test-only change; no production code touched. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-002 | Manager execution evidence recorded (worker made no execution claims): (1) Package after the legacy fixture correction — `DEVELOPER_DIR beta make -e test` exit 0, log `/tmp/forgefit-wave1-make-test-final.log`; ForgeCore 400 tests in 38 suites, ForgeData 87 tests in 13 suites, support package builds passed. (2) Targeted iOS 26.5 app run — exit 0, 39 tests in 7 suites, log `/tmp/forgefit-wave1-targeted-clean-sim.log`, result `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`; includes `WatchTerminalCommandIdentityTests` and `WatchStructuredSetSyncTests`. (3) iPhone simulator build — exit 0, log `/tmp/forgefit-wave1-build-ios-rerun.log` (after an earlier no-space infrastructure failure). (4) Explicit Watch simulator scheme build — exit 0, log `/tmp/forgefit-wave1-build-watch.log`. Final adversarial reviewer verdict: no P1/P2 code defects remain. Outstanding: interactive Watch validation of pending-identity store/UI ordering and republish delivery; hardware delay/replay (devicectl shows physical iPhone and Watch unavailable); adjacent engine-session race owned by FF-003. |

### Files changed

- `Packages/ForgeCore/Sources/ForgeCore/WatchSync.swift` — added additive-optional `workoutID: UUID?` to `WatchCommand.finishWorkout` and `WatchCommand.discardWorkout` (wire contract; no SwiftData schema change); added shared `WatchTerminalCommandPolicy` (phone execute-gate + watch pending-identity gate) so both devices run the tested policy.
- `ForgeFit/Health/WatchLink.swift` — phone handler now gates `.finishWorkout`/`.discardWorkout` through `WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID:activeWorkoutID:)`; nil (legacy), mismatched, and active-less commands are refused AND trigger an immediate authoritative re-publish so a watch cleared on a stale command converges.
- `ForgeFitWatch Watch App/WatchStore.swift` — watch stamps `WatchWorkoutSnapshot.workoutID` on `finishWorkout`/`discardWorkout` emissions; new `isAwaitingWorkoutIdentity` (set by `showPhoneStartedWorkoutPlaceholder`, cleared by `apply(context:)` and `clearWorkoutLocally()`); `finishWorkout`/`discardWorkout` refuse while identity is pending, before any engine/HealthKit/wire/local mutation; phone→watch `.discardWorkout` handling unchanged (authoritative, ID ignored).
- `ForgeFitWatch Watch App/WatchActiveWorkoutView.swift` — Finish/Discard controls (and the conditioning Finish control) disabled during the pending-identity window; "Syncing workout…" state copy shown so the disabled state is understandable.
- `ForgeFit/Workout/WorkoutFinisher.swift` — phone→watch discard now carries the discarded workout's ID (direction and watch-side behavior unchanged).
- `ForgeFit/Settings/AccountResetService.swift` — phone→watch discard now sent with `workoutID: nil` (no single target; direction and behavior unchanged).
- `Packages/ForgeCore/Tests/ForgeCoreTests/WatchSyncTests.swift` — round-trips updated for the new shapes (bound + nil forms); pure `WatchTerminalCommandPolicy` tests (phone execute-gate and watch pending-identity gate); legacy-wire tests pin the exact pre-change payloads — `finishWorkout` without `workoutID` decodes as unbound, and `discardWorkout`'s legacy empty-object form `{"discardWorkout":{}}` decodes as `.discardWorkout(workoutID: nil)` with decode failure NOT an accepted outcome (manager-verified encoded form).
- `ForgeFitTests/WatchTerminalCommandIdentityTests.swift` — handler suite: matching finish/discard work; stale finish/discard for a superseded workout leaves the newer workout untouched; nil-ID (legacy) finish/discard refused; terminal commands with no active workout refused.

### Tests requested / run

RUN — executed by the manager after the legacy empty-object fixture correction; results recorded here (worker made no execution claims):

- `DEVELOPER_DIR beta make -e test` → **exit 0**. Log: `/tmp/forgefit-wave1-make-test-final.log`. ForgeCore: 400 tests in 38 suites passed. ForgeData: 87 tests in 13 suites passed. Support package builds passed. (Covers `WatchSyncTests`: legacy-wire decode tests `legacyFinishWorkoutWithoutWorkoutIDStillDecodesAsUnbound` and `legacyDiscardWorkoutDecodesAsUnbound`, plus the pure `WatchTerminalCommandPolicy` tests.)
- Targeted iOS 26.5 app run → **exit 0, 39 tests in 7 suites**. Log: `/tmp/forgefit-wave1-targeted-clean-sim.log`; result bundle: `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`. Includes `WatchTerminalCommandIdentityTests` (handler suite: matching/stale/nil/no-active refusals) and `WatchStructuredSetSyncTests` (existing WatchLink plumbing guard).
- iPhone simulator build → **exit 0**. Log: `/tmp/forgefit-wave1-build-ios-rerun.log` (an earlier run failed on infrastructure no-space, not product code; rerun passed).
- Explicit Watch simulator scheme build → **exit 0**. Log: `/tmp/forgefit-wave1-build-watch.log`.

NOT yet executed:

- Interactive simulator watch↔phone validation: finish is refused and Finish/Discard stay disabled with "Syncing workout…" throughout the phone-handoff placeholder window; after the real snapshot lands the state clears and finish works; the phone's republish-on-refusal converges a stale watch. (Watch target builds, but the flow was not exercised interactively.)
- Hardware Apple Watch + iPhone: finish A → immediately start B → replay A's finish/discard userInfo with real WCSession delivery and artificial delay injection. `devicectl` reports physical iPhone and Watch unavailable.

### Residual risks

- **new-Watch → old-Phone window:** an old phone binary cannot validate the added ID (its decoder either ignores the extra key or drops the message); a terminal command from a fresh Watch against an old phone cannot be bound. Unavoidable for any payload-shape change; the fix targets new-phone protection, which the tests cover.
- **Legacy `discardWorkout` wire form — resolved (manager-verified + executed):** the pre-binding no-payload case's synthesized codec emits the case key with an empty object payload, `{"discardWorkout":{}}` (independently confirmed by encoding the pre-change enum). `legacyDiscardWorkoutDecodesAsUnbound` pins that exact payload and requires `.discardWorkout(workoutID: nil)`; no decode-failure fallback remains. Confirmed by `make -e test` exit 0 (see Tests requested / run).
- **Interactive Watch flow unvalidated (simulator and hardware):** the pending-identity placeholder lifecycle (placeholder → real snapshot), the disabled Finish/Discard + "Syncing workout…" UI, and the phone's republish-on-refusal convergence were covered by automated tests and policy tests only. The Watch scheme builds (exit 0), but the end-to-end flow was not exercised on a watch simulator, and `devicectl` shows physical iPhone and Watch unavailable, so the delay/replay run is outstanding.
- **Republish-on-refusal delivery not directly observed:** the phone's immediate re-publish after a refused terminal command bails inside `publishStateNow` when no watch app is installed, so no test hooks were added; automated handler suites and the `WatchTerminalCommandPolicy` tests pass, but the WCSession delivery of the re-published snapshot needs the interactive simulator/hardware evidence above.
- **FF-003 owns the adjacent engine-session race:** the adversarial review surfaced an engine-session identity/timing concern adjacent to this wire change; it is tracked and owned by FF-003 (Watch engine workout identity, Wave A successor) and was deliberately not addressed here.
- Mismatched/dropped terminal commands re-publish phone state as above; a stale watch converges on that snapshot. Interactive watch UX for a dropped finish (workout "comes back" on the watch) is the intended convergence, not a regression.

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| 2026-08-11 | Final adversarial reviewer (manager-relayed) | No P1/P2 code defects remain; NOT Verified | Package + targeted app suites and iOS/Watch builds pass (evidence above). Interactive Watch validation of pending-identity store/UI ordering and republish delivery still outstanding; hardware delay/replay outstanding (devicectl: no physical devices); adjacent engine-session race owned by FF-003. Verified status awaits the remaining simulator/hardware evidence. |

## Definition of Done

- [x] All acceptance criteria checked.
- [x] Required automated tests added and passing via the named command.
- [ ] Required runtime / hardware validation executed and results recorded.
- [x] Worker work log completed (status, owner, files changed, tests,
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