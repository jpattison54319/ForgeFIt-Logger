# Authoritative Cardio Distance Announcements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the phone display, interval progress, Live Activity, and spoken splits use one authoritative outdoor live-distance source.

**Architecture:** ForgeCore provides a timestamped Watch-vs-GPS arbiter and a monotonic milestone tracker. `CardioRouteRecorder` owns session-scoped readings and applies those pure policies; WatchLink forwards Watch distance into it, while every phone consumer reads its authoritative accessor. GPS route storage remains independent.

**Tech Stack:** Swift 6.2, Swift Testing, CoreLocation, WatchConnectivity, HealthKit metrics, SwiftUI, AVFoundation, iOS/watchOS 26.

## Global Constraints

- Fresh Watch distance wins for 15 seconds from phone receipt time.
- Phone GPS still records the route while Watch owns the visible metric.
- Audio cannot cross a boundary before the authoritative visible distance.
- Preserve exact mile conversion at 1,609.344 meters and kilometer conversion at 1,000 meters.
- No HealthKit, SwiftData, CloudKit, or privacy-schema changes.
- Preserve all pre-existing user edits, especially unrelated `WatchLink.swift` readiness changes; inspect and stage nothing automatically.

---

### Task 1: Build the pure distance arbiter

**Files:**
- Create: `Packages/ForgeCore/Sources/ForgeCore/LiveDistancePolicy.swift`
- Create: `Packages/ForgeCore/Tests/ForgeCoreTests/LiveDistancePolicyTests.swift`

**Interfaces:**
- Produces: `LiveDistanceReading`, `LiveDistanceSource`, and `LiveDistanceArbiter.preferred(watch:phoneGPS:storedMeters:at:watchFreshness:)`.

- [ ] **Step 1: Write failing arbitration tests**

Test fresh Watch 2.93 mi versus GPS 3.01 mi, stale Watch fallback, nil/zero Watch fallback, stored-distance fallback, and nonfinite/negative rejection.

- [ ] **Step 2: Verify RED**

Run `swift test --package-path Packages/ForgeCore --filter LiveDistancePolicyTests` and confirm missing-type compilation failures.

- [ ] **Step 3: Implement the arbiter**

Define timestamped readings in meters. Select positive finite Watch distance when `now.timeIntervalSince(receivedAt) <= 15`, otherwise positive finite GPS, otherwise positive finite stored distance. Return source with meters; never average sources.

```swift
public enum LiveDistanceSource: Sendable, Equatable { case watch, phoneGPS, stored }
public struct LiveDistanceReading: Sendable, Equatable {
    public let meters: Double
    public let observedAt: Date
    public let source: LiveDistanceSource
}

public enum LiveDistanceArbiter {
    public static func preferred(
        watch: LiveDistanceReading?,
        phoneGPS: LiveDistanceReading?,
        storedMeters: Double?,
        at now: Date,
        watchFreshness: TimeInterval = 15
    ) -> LiveDistanceReading? { /* ordered validation and selection */ }
}
```

- [ ] **Step 4: Verify GREEN**

Run the focused suite and all ForgeCore tests.

- [ ] **Step 5: Checkpoint diff**

Run `git diff --check` on the new policy and test files.

### Task 2: Build the monotonic milestone tracker

**Files:**
- Modify: `Packages/ForgeCore/Sources/ForgeCore/LiveDistancePolicy.swift`
- Modify: `Packages/ForgeCore/Tests/ForgeCoreTests/LiveDistancePolicyTests.swift`

**Interfaces:**
- Produces: `public struct DistanceMilestoneTracker` with `init(boundaryMeters:)`, `mutating func consume(meters:) -> [Int]`, and `mutating func reset()`.

- [ ] **Step 1: Write failing milestone tests**

Prove exact mile and kilometer boundaries, 2.93/3.01 source arbitration, no duplicates after decreasing values, multiple crossed boundaries, reset, and invalid values.

- [ ] **Step 2: Verify RED**

Run the focused suite and confirm `DistanceMilestoneTracker` is missing.

- [ ] **Step 3: Implement the tracker**

Store the largest emitted positive boundary index. For a valid reading, calculate `floor(meters / boundaryMeters)`, emit the closed range from `lastIndex + 1` through the new index, and retain monotonic state when distance decreases. Reject nonpositive boundary initialization with a precondition.

```swift
public struct DistanceMilestoneTracker: Sendable {
    public init(boundaryMeters: Double)
    public mutating func consume(meters: Double) -> [Int]
    public mutating func reset()
}
```

- [ ] **Step 4: Verify GREEN**

Run focused and full ForgeCore suites.

- [ ] **Step 5: Checkpoint diff**

Run `git diff --check` and inspect all boundary math.

### Task 3: Make route recording own authoritative session distance

**Files:**
- Modify: `ForgeFit/Cardio/CardioRouteSupport.swift`
- Create: `ForgeFitTests/CardioLiveDistanceCoordinatorTests.swift`

**Interfaces:**
- Produces recorder methods `updateWatchDistance(_:receivedAt:)` and `authoritativeLiveDistance(for:storedMeters:at:)`.
- Changes `start(session:)` to activate milestone state before location authorization and retain the session start date.

