# Authoritative Cardio Distance Announcements Design

**Date:** 2026-07-22

## Goal

Ensure a mile or kilometer is announced only after the same live distance shown on the phone and Apple Watch has crossed that boundary.

## Confirmed root cause

During an outdoor workout, the phone UI prefers `LiveMetricsHub.shared.liveMetrics.distanceMeters`, which is streamed from Apple Watch. `CardioRouteRecorder`, however, triggers spoken splits from its independent phone-GPS accumulator. Phone GPS can run ahead of HealthKit's Watch distance, so audio can announce mile 3 while both visible devices still show 2.93 miles.

The defect is not unit conversion or rounding. The announcement and display use different live sources of truth.

## Product invariants

- Audio must never announce a distance boundary that the authoritative visible metric has not crossed.
- A fresh Apple Watch stream owns outdoor live distance.
- Phone GPS remains responsible for recording the route even while Watch distance owns the live metric.
- When Watch data becomes stale, display, goals, intervals, Live Activity, and audio fall back to phone GPS together.
- Each boundary is announced at most once.
- No new HealthKit sample, CloudKit field, or persisted schema is required.

## Architecture

Two pure policies are introduced in ForgeCore and coordinated by the existing phone-side route recorder:

1. `LiveDistanceArbiter` chooses a `watch` or `phoneGPS` reading from timestamped inputs.
2. `DistanceMilestoneTracker` consumes only the chosen authoritative distance and returns newly crossed boundary indexes.

`CardioRouteRecorder` owns the session-scoped readings, tracker, and split timing anchors because it already owns route recording and `PaceAnnouncer` lifecycle. It exposes one authoritative live-distance accessor that all phone consumers use.

## Source arbitration

The recorder stores:

- Latest Watch distance and the phone receipt time of that Watch packet.
- Latest phone-GPS accumulated distance and GPS timestamp.
- Active session ID.
- Recording start and split anchor dates.

Watch freshness is based on packet receipt time, not `WatchLiveMetrics.asOf`. That field can represent the last heart-rate sample and therefore is not a reliable distance-packet timestamp. The freshness window remains 15 seconds, matching the existing Watch-stream cadence contract.

Selection rules at a caller-supplied current time:

1. Use Watch distance when it is positive and its packet was received no more than 15 seconds ago.
2. Otherwise use positive phone-GPS distance.
3. Otherwise use the stored session distance if the caller supplies it.
4. Otherwise return no live distance.

The arbiter returns both meters and source so tests and diagnostics can verify ownership. Distance is never blended or averaged.

## Update flow

### Session start

`CardioExerciseCard` assigns the cardio session's live start timestamp before starting route recording. The recorder activates session and milestone state immediately, even when phone location authorization is unavailable, then starts `CLLocationManager` only when authorized. It receives the session timestamp so Watch-first sessions have honest split and total durations even before the first GPS fix. Authorization-pending startup retains both session ID and start date.

### Phone GPS update

1. Accurate GPS fixes continue accumulating route distance exactly as today.
2. The recorder updates the phone-GPS reading.
3. It asks the arbiter for the authoritative reading.
4. If Watch is fresh, the lower Watch distance is evaluated and phone GPS cannot announce early.
5. If Watch is absent or stale, the same GPS reading now returned to the UI is evaluated for milestones.

### Watch update

1. `WatchLink` continues publishing the packet to `LiveMetricsHub` for heart rate and workout metrics.
2. It also forwards positive Watch distance and packet receipt time to the active route recorder.
3. The recorder asks the arbiter for the authoritative reading and evaluates milestones immediately.

### Phone consumers

The following outdoor-distance consumers use the recorder's authoritative accessor rather than independently preferring Watch and GPS:

- `CardioExerciseCard` live distance and pace.
- `IntervalRunner` distance progress.
- `WorkoutActivityController` Live Activity distance and pace.
- Spoken mile/kilometer milestones.

This prevents another source-order drift from recreating the bug on a different surface.

## Milestone tracking

`DistanceMilestoneTracker` is initialized with the locale-selected boundary distance: exactly 1,609.344 meters for miles or 1,000 meters for kilometers.

For each authoritative reading it:

- Rejects negative and nonfinite values.
- Computes every newly crossed positive boundary.
- Never reduces the number of completed boundaries if a source switch reports a smaller distance.
- Emits each boundary index once.
- Supports a large GPS gap crossing multiple boundaries without duplication.

The app layer converts emitted indexes into the existing `PaceAnnouncement.phrase`. Split and total durations use the timestamp of the authoritative update that crossed the boundary. The current speech setting and audio-session behavior remain unchanged.

## Source switching

If Watch becomes fresh while phone GPS is farther ahead, the visible authoritative distance may move to the lower Watch value, matching current Watch-first product behavior. The tracker does not retract already announced boundaries.

If Watch later becomes stale and phone GPS is ahead, the phone display and audio adopt GPS in the same evaluation. A boundary may be announced at that moment, but it is no longer early relative to the visible phone value. No hidden GPS boundary is announced while Watch remains authoritative.

## Error and lifecycle handling

- No Watch distance: GPS behavior is unchanged.
- No location authorization but Watch distance exists: Watch can drive visible distance and announcements; route storage remains unavailable.
- Watch packet with nil/zero distance: it does not displace a valid GPS reading.
- Stale Watch packet: GPS becomes authoritative after 15 seconds.
- Out-of-order or decreasing readings: tracker monotonicity prevents duplicate announcements.
- Stop/cancel/new session: all readings, timestamps, and milestone state reset; queued speech is stopped as today.
- Indoor cardio: route recorder and distance announcements remain inactive.

## Testing

ForgeCore tests prove:

- Fresh Watch at 2.93 miles beats phone GPS at 3.01 miles.
- The third-mile event is absent until Watch reaches 3.00 miles.
- With no Watch, GPS crossing 3.00 miles emits mile 3 once.
- A stale Watch yields to GPS.
- A nil/zero Watch distance does not suppress GPS.
- Decreasing source values never duplicate a boundary.
- One update crossing multiple boundaries emits each missing index once.
- Kilometer and exact international-mile thresholds are respected.
- Negative, NaN, and infinite readings do not emit events.

App-target tests prove:

- A fresh Watch update reaches the route recorder and can trigger a milestone.
- A GPS update cannot trigger mile 3 while fresh Watch distance remains at 2.93.
- Phone display, interval progress, Live Activity, and announcement arbitration resolve the same source.
- Starting before the first GPS fix still anchors Watch-driven split duration to session start.
- Stopping and starting a new session resets milestone state.

Manual verification uses a deterministic debug fixture or injected readings rather than waiting for a real three-mile run:

1. Start an outdoor run with Watch ownership active.
2. Inject Watch 2.93 mi and phone GPS 3.01 mi.
3. Confirm phone and Watch show 2.93 and no mile-3 speech occurs.
4. Inject Watch 3.00 mi.
5. Confirm both visible metrics cross the boundary and mile 3 is spoken once.
6. Repeat without a Watch stream and confirm GPS fallback.

## Out of scope

- Reconciling final HealthKit distance with saved GPS-route distance.
- GPS smoothing or route-quality changes.
- Spoken pace coaching beyond completed split announcements.
- Watch-side speech synthesis.
