import Foundation
import ForgeCore
import ForgeData
import SwiftData

#if canImport(HealthKit)
import CoreLocation
import HealthKit
#endif

nonisolated enum HealthWorkoutImportPolicy {
    static let minimumAutomaticInterval: TimeInterval = 300

    static func isAutomaticImportDue(
        lastAttempt: Date?,
        now: Date,
        minimumInterval: TimeInterval = minimumAutomaticInterval
    ) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= minimumInterval
    }
}

/// Serializes import requests and persists the automatic-import throttle across
/// cold launches. The actual HealthKit and SwiftData work belongs to a
/// ModelActor below; this actor only owns scheduling state.
actor HealthWorkoutImporter {
    nonisolated static let shared = HealthWorkoutImporter()
    nonisolated static let lastAutomaticAttemptKey = "healthWorkoutImport.lastAutomaticAttempt"

    private struct ImportOperation: Sendable {
        let id: UUID
        let task: Task<Int, Never>
        var wasAutomaticallyRequested: Bool
    }

    private var activeImport: ImportOperation?
    private var cancelledImportTask: Task<Int, Never>?
    private var isLiveWorkoutActive = false
    private var latestPerformanceRevision = 0

    func setLiveWorkoutActive(_ isActive: Bool) {
        applyLiveWorkoutState(isActive)
    }

    func setLiveWorkoutActive(_ isActive: Bool, revision: Int) {
        guard revision >= latestPerformanceRevision else { return }
        latestPerformanceRevision = revision
        applyLiveWorkoutState(isActive)
    }

    private func applyLiveWorkoutState(_ isActive: Bool) {
        isLiveWorkoutActive = isActive
        guard isActive else { return }
        if let operation = activeImport {
            if operation.wasAutomaticallyRequested {
                // `importRecentIfDue` stamps before starting to coalesce
                // foreground notifications. A workout-owned cancellation must
                // undo that stamp so the post-workout maintenance pass can
                // immediately retry instead of waiting five minutes.
                UserDefaults.standard.removeObject(forKey: Self.lastAutomaticAttemptKey)
            }
            cancelledImportTask = operation.task
            operation.task.cancel()
        }
        activeImport = nil
    }

    @discardableResult
    func importRecent(in container: ModelContainer, days: Int = 60) async -> Int {
        await runImport(in: container, days: days, automatic: false)
    }

    @discardableResult
    func importRecentIfDue(
        in container: ModelContainer,
        days: Int = 60,
        now: Date = .now
    ) async -> Int {
        guard !isLiveWorkoutActive else { return 0 }
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.object(forKey: Self.lastAutomaticAttemptKey) as? Date
        guard HealthWorkoutImportPolicy.isAutomaticImportDue(
            lastAttempt: lastAttempt,
            now: now
        ) else { return 0 }

        // Stamp before starting so repeated lifecycle notifications cannot
        // queue identical 60-day scans while this one is awaiting HealthKit.
        defaults.set(now, forKey: Self.lastAutomaticAttemptKey)
        return await runImport(in: container, days: days, automatic: true)
    }

    private func runImport(
        in container: ModelContainer,
        days: Int,
        automatic: Bool
    ) async -> Int {
        guard !isLiveWorkoutActive else { return 0 }
        if let cancelledImportTask {
            _ = await cancelledImportTask.value
            self.cancelledImportTask = nil
            guard !isLiveWorkoutActive, !Task.isCancelled else { return 0 }
        }
        if var activeImport {
            if automatic, !activeImport.wasAutomaticallyRequested {
                activeImport.wasAutomaticallyRequested = true
                self.activeImport = activeImport
            }
            let task = activeImport.task
            return await withTaskCancellationHandler(
                operation: { await task.value },
                onCancel: { task.cancel() }
            )
        }

        // A SwiftData ModelActor adopts the queue on which it is created.
        // Construct it inside the detached task as well as running it there;
        // creating it at an arbitrary caller would allow MainActor inheritance.
        let task = Task.detached(priority: .utility) {
            let worker = HealthWorkoutImportWorker(modelContainer: container)
            return await worker.importRecent(days: days)
        }
        let id = UUID()
        activeImport = ImportOperation(
            id: id,
            task: task,
            wasAutomaticallyRequested: automatic
        )
        let imported = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        if activeImport?.id == id {
            activeImport = nil
        }
        return imported
    }
}

