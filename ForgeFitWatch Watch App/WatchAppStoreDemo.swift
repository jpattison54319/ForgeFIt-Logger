#if DEBUG
import Foundation
import ForgeCore

/// `--seed-watch-demo`: the watch half of the App Store capture fixture.
///
/// The watch app has no store of its own — every screen renders a
/// `WatchAppContext` the phone pushes over WatchConnectivity. A watch
/// simulator running on its own therefore shows an empty start screen, which
/// is true and useless for a product page. This injects the same snapshot a
/// paired phone would have sent, so the captured screens are the real views
/// with real layout, not a mock.
///
/// `--seed-watch-demo-active` adds the live workout on top: two sets already
/// logged, a rest countdown running, and a superset partner waiting.
enum WatchAppStoreDemo {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-watch-demo")
    }

    static var wantsActiveWorkout: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-watch-demo-active")
    }

    /// `--seed-watch-lengthened`: adds one extended set (full-range reps plus
    /// lengthened partials) to the seeded workout. Kept behind its own flag so
    /// the App Store capture fixture stays exactly the workout it was composed
    /// to show.
    static var wantsLengthenedSet: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-watch-lengthened")
    }

    /// One extended set mid-flight: the full-range reps are logged and the
    /// lengthened partials that followed are already on it, so the wrist row
    /// and the set editor both have something real to render.
    private static var lengthenedExtendedSet: WatchSetSnapshot {
        WatchSetSnapshot(
            id: UUID(),
            label: "3E",
            weight: 67.5,
            unitSuffix: "lb",
            weightKg: 30.6,
            reps: 8,
            completed: false,
            setTypeRaw: SetType.lengthenedExtended.rawValue,
            partialReps: 4
        )
    }

    /// Keeps a synthetic heart rate inside the engine's freshness window. The
    /// wrist view re-reads `liveHeartRate(at:)` every second and drops back to
    /// "Starting HR…" the moment the sample goes stale, so the reading has to
    /// be re-stamped rather than set once.
    @MainActor
    static func startHeartRateTicker(_ engine: WatchWorkoutEngine) {
        Task { @MainActor in
            var beat = 0
            while !Task.isCancelled {
                // A shallow drift, so a capture never looks frozen.
                let bpm = 132 + [0, 1, 2, 1, -1, -2, -1, 0][beat % 8]
                engine.seedAppStoreDemoHeartRate(bpm, average: 128)
                beat += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static func context(now: Date = Date()) -> WatchAppContext {
        WatchAppContext(
            workout: wantsActiveWorkout ? activeWorkout(now: now) : nil,
            routines: [
                WatchRoutineSummary(id: UUID(), name: "Push Day", exerciseCount: 5),
                WatchRoutineSummary(id: UUID(), name: "Pull Day", exerciseCount: 5),
                WatchRoutineSummary(id: UUID(), name: "Leg Day", exerciseCount: 5),
                WatchRoutineSummary(id: UUID(), name: "Zone 2 Run", exerciseCount: 1),
            ],
            readiness: 96,
            readinessAction: "Proceed as planned",
            readinessDetail: "No adverse HRV deviation",
            readinessBasis: .daily,
            unitSuffix: "lb",
            updatedAt: now,
            distanceUnit: .mi
        )
    }

    /// Mirrors the iPhone fixture's Push Day: bench finished through set two,
    /// set three waiting, and the incline superset partner below it.
    private static func activeWorkout(now: Date) -> WatchWorkoutSnapshot {
        let bench = WatchExerciseSnapshot(
            id: UUID(),
            position: 0,
            name: "Barbell Bench Press",
            sets: [
                WatchSetSnapshot(id: UUID(), label: "1", weight: 180, unitSuffix: "lb", reps: 8, completed: true),
                WatchSetSnapshot(id: UUID(), label: "2", weight: 180, unitSuffix: "lb", reps: 7, completed: true),
                WatchSetSnapshot(id: UUID(), label: "3", weight: 180, unitSuffix: "lb", reps: 6, completed: false),
            ]
        )
        let incline = WatchExerciseSnapshot(
            id: UUID(),
            position: 1,
            name: "Incline Dumbbell Press",
            sets: [
                WatchSetSnapshot(id: UUID(), label: "1", weight: 67.5, unitSuffix: "lb", reps: 10, completed: false),
                WatchSetSnapshot(id: UUID(), label: "2", weight: 67.5, unitSuffix: "lb", reps: 9, completed: false),
            ] + (wantsLengthenedSet ? [lengthenedExtendedSet] : [])
        )
        return WatchWorkoutSnapshot(
            workoutID: UUID(),
            title: "Push Day",
            startedAt: now.addingTimeInterval(-34 * 60),
            exercises: [bench, incline],
            restEndsAt: now.addingTimeInterval(78),
            restTotalSeconds: 120
        )
    }
}
#endif
