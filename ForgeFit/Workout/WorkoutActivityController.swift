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
        let pureCardio = workout.cardioSessions.contains { !$0.isYogaSession } && !hasStrengthSets
        let pureYoga = !workout.cardioSessions.isEmpty
            && workout.cardioSessions.allSatisfy(\.isYogaSession)
            && !hasStrengthSets
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

        // Guided yoga headline: the current pose with a native countdown.
        // Any yoga session in the workout takes the lock screen while it's
        // live — a mixed lift+yoga session is *doing yoga right now*.
        if let yogaSession = workout.cardioSessions.first(where: { $0.isYogaSession && $0.endedAt == nil && $0.liveStartedAt != nil }) {
            let runner = YogaFlowRunnerHub.shared.runner(for: yogaSession.id)
            let style = yogaSession.resolvedYogaStyle
            let poseName = runner?.currentStep?.displayName
            let position = runner.map { "Pose \(min($0.currentIndex + 1, $0.steps.count)) of \($0.steps.count)" }
            let nextName = runner?.nextStep.map { "Next: \($0.displayName)" }
            let detail = [position, nextName].compactMap { $0 }.joined(separator: " · ")
            let duration = max(0, Int(Date().timeIntervalSince(yogaSession.liveStartedAt ?? yogaSession.startedAt)))

            return WorkoutActivityAttributes.ContentState(
                startedAt: workout.startedAt,
                exerciseName: poseName ?? currentName,
                completedSets: 0,
                totalSets: 0,
                mode: .yoga,
                cardioTitle: "\(style.title) Yoga",
                cardioMetric: poseName ?? Fmt.durationShort(duration),
                cardioDetail: detail.isEmpty ? Fmt.durationShort(duration) : detail,
                restEndsAt: nil,
                heartRate: WatchLink.shared.liveMetrics?.heartRate ?? yogaSession.avgHR,
                poseEndsAt: (runner?.isPaused == false) ? runner?.stepEndsAt : nil
            )
        }

        // Pure yoga workout not currently mid-pose (about to start, between
        // segments, or done): a calm session card instead of cardio's "Other".
        if pureYoga, let session = workout.cardioSessions.first {
            let style = session.resolvedYogaStyle
            let duration = session.durationSeconds
                ?? max(0, Int(Date().timeIntervalSince(session.liveStartedAt ?? workout.startedAt)))
            return WorkoutActivityAttributes.ContentState(
                startedAt: workout.startedAt,
                exerciseName: currentName,
                completedSets: 0,
                totalSets: 0,
                mode: .yoga,
                cardioTitle: "\(style.title) Yoga",
                cardioMetric: Fmt.durationShort(duration),
                cardioDetail: session.liveStartedAt == nil ? "Ready to begin" : Fmt.durationShort(duration),
                restEndsAt: nil,
                heartRate: WatchLink.shared.liveMetrics?.heartRate ?? session.avgHR
            )
        }

        if pureCardio, let session = workout.cardioSessions.first(where: { !$0.isYogaSession }) {
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
