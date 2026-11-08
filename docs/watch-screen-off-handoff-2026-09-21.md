# Phone-started Watch handoff (2026-09-21)

## Finding

The iPhone already published the committed workout graph and called
`HKHealthStore.startWatchApp(with:)`, but the Watch delegate discarded the
provided `HKWorkoutConfiguration`. It waited for a correlated WatchConnectivity
reply before starting `HKWorkoutSession`. A sleeping Watch has no active workout
session to keep its app running, and iPhone `sendMessage` cannot wake it. The
first unreachable request could therefore lead to Retry Sync while the Watch
remained idle until its display was raised. A retained application context is
not a safe workout-start authority: it can be from a prior workout.

Apple's documented path is to start a Watch workout session from the
configuration delivered to `WKApplicationDelegate.handle(_:)`. An active
session keeps the Watch app running with the wrist down. Application context
is latest-wins background state, and a WatchConnectivity background task must
stay alive through session activation and incoming delivery.

- [Start a Watch app from iPhone](https://developer.apple.com/documentation/healthkit/hkhealthstore/startwatchapp%28with%3Acompletion%3A%29)
- [Watch workout configuration delegate](https://developer.apple.com/documentation/watchkit/wkapplicationdelegate/handle%28_%3A%29-1pfoc)
- [Immediate-message wake limitation](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage%28_%3Areplyhandler%3Aerrorhandler%3A%29)
- [WatchConnectivity background tasks](https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask)
- [Background workout behavior](https://developer.apple.com/documentation/healthkit/running-workout-sessions)

## Change

- The Watch reattaches a recoverable HealthKit session first, then starts a
  provisional session using the phone's configuration if no session exists.
  It does this without waiting for a live WatchConnectivity reply.
- The provisional session has no workout ID and cannot stream metrics or be
  saved as the phone workout. Only a fresh correlated phone reply can bind it;
  a fresh idle reply discards it. A local Stop or superseding handoff invalidates
  pending work.
- The Watch now handles SwiftUI WatchConnectivity background tasks, waiting
  for an actual delegate delivery, no remaining pending content, and recovery
  completion, with a bounded timeout. Activation and reachability changes
  expedite failed transient requests.
- The iPhone records a device-local, payload-free diagnostic if HealthKit
  fails to launch the Watch app. The short startup retry grace remains; a
  sustained failure still exposes an actionable Retry control.

No schema, CloudKit, backup, server, or personal-health-data logging changes
were made. The existing Watch `workout-processing` background mode and
HealthKit entitlement were confirmed in `WatchInfo.plist` and the Watch
entitlements.

The checkout already contained uncommitted Watch retry-presentation and
recovery edits before this investigation. Validation covers their combined
working-tree state with this handoff change, not the published Build 100 or a
cherry-pick of just this handoff patch. Unrelated cardio/audio edits were preserved.

## Verification and remaining gate

Focused `WatchRecoveryIntegrationTests` passed 27/27 on watchOS 26.5,
including provisional start, no pre-verification metrics, authoritative ID
binding, stale handoff discard, overlapping handoffs, an idle reply racing
session recovery, local Stop, and terminal ordering. ForgeCore's
`WatchSyncRecoveryTests` passed 23/23. Six deterministic Watch recovery UI
scenarios passed with 24 before/after screenshot and accessibility checkpoints
and a complete evidence gate at
`/tmp/forgefit-handoff-verified-acceptance/watch-run.YEottU`. The brief-failure
fixture automatically returns to a workout with a synthetic live-HR indicator
and no Retry control. An independent `gpt-5.6-luna` review found no new
actionable production handoff bug. The acceptance tool reported 132 tree-lint
findings across the six flows (including system pager containers and a
truncated accessibility label); these remain a separate accessibility review,
not proof that the handoff fails. Nine unrelated Watch flows were not run in
this focused replay. `git diff --check` passed. The UI fixture cannot simulate
radio delivery or a truly sleeping paired Watch.

The paired physical iPhone and Watch were unavailable to the Mac during this
run. No physical install, wrist-down replay, or real-sensor verification was
possible, and these local changes have not been committed, pushed, or uploaded.

Before claiming the real user symptom fixed, install the same build on the
paired iPhone and Watch, leave the Watch display down, start a workout on the
phone, and confirm within the startup window that the Watch session starts,
the workout graph/HR arrive without raising the wrist, and Retry Sync does not
appear. Repeat after a cold Watch launch, a brief disconnect, and a fast
finish/start transition. Check that an old completion summary never replaces
the new workout, and that Stop on Watch is not undone by a late reply.