- [ ] **Step 1: Write failing coordinator tests**

Extract an internal value-type `CardioLiveDistanceCoordinator` in `CardioRouteSupport.swift` so tests can feed Watch/GPS readings without `CLLocationManager` or speech. Assert Watch 2.93 suppresses the GPS 3.01 milestone, Watch 3.00 emits mile 3 once, stale Watch yields to GPS, and reset clears ownership/milestones.

- [ ] **Step 2: Verify RED**

Run the focused app test on iPhone 17 Pro/iOS 26.5 and confirm the coordinator API is missing.

- [ ] **Step 3: Implement the coordinator and recorder integration**

The coordinator stores latest Watch/GPS readings, `LiveDistanceArbiter`, `DistanceMilestoneTracker`, recording start, and split anchor. Its update methods return `(authoritative: LiveDistanceReading?, milestones: [Int])`. `CardioRouteRecorder` converts milestones to the existing `PaceAnnouncer` calls and owns no separate `announcedSplits` counter.

```swift
struct CardioLiveDistanceCoordinator {
    struct Output {
        let authoritative: LiveDistanceReading?
        let milestones: [Int]
    }

    mutating func updateWatch(meters: Double, receivedAt: Date) -> Output
    mutating func updateGPS(meters: Double, observedAt: Date) -> Output
    func authoritative(storedMeters: Double?, at date: Date) -> LiveDistanceReading?
    mutating func reset(boundaryMeters: Double, startedAt: Date)
}
```

Activate `recordingSessionID` and coordinator state immediately in `start(session:)`. Request/start location services separately. Preserve pending start date during authorization. Reset everything in `stop` even when no route locations exist.

- [ ] **Step 4: Verify GREEN**

Run the focused app suite and `swift test --package-path Packages/ForgeCore`.

- [ ] **Step 5: Checkpoint diff**

Run `git diff --check` on route support and its tests.

### Task 4: Feed Watch distance and unify all phone consumers

**Files:**
- Modify: `ForgeFit/Health/WatchLink.swift`
- Modify: `ForgeFit/Cardio/CardioViews.swift`
- Modify: `ForgeFit/Cardio/IntervalRunner.swift`
- Modify: `ForgeFit/Workout/WorkoutActivityController.swift`
- Modify: `ForgeFitTests/IntervalRunnerDistanceTests.swift`

**Interfaces:**
- Consumes recorder methods from Task 3.

- [ ] **Step 1: Write failing integration tests**

Add focused tests proving the interval runner's production feed and a pure presentation helper resolve recorder-authoritative distance rather than reading Watch/GPS independently. Preserve existing injected interval-feed tests.

- [ ] **Step 2: Verify RED**

Run `IntervalRunnerDistanceTests` and the coordinator tests; confirm the new authoritative accessor is not yet consumed.

- [ ] **Step 3: Forward every Watch metrics path**

Create one `@MainActor` helper in `WatchLink` that calls both `LiveMetricsHub.shared.updateFromWatch(metrics)` and `CardioRouteRecorder.shared.updateWatchDistance(metrics.distanceMeters, receivedAt: .now)`. Use it for `.liveMetrics` commands and application-context fallback, preserving pre-existing readiness edits.

```swift
@MainActor
private func applyLiveMetrics(_ metrics: WatchLiveMetrics, receivedAt: Date = .now) {
    LiveMetricsHub.shared.updateFromWatch(metrics)
    CardioRouteRecorder.shared.updateWatchDistance(metrics.distanceMeters, receivedAt: receivedAt)
}
```

- [ ] **Step 4: Replace independent source selection**

In `CardioExerciseCard`, set session start timestamps before `CardioRouteRecorder.start`. Replace direct Watch/GPS preference code with `authoritativeLiveDistance`. Update `IntervalRunner` and `WorkoutActivityController` to call the same accessor, supplying stored session distance only as final fallback.

```swift
CardioRouteRecorder.shared.authoritativeLiveDistance(
    for: session.id,
    storedMeters: session.distanceMeters,
    at: .now
)
```

- [ ] **Step 5: Verify GREEN**

Run focused app suites, ForgeCore tests, and `make build-ios`.

- [ ] **Step 6: Checkpoint diff**

Run `git diff --check` and inspect every changed source-selection call site.

### Task 5: End-to-end regression verification

**Files:** No new production files.

- [ ] Run all `LiveDistancePolicyTests`.
- [ ] Run `CardioLiveDistanceCoordinatorTests` and `IntervalRunnerDistanceTests` on iPhone 17 Pro/iOS 26.5.
- [ ] Run all ForgeCore tests.
- [ ] Run `make build-ios` and `make build-watch` because the Watch wire consumer changed.
- [ ] Use the deterministic fixture to feed Watch 2.93 mi plus GPS 3.01 mi; verify no mile-3 event, then feed Watch 3.00 mi and verify exactly one event.
- [ ] Repeat without Watch input and verify GPS fallback.
- [ ] Inspect phone live distance, interval strip, and Live Activity for the same selected source.
- [ ] Run `git diff --check` and confirm no final-distance reconciliation, GPS smoothing, schema, or unrelated readiness code changed.
