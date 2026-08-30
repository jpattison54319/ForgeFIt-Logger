import ForgeData
import Foundation

@MainActor
enum FeatureDiscoveryCoordinator {
    static func offer(
        workouts: [WorkoutModel],
        routines: [RoutineModel],
        folders: [RoutineFolderModel],
        trackings: [MicrocycleTrackingModel],
        store: FeatureDiscoveryStore,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> FeatureDiscoveryOffer? {
        let decision = MicrocycleTrackingDiscoveryPolicy.evaluate(
            workouts: workouts,
            routines: routines,
            folders: folders,
            trackings: trackings,
            enrolledAt: store.enrolledAt,
            isSuppressed: store.status(for: .microcycleTracking) != nil,
            now: now,
            calendar: calendar
        )
        guard case .offer(let offer) = decision else { return nil }
        return offer
    }
}