/// A private ModelContext whose serial executor is never MainActor. Model
/// objects stay inside this actor; the caller receives only an integer count.
@ModelActor
actor HealthWorkoutImportWorker {

    #if DEBUG
    func isExecutingOnMainThreadForTesting() -> Bool {
        Self.currentThreadIsMain()
    }

    private nonisolated static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
    #endif

    @discardableResult
    func importRecent(days: Int = 60) async -> Int {
        #if canImport(HealthKit)
        guard HealthService.shared.isAvailable else { return 0 }
        let context = modelContext
        context.autosaveEnabled = false
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return 0 }
        let healthStore = HKHealthStore()
        let healthWorkouts = await fetchWorkouts(from: start, to: end, store: healthStore)
            .filter { !isForgeFitSource($0) }
            .sorted { $0.endDate < $1.endDate }
        guard !Task.isCancelled else { return 0 }
        guard !healthWorkouts.isEmpty else { return 0 }

        var existing = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        var existingHealthUUIDs = Set(existing.compactMap(\.hkWorkoutUUID))
        var imported = 0
        var didCommit = false
        // A workout-start cancellation rolls the private batch back instead
        // of performing a potentially large SwiftData save while the logger
        // is becoming interactive. The automatic throttle is cleared by the
        // scheduling actor, so the entire batch retries after the workout.
        defer {
            if !didCommit { context.rollback() }
        }

        for healthWorkout in healthWorkouts {
            guard !Task.isCancelled else { return 0 }
            guard !existingHealthUUIDs.contains(healthWorkout.uuid),
                  !hasSimilarLocalWorkout(to: healthWorkout, in: existing) else { continue }

            let avgHR = await heartRate(.discreteAverage, for: healthWorkout, store: healthStore).map { Int($0.rounded()) }
            guard !Task.isCancelled else { return 0 }
            let maxHR = await heartRate(.discreteMax, for: healthWorkout, store: healthStore).map { Int($0.rounded()) }
            guard !Task.isCancelled else { return 0 }
            let durationSeconds = max(1, Int(healthWorkout.duration.rounded()))
            let energyKcal = activeEnergyKcal(for: healthWorkout)
            let distanceMeters = healthWorkout.totalDistance?.doubleValue(for: .meter())
            let zones = [Int](repeating: 0, count: 5)
            let source = sourceLabel(for: healthWorkout)
            let kind = cardioKind(for: healthWorkout.workoutActivityType)

            let workoutExercise = kind.exerciseID.map {
                WorkoutExerciseModel(userID: ForgeFitDemo.userID, exerciseID: $0, position: 0)
            }
            let cardioSession: CardioSessionModel?
            if kind.isYoga {
                // Yoga/flexibility import: a yoga session — no distance (the
                // mat doesn't move) and no estimated zone-duration load.
                cardioSession = CardioSessionModel(
                    userID: ForgeFitDemo.userID,
                    workoutExerciseID: nil,
                    modality: CardioSessionModel.yogaModality,
                    startedAt: healthWorkout.startDate,
                    liveStartedAt: healthWorkout.startDate,
                    endedAt: healthWorkout.endDate,
                    hkWorkoutUUID: healthWorkout.uuid,
                    sourceDevice: source,
                    durationSeconds: durationSeconds,
                    activeEnergyKcal: energyKcal,
                    avgHR: avgHR,
                    maxHR: maxHR,
                    hrZoneSeconds: zones,
                    effort: estimatedEffort(avgHR: avgHR),
                    yogaStyleRaw: kind.yogaStyle?.rawValue
                )
            } else {
                cardioSession = kind.cardioKind.map {
                    CardioSessionModel(
                        userID: ForgeFitDemo.userID,
                        workoutExerciseID: workoutExercise?.id,
                        modality: $0.rawValue,
                        startedAt: healthWorkout.startDate,
                        liveStartedAt: healthWorkout.startDate,
                        endedAt: healthWorkout.endDate,
                        hkWorkoutUUID: healthWorkout.uuid,
                        sourceDevice: source,
                        durationSeconds: durationSeconds,
                        distanceMeters: distanceMeters,
                        distanceSource: distanceMeters == nil ? nil : .healthKit,
                        activeEnergyKcal: energyKcal,
                        avgHR: avgHR,
                        maxHR: maxHR,
                        hrZoneSeconds: zones,
                        effort: estimatedEffort(avgHR: avgHR),
                        tss: estimatedZoneDurationLoad(durationSeconds: durationSeconds, avgHR: avgHR)
                    )
                }
            }

            let workout = WorkoutModel(
                userID: ForgeFitDemo.userID,
                title: title(for: healthWorkout.workoutActivityType),
                startedAt: healthWorkout.startDate,
                endedAt: healthWorkout.endDate,
                hkWorkoutUUID: healthWorkout.uuid,
                sourceDevice: source,
                notes: "Imported from Apple Health",
                avgHR: avgHR,
                maxHR: maxHR,
                activeEnergyKcal: energyKcal,
                hrZoneSeconds: zones,
                exercises: workoutExercise.map { [$0] } ?? [],
                cardioSessions: cardioSession.map { [$0] } ?? []
            )
            let importedRoute: [CLLocation]?
            if cardioSession != nil, kind.cardioKind?.supportsOutdoorRoute == true {
                importedRoute = await routeLocations(for: healthWorkout, store: healthStore)
                guard !Task.isCancelled else { return 0 }
            } else {
                importedRoute = nil
            }

            guard !Task.isCancelled else { return 0 }
            context.insert(workout)
            existingHealthUUIDs.insert(healthWorkout.uuid)
            existing.append(workout)
            if let cardioSession, let importedRoute {
                CardioRouteMath.replaceRoute(for: cardioSession, locations: importedRoute, in: context)
            }
            imported += 1
        }

        guard !Task.isCancelled else { return 0 }
        do {
            if imported > 0 { try context.save() }
            didCommit = true
            return imported
        } catch {
            // Never report an imported count for objects that did not become
            // durable, and never leave this private batch pending to be swept
            // into an unrelated later save.
            return 0
        }
        #else
        return 0
        #endif
    }

    #if canImport(HealthKit)
    private func fetchWorkouts(from start: Date, to end: Date, store: HKHealthStore) async -> [HKWorkout] {
        guard !Task.isCancelled else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return await HealthService.runCancellableQuery(
            store: store,
            cancelledValue: []
        ) { finish in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                finish((samples as? [HKWorkout]) ?? [])
            }
        }
    }

    private func heartRate(_ option: HKStatisticsOptions, for workout: HKWorkout, store: HKHealthStore) async -> Double? {
        guard !Task.isCancelled,
              let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await HealthService.runCancellableQuery(store: store, cancelledValue: nil) { finish in
            HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: option) { _, stats, _ in
                let quantity = option == .discreteMax ? stats?.maximumQuantity() : stats?.averageQuantity()
                finish(quantity?.doubleValue(for: unit))
            }
        }
    }

    private func activeEnergyKcal(for workout: HKWorkout) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private func routeLocations(for workout: HKWorkout, store: HKHealthStore) async -> [CLLocation] {
        guard !Task.isCancelled else { return [] }
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = await HealthService.runCancellableQuery(
            store: store,
            cancelledValue: []
        ) { finish in
            HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                finish((samples as? [HKWorkoutRoute]) ?? [])
            }
        }

        var routeLocations: [CLLocation] = []
        for route in routes {
            guard !Task.isCancelled else { return [] }
            routeLocations.append(contentsOf: await locations(for: route, store: store))
        }
        guard !Task.isCancelled else { return [] }
        return routeLocations.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(for route: HKWorkoutRoute, store: HKHealthStore) async -> [CLLocation] {
        guard !Task.isCancelled else { return [] }
        return await HealthService.runCancellableQuery(store: store, cancelledValue: []) { finish in
            var collected: [CLLocation] = []
            return HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                collected.append(contentsOf: locations ?? [])
                if done {
                    finish(collected)
                }
            }
        }
    }

    private func isForgeFitSource(_ workout: HKWorkout) -> Bool {
        let source = workout.sourceRevision.source
        let appBundleID = Bundle.main.bundleIdentifier
        let bundleMatches = appBundleID.map { source.bundleIdentifier == $0 } ?? false
        let nameMatches = source.name.localizedCaseInsensitiveContains("ForgeFit")
            || source.bundleIdentifier.localizedCaseInsensitiveContains("ForgeFit")
        return bundleMatches || nameMatches
    }

    /// A local workout covering the same time window suppresses import —
    /// INCLUDING soft-deleted ones. If the user deleted a workout, the
    /// overlapping Apple Health record must not resurrect it ("I deleted
    /// today's workout but it still says I trained today").
    private func hasSimilarLocalWorkout(to healthWorkout: HKWorkout, in existing: [WorkoutModel]) -> Bool {
        existing.contains { local in
            guard local.hkWorkoutUUID == nil,
                  let localEnd = local.endedAt else { return false }
            let startDelta = abs(local.startedAt.timeIntervalSince(healthWorkout.startDate))
            let endDelta = abs(localEnd.timeIntervalSince(healthWorkout.endDate))
            return startDelta <= 120 && endDelta <= 120
        }
    }

    private func sourceLabel(for workout: HKWorkout) -> String {
        let source = workout.sourceRevision.source
        let name = source.name.replacingOccurrences(of: " ", with: "-").lowercased()
        if name.isEmpty { return "healthkit" }
        return "healthkit-\(name)"
    }

    private struct ImportedKind {
        var cardioKind: CardioKind?
        var exerciseID: UUID?
        /// Yoga/flexibility activity: imports as a yoga session (its own
        /// pillar) instead of a generic titled workout.
        var isYoga = false
        var yogaStyle: YogaStyle?
    }

    private func cardioKind(for activity: HKWorkoutActivityType) -> ImportedKind {
        switch activity {
        case .running:
            return ImportedKind(cardioKind: .run, exerciseID: GlobalExerciseLibrary.treadmillRunID)
        case .walking, .hiking:
            return ImportedKind(cardioKind: .walk, exerciseID: GlobalExerciseLibrary.treadmillRunID)
        case .cycling:
            return ImportedKind(cardioKind: .cycle, exerciseID: GlobalExerciseLibrary.indoorCycleID)
        case .rowing:
            return ImportedKind(cardioKind: .row, exerciseID: GlobalExerciseLibrary.rowErgID)
        case .elliptical:
            return ImportedKind(cardioKind: .elliptical, exerciseID: nil)
        case .stairClimbing:
            return ImportedKind(cardioKind: .stair, exerciseID: nil)
        case .jumpRope:
            return ImportedKind(cardioKind: .jumpRope, exerciseID: nil)
        case .skatingSports:
            return ImportedKind(cardioKind: .skate, exerciseID: nil)
        case .swimming:
            return ImportedKind(cardioKind: .swim, exerciseID: nil)
        case .highIntensityIntervalTraining, .crossTraining:
            return ImportedKind(cardioKind: .other, exerciseID: nil)
        case .yoga, .mindAndBody:
            return ImportedKind(cardioKind: nil, exerciseID: nil, isYoga: true)
        case .flexibility:
            // Stretching sessions count toward the flexibility pillar as
            // gentle (recovery-classified) practice.
            return ImportedKind(cardioKind: nil, exerciseID: nil, isYoga: true, yogaStyle: .gentle)
        default:
            return ImportedKind(cardioKind: nil, exerciseID: nil)
        }
    }

    private func title(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: "Run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .cycling: "Ride"
        case .rowing: "Row"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair Climb"
        case .jumpRope: "Jump Rope"
        case .skatingSports: "Skate"
        case .swimming: "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength Training"
        case .coreTraining: "Core Training"
        case .highIntensityIntervalTraining: "HIIT"
        case .crossTraining: "Cross Training"
        case .yoga, .mindAndBody: "Yoga"
        case .flexibility: "Stretching"
        case .pilates: "Pilates"
        default: "Apple Health Workout"
        }
    }

    private func estimatedEffort(avgHR: Int?) -> Int? {
        guard let avgHR else { return nil }
        return switch HRZone.zone(forAvgHR: avgHR) {
        case 1: 3
        case 2: 4
        case 3: 6
        case 4: 8
        default: 9
        }
    }

    private func estimatedZoneDurationLoad(durationSeconds: Int, avgHR: Int?) -> Double? {
        guard let avgHR else { return nil }
        let minutes = Double(durationSeconds) / 60
        let multiplier = switch HRZone.zone(forAvgHR: avgHR) {
        case 1: 0.35
        case 2: 0.55
        case 3: 0.75
        case 4: 0.95
        default: 1.1
        }
        return minutes * multiplier
    }
    #endif
}
