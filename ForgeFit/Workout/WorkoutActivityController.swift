import ForgeCore
import ForgeData
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Manages the workout Live Activity: starts when a workout starts, updates
/// on set/rest/HR changes (driven by ContentView's fingerprint), ends on
/// finish/discard. Keeps the lock screen and Dynamic Island honest without
/// any background execution.
@MainActor
final class WorkoutActivityController {
    static let shared = WorkoutActivityController()

    #if canImport(ActivityKit)
    private var activity: Activity<WorkoutActivityAttributes>?

    func update(workout: WorkoutModel?, exercises: [ExerciseLibraryModel]) {
        guard let workout else {
            end()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = contentState(for: workout, exercises: exercises)
        if let current = activity ?? Activity<WorkoutActivityAttributes>.activities.first {
            activity = current
            Task {
                await Self.withBackgroundTask(named: "UpdateWorkoutLiveActivity") {
                    await current.update(ActivityContent(state: state, staleDate: nil))
                    for stale in Activity<WorkoutActivityAttributes>.activities where stale.id != current.id {
                        await stale.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        } else {
            activity = try? Activity.request(
                attributes: WorkoutActivityAttributes(workoutTitle: workout.title ?? "Workout"),
                content: ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Ends the Live Activity. Wrapped in a background task assertion because
    /// a watch-initiated finish delivers here via a WCSession message while
    /// the phone can be backgrounded/locked — iOS only wakes the app for a
    /// brief window to handle that message, and without extra time the async
    /// `Activity.end()` call can be cut off mid-flight, leaving the Live
    /// Activity stuck on the lock screen until the user manually starts and
    /// stops another workout on the phone.
    func end() {
        let current = activity
        self.activity = nil
        Task {
            await Self.withBackgroundTask(named: "EndWorkoutLiveActivity") {
                if let current {
                    await current.end(nil, dismissalPolicy: .immediate)
                }
                for stale in Activity<WorkoutActivityAttributes>.activities where stale.id != current?.id {
                    await stale.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    #if canImport(UIKit)
    /// Requests extra background execution time for `work`, ending the
    /// assertion when it completes (or immediately if the OS expires it
    /// first, so we're never penalized for overstaying).
    private static func withBackgroundTask(named name: String, _ work: () async -> Void) async {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        await work()
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
    #else
    private static func withBackgroundTask(named name: String, _ work: () async -> Void) async {
        await work()
    }
    #endif

    private func contentState(for workout: WorkoutModel, exercises: [ExerciseLibraryModel]) -> WorkoutActivityAttributes.ContentState {
        let sorted = workout.exercises.sorted { $0.position < $1.position }
        let allSets = sorted.flatMap(\.sets)
        let hasStrengthSets = allSets.contains { $0.completedAt != nil || $0.reps != nil || $0.weight != nil }
        let pureCardio = !workout.cardioSessions.isEmpty && !hasStrengthSets
        // "Current" exercise = first one with work left.
        let current = sorted.first { we in
            we.sets.contains { $0.completedAt == nil } || we.sets.isEmpty
        } ?? sorted.last
        let currentName = current.flatMap { we in exercises.first { $0.id == we.exerciseID }?.name }
        // "Next" = the first exercise after the current one that still has
        // work left; nil on the final exercise (the UI labels that state).
        let next = current.flatMap { cur in
            sorted
                .drop { $0.id != cur.id }
                .dropFirst()
                .first { we in we.sets.contains { $0.completedAt == nil } || we.sets.isEmpty }
        }
        let nextName = next.flatMap { we in exercises.first { $0.id == we.exerciseID }?.name }

        let timer = RestTimerController.shared
        let resting = timer.isRunning && !timer.isMicro

        if pureCardio, let session = workout.cardioSessions.first {
            let kind = CardioKind.from(modality: session.modality)
            let duration = session.durationSeconds ?? max(0, Int(Date().timeIntervalSince(session.liveStartedAt ?? session.startedAt)))
            // Prefer live distance (watch stream / phone GPS) so the lock screen
            // and Dynamic Island tick in real time; treadmills stay manual-only.
            let library = workout.exercises.first { $0.id == session.workoutExerciseID }
                .flatMap { we in exercises.first { $0.id == we.exerciseID } }
            let providesGPS = CardioKind.providesGPSDistance(name: library?.name ?? "", equipment: library?.equipment)
            let liveDist: Double? = providesGPS
                ? (WatchLink.shared.liveMetrics?.distanceMeters
                    ?? CardioRouteRecorder.shared.liveDistanceMeters(for: session.id)
                    ?? session.distanceMeters)
                : session.distanceMeters
            let paceOrSpeed = kind.usesPace
                ? CardioMetrics.paceString(distanceMeters: liveDist, durationSeconds: duration, kind: kind)
                : CardioMetrics.speedString(distanceMeters: liveDist, durationSeconds: duration)
            // Structured session: the current interval step is the headline.
            let intervalStep = IntervalRunnerHub.shared.runner(for: session.id)?.currentStep?.label
            let paceMetric = paceOrSpeed == "—" ? Fmt.durationShort(duration) : paceOrSpeed
            let primaryMetric = intervalStep ?? paceMetric
            let detail = [
                Fmt.distance(liveDist),
                session.avgHR.map { "\($0) bpm" } ?? WatchLink.shared.liveMetrics?.heartRate.map { "\($0) bpm" }
            ]
                .compactMap { $0 }
                .filter { $0 != "—" }
                .joined(separator: " · ")

            return WorkoutActivityAttributes.ContentState(
                startedAt: workout.startedAt,
                exerciseName: currentName,
                completedSets: 0,
                totalSets: 0,
                mode: .cardio,
                cardioTitle: kind.title,
                cardioMetric: primaryMetric,
                cardioDetail: detail.isEmpty ? Fmt.durationShort(duration) : detail,
                restEndsAt: nil,
                heartRate: WatchLink.shared.liveMetrics?.heartRate ?? session.avgHR
            )
        }

        return WorkoutActivityAttributes.ContentState(
            startedAt: workout.startedAt,
            exerciseName: currentName,
            nextExerciseName: nextName,
            completedSets: allSets.filter { $0.completedAt != nil }.count,
            totalSets: allSets.count,
            restEndsAt: resting ? timer.endsAt : nil,
            heartRate: WatchLink.shared.liveMetrics?.heartRate
        )
    }
    #else
    func update(workout: WorkoutModel?, exercises: [ExerciseLibraryModel]) {}
    func end() {}
    #endif
}
