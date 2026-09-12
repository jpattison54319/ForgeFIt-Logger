# Watch sync and recovery audit — September 12, 2026

Implementation update: the findings below describe the pre-change build 98 source. The authorized build 99 changes and current evidence are recorded in [Watch recovery acceptance](watch-sync-recovery-acceptance-2026-09-12.md).

The current code contains several ways to remain stuck after a missed handoff,
accept stale state, or restart a session that should stay stopped. These do not
require mismatched installations. A separate decoder probe also demonstrates a
specific compatibility failure that can silently reject the workout graph.

This is a source audit and recovery proposal, not an implemented fix. The
reported physical workout's original transport failure remains unconfirmed.
Production files and the existing quick-increment/microcycle work were not
changed. HEAD is `d7a6dbb`; the audited Watch transport, engine, and wire files
have no local differences from that commit.

## Findings

### 1. P1 — A missed handoff can leave the Watch waiting indefinitely

Sources: `ForgeFitWatch Watch App/WatchStore.swift:620`, `:811`, `:849`;
`ForgeFitWatch Watch App/WatchActiveWorkoutView.swift:808`;
`ForgeFit/Health/WatchLink.swift:167`, `:512`.

The HealthKit launch creates a provisional workout and requests a fresh phone
context. That request uses the ordinary command sender: no correlated reply,
no acknowledgement that the workout graph was decoded and applied, and no
deadline or retry schedule for the unresolved identity. Further attempts depend
on scene activation, session activation, or reachability changes. A quiet,
already-foreground Watch can therefore remain stuck after a failed exchange.

The phone's snapshot publisher ignores application-context errors and immediate
message errors. Its terminal-command sender also has no fallback when the
Watch was reachable at the check but the subsequent send fails. The Watch has
an error-to-user-info fallback for ordinary outgoing commands, but that does
not acknowledge the phone's response or successful context application.

While pending, heart-rate transmission is blocked, both wrist terminal controls
are disabled, and the phone's finish command returns without requesting another
reconciliation. This is the closest code-level match to the reported symptoms.

**Recovery direction:** use a correlated request/reply exchange for active
handoffs, retain application context as a convergence channel, and retry a
single outstanding request with bounded backoff while execution is available.
Keep a safe local Stop on Watch action available during sync and show a visible
Retry after a short grace period. A timeout must not fabricate identity or automatically delete a phone
workout. A refused terminal command should trigger reconciliation.

### 2. P1 — Stale snapshots can become authoritative and undo newer state

Sources: `ForgeFitWatch Watch App/WatchStore.swift:685`, `:930`, `:964`;
`Packages/ForgeCore/Sources/ForgeCore/WatchSync.swift:41`, `:793`.

Every successfully decoded incoming context sets
`hasReceivedAuthoritativeContext = true`, clears the pending flag, and replaces
the current graph. There is no revision comparison or correlation with the
current handoff request. Although contexts contain `updatedAt`, the receiver
does not use it to reject older state.

The retained-context guard protects only one entry point, and only when the
in-memory UI pending flag is already true. On process relaunch that flag starts
false even when the engine later recovers a durably pending handoff. Retained
idle or older-workout state can then be treated as authoritative before the
new request is answered.

Concrete sequences to protect:

- A newer live B context arrives by immediate message, followed by an older A
  or idle context from another delivery channel. The Watch replaces B and may
  cancel/restart its engine.
- A provisional handoff receives a delayed old-workout context and binds its
  otherwise-unidentified engine to that old workout.
- The app relaunches during a provisional handoff and applies retained idle
  state before recovering the HealthKit session.
- A just-finished workout receives a late active snapshot and is started again
  because there is no terminal-workout marker in the receiver's reconciliation.

**Recovery direction:** separate cached presentation from verified session
authority. Use an authority epoch, monotonic revision, and request correlation;
establish a new epoch through a fresh exchange. Retain a bounded record of
terminal workout identities so stale active snapshots cannot resurrect them.
Wall-clock timestamps alone should not decide session ownership.

### 3. P1 — A delayed Discard for A can cancel a newer Watch workout B

Sources: `ForgeFitWatch Watch App/WatchStore.swift:866`;
`ForgeFit/Workout/WorkoutFinisher.swift:804`;
`ForgeFit/Settings/AccountResetService.swift:154`.

