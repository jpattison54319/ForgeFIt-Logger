import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Owns post-finish HealthKit fills. Scheduled work carries only value
/// snapshots and stable IDs across suspension; it creates a fresh context and
/// refetches immediately before mutation. Account reset cancels the registry,
/// while the refetch/deletion guards independently protect history deletion
/// and a cancellation that races the HealthKit callback.
@MainActor
final class DeferredWorkoutEnrichmentCoordinator {
    static let shared = DeferredWorkoutEnrichmentCoordinator()

    struct SessionRequest: Sendable {
        let sessionID: UUID
        let start: Date
        let end: Date
        let modality: CardioKind
        let fallbackAvgHR: Int?
        let fallbackMaxHR: Int?
        let importsDistance: Bool
        let providesGPSDistance: Bool
        let hadManualIntervalPlan: Bool
    }

    struct WorkoutRequest: Sendable {
        let workoutID: UUID
        let start: Date
        let end: Date
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func scheduleSession(_ request: SessionRequest, container: ModelContainer) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enrichSession(request, container: container) {
                await HealthService.shared.importSnapshot(
                    from: request.start,
                    to: request.end,
                    modality: request.modality
                )
            }
            self.tasks[token] = nil
        }
        tasks[token] = task
    }

    @discardableResult
    func scheduleWorkout(
        _ request: WorkoutRequest,
        container: ModelContainer
    ) -> Task<Void, Never> {
        scheduleWorkout(request, container: container) {
            await HealthService.shared.importSnapshot(
                from: request.start,
                to: request.end,
                modality: .other
            )
        }
    }

    /// Injectable scheduling seam used to prove reset cancels the registry.
    @discardableResult
    func scheduleWorkout(
        _ request: WorkoutRequest,
        container: ModelContainer,
        snapshot: @escaping @Sendable () async -> CardioSnapshot
    ) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enrichWorkout(request, container: container, snapshot: snapshot)
            self.tasks[token] = nil
        }
        tasks[token] = task
        return task
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Internal injection seam for reset/deletion race tests.
    func enrichSession(
        _ request: SessionRequest,
        container: ModelContainer,
        snapshot: @escaping @Sendable () async -> CardioSnapshot
    ) async {
        let values = await snapshot()
        guard !Task.isCancelled else { return }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = request.sessionID
        guard let session = try? context.fetch(
            FetchDescriptor<CardioSessionModel>(predicate: #Predicate { $0.id == id })
        ).first,
              session.deletedAt == nil,
              session.endedAt != nil else { return }

        if let hr = values.avgHR ?? request.fallbackAvgHR { session.avgHR = hr }
        if let maxHR = values.maxHR ?? request.fallbackMaxHR { session.maxHR = maxHR }
        if let energy = values.activeEnergyKcal { session.activeEnergyKcal = energy }
        if request.importsDistance,
           let distance = values.distanceMeters,
           !(request.providesGPSDistance && session.routePoints.count >= 2) {
            session.distanceMeters = distance
            session.distanceSource = .healthKit
        }
        session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(
            avgHR: session.avgHR,
            durationSeconds: session.durationSeconds
        )
        guard !Task.isCancelled else { return }
        try? context.save()

        // `finalize` follows the same capture-values → await → fresh-refetch
        // contract, so reset during its Health query cannot touch this model.
        await CardioSeriesService.finalize(
            session: session,
            hadManualIntervalPlan: request.hadManualIntervalPlan,
            in: context
        )
    }

    /// Internal injection seam for reset/deletion race tests.
    func enrichWorkout(
        _ request: WorkoutRequest,
        container: ModelContainer,
        snapshot: @escaping @Sendable () async -> CardioSnapshot
    ) async {
        let values = await snapshot()
        guard !Task.isCancelled else { return }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = request.workoutID
        guard let workout = try? context.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })
        ).first,
              workout.deletedAt == nil,
              workout.endedAt != nil else { return }
        if workout.avgHR == nil, let hr = values.avgHR { workout.avgHR = hr }
        if workout.maxHR == nil, let maxHR = values.maxHR { workout.maxHR = maxHR }
        if workout.activeEnergyKcal == nil, let energy = values.activeEnergyKcal {
            workout.activeEnergyKcal = energy
        }
        guard !Task.isCancelled else { return }
        try? context.save()
    }
}