The phone stamps ordinary discard messages with the discarded workout's ID.
The Watch explicitly ignores that ID and unconditionally cancels its current
engine and clears its graph. A queued discard for A arriving after B starts
therefore stops B on the Watch, while B can remain active on the phone. A later
B context may restart collection, but it cannot undo the recording interruption.

**Recovery direction:** apply workout identity checks in both directions.
Stale or unbound ordinary commands should request current state instead of
mutating a newer session. Account reset currently sends a nil-ID discard and
must remain a distinct, explicitly versioned reset operation; simply rejecting
every nil message would break that existing reset behavior.

### 4. P1 — A cold background phone launch does not reliably initialize sync

Sources: `ForgeFit/ForgeFitApp.swift:80`, `ForgeFit/ContentView.swift:2073`,
`ForgeFit/Health/WatchLink.swift:610`,
`ForgeFit/Health/ReadinessDelivery.swift:419`.

The normal WatchLink configure/activate sequence lives in the screen's launch
task. App initialization configures readiness and intent dependencies, but not
the Watch connection. A later readiness publishing path can configure it, but
that is not a guaranteed prerequisite of a WatchConnectivity background wake.
The command handler silently drops requests if its model context is nil.

Consequently, recovery that depends on the Watch waking a phone process which
never presents a scene can wait for a receiver that has not activated or gained
data access. This is a source-level background-launch gap, not a hardware
reproduction of the reported foreground phone start.

**Recovery direction:** configure and activate the transport once the app-level
persistence container is ready, including persistence recovery. Keep UI callbacks
in the scene. If storage is temporarily unavailable, return an explicit
recoverable status rather than an empty context or silent success.

### 5. P2 — Failed HealthKit recovery can stop retrying while fresh data arrives

Sources: `ForgeFitWatch Watch App/WatchStore.swift:173`, `:202`, `:718`.

Bootstrap retries recovery three times, separated by one and three seconds.
After the third transient failure it returns with bootstrap incomplete. A later
valid phone context is stored, but context application does not retry bootstrap
when that flag is false. Existing live views use one-shot tasks. Recovery then
depends on another scene/reachability event even if HealthKit has recovered in
the meantime.

**Recovery direction:** keep an explicit recoverable-failure state and schedule
bounded retries or restart recovery on a newly verified context. Keep recovery
single-flight and do not interpret an error as proof that no session exists.

### 6. P2 — Snapshot reconciliation can bypass the engine's restart limit

Sources: `ForgeFitWatch Watch App/WatchWorkoutEngine.swift:176`, `:698`, `:711`;
`ForgeFitWatch Watch App/WatchStore.swift:133`, `:243`.

The engine attempts one internal restart and suppresses that restart when
another workout app owns the sensors. After teardown, however, it exposes only
the absence of a session to WatchStore. The next context or foreground
reconciliation calls `start` again, which resets the restart-limit flag. The
failure reason is not represented in the store's decision.

This can repeatedly retry an unavailable session or conflict with a workout
the user deliberately started in another app. Conversely, without another
context or lifecycle event, a transient failure can remain unrecovered.

**Recovery direction:** represent engine states such as starting, running,
recovering, stopping, transient failure, permission required, and blocked by
another workout. Preserve the retry budget for the same logical workout across
snapshot refreshes. Resume automatically only for recoverable failures; respect
another app's active session until an explicit new user action or a verified
change makes retry appropriate.

### 7. P2 — One unsupported optional enum can silently reject the whole graph

Sources: `Packages/ForgeCore/Sources/ForgeCore/WatchSync.swift:24`, `:30`, `:59`;
`Packages/ForgeCore/Sources/ForgeCore/ForgeTheme.swift:6`;
`ForgeFitWatch Watch App/WatchStore.swift:964`.

The wire wrapper converts decoding errors to nil, and receivers silently
return. Optional enum fields tolerate missing keys but not unknown enum values.
A probe linked against the actual compiled ForgeCore module demonstrated:

| Synthetic payload | Actual decoder result |
| --- | --- |
| Current context with a workout and known theme | Workout decoded |
| Same context with optional theme omitted | Workout decoded |
| Same context with an unknown future theme value | Entire context rejected |

An unrelated appearance addition can therefore block the workout graph on an
older peer. This proves a compatibility vulnerability, not that today's phone
and Watch actually differ in theme support.

**Recovery direction:** exchange protocol capabilities and build provenance,
surface incompatible-peer and decode failures, and decode nonessential
presentation enums conservatively. Keep workout identity and lifecycle fields
strict. Do not turn an unknown critical state into an assumed active or idle
workout. Consider keeping minimal session identity/lifecycle data independent
of optional presentation fields so an unsupported theme cannot block teardown.

## Recommended implementation order

1. Make authority and terminal operations safe: reject stale snapshots, bind
   commands to the exact workout, distinguish account resets, and initialize
   the phone transport independently of its UI.
2. Add one recovery coordinator for pending handoff and transient failures.
   Track a request ID, lifecycle generation, retry budget, and last verified
   acknowledgement. Cancel obsolete tasks when the workout changes. A local
   stop must also clear pending handoff configuration and invalidate late
   recovery completions so they cannot start recording again.
3. Expose meaningful recovery UI: syncing initially, a clear interrupted state
   after the grace period, Retry, and an always-available local stop with an explicit consequence.
   Preserve the phone workout and never send a fabricated or unbound discard.
4. Add compatibility handling and bounded local diagnostics. Record transport
   error domain/code, activation state, protocol/build identifiers, request
   outcome, payload byte count, and retry count. Do not log workout payloads,
   exercise names, weights, heart-rate samples, or routes.

An example retry cadence is 1, 2, 4, and 8 seconds with jitter, then a slower
bounded retry while the active workout has execution time, plus reachability
and foreground triggers. These are proposed starting values, not measured
platform guarantees. Deduplicate outstanding requests, cancel obsolete ones,
and do not repeatedly scan history or recreate HealthKit sessions on a timer.

Apple documents that application context replaces pending context, user-info
transfers queue, and interactive messages can return replies and errors. That
supports using explicit acknowledgement for a live handoff while retaining
background convergence. Apple also recommends activating the connection early
in app launch. These recommendations follow that guidance; automatic recovery
still cannot guarantee connectivity while either device is unavailable.
[Watch Connectivity sample documentation](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity),
[Apple's transfer and lifecycle guidance](https://developer.apple.com/videos/play/wwdc2021/10003/).

## Verification and missing coverage

Executed against the current checkout:

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/ForgeCore --filter 'WatchSyncTests|WatchSessionIdentityStoreTests|WatchEngineIdentityTests|WatchTerminalCommandPolicyTests|WatchHandoffContextPolicyTests'`
  completed with exit 0: **56 tests in the WatchSyncTests suite passed**.
  Log: `/tmp/forgefit-watch-recovery-audit-tests-20260912.log`.
- The compatibility probe linked the actual compiled ForgeCore object/module
  and completed with exit 0. Source and output:
  `/tmp/forgefit-watch-recovery-audit-20260912/CompatibilityProbe.swift` and
  `/tmp/forgefit-watch-recovery-audit-20260912/compatibility-probe.log`.

Existing tests provide useful codec, durable identity, and pure policy coverage.
The Watch app unit-test target currently contains only an empty example test.
Its demo UI fixtures bypass real HealthKit startup/recovery. Passing these tests
does not validate the asynchronous WatchStore/engine/transport interaction.

Required deterministic fault-injection coverage before accepting repairs:

| Scenario | Required result |
| --- | --- |
| First context request, response, or acknowledgement is lost | Bounded retry converges; no duplicate session |
| Reachable check succeeds but immediate send fails | Observable failure and safe fallback/retry |
| Phone cold-launches in background without a scene | Transport answers with committed state |
| Fresh B context precedes older A or idle context | B remains current and keeps recording |
| Process restarts mid-handoff with retained idle context | No destructive reconciliation until authority is verified |
| Discard/Finish for A arrives while B is active | B remains untouched |
| User stops locally during authorization/recovery | Late completion cannot restart the stopped session |
| HealthKit fails recovery three times and then succeeds | Recovery resumes without a required UI navigation event |
| Another app starts a workout | ForgeFit does not repeatedly reclaim the sensors |
| Peer introduces an unknown presentation value | Session identity remains usable or an explicit compatibility state appears |
| Account reset is followed by a new workout | Reset scope is respected; delayed old messages cannot clear the new workout |
| Finish is duplicated or followed by an older active snapshot | No duplicate save and no session resurrection |

Use injected transport, clock, and engine boundaries to exercise production
recovery logic, then run deterministic UI acceptance for the resulting recovery
controls. Finally replay phone-start, wrist-down heart rate, disconnect/reconnect,
finish, and A-to-B transitions on the paired devices. No new hardware replay,
physical installation, or frame-time profiling was performed for this audit.
