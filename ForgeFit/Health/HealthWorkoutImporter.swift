import Foundation
import ForgeCore
import ForgeData
import SwiftData

#if canImport(HealthKit)
import CoreLocation
import HealthKit
#endif

@MainActor
final class HealthWorkoutImporter {
    static let shared = HealthWorkoutImporter()

    private init() {}

    @discardableResult
    func importRecent(in context: ModelContext, days: Int = 60) async -> Int {
        #if canImport(HealthKit)
        guard HealthService.shared.isAvailable else { return 0 }
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return 0 }
        let healthStore = HKHealthStore()
        let healthWorkouts = await fetchWorkouts(from: start, to: end, store: healthStore)
            .filter { !isForgeFitSource($0) }
            .sorted { $0.endDate < $1.endDate }
        guard !healthWorkouts.isEmpty else { return 0 }

        let existing = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        let existingHealthUUIDs = Set(existing.compactMap(\.hkWorkoutUUID))
        var imported = 0

        for healthWorkout in healthWorkouts {
            guard !existingHealthUUIDs.contains(healthWorkout.uuid),
                  !hasSimilarLocalWorkout(to: healthWorkout, in: existing) else { continue }

            let avgHR = await heartRate(.discreteAverage, for: healthWorkout, store: healthStore).map { Int($0.rounded()) }
            let maxHR = await heartRate(.discreteMax, for: healthWorkout, store: healthStore).map { Int($0.rounded()) }
            let durationSeconds = max(1, Int(healthWorkout.duration.rounded()))
            let energyKcal = activeEnergyKcal(for: healthWorkout)
            let distanceMeters = healthWorkout.totalDistance?.doubleValue(for: .meter())
            let zones = CardioMetrics.estimatedZoneSecondsArray(avgHR: avgHR, durationSeconds: durationSeconds)
            let source = sourceLabel(for: healthWorkout)
            let kind = cardioKind(for: healthWorkout.workoutActivityType)

            let workoutExercise = kind.exerciseID.map {
                WorkoutExerciseModel(userID: ForgeFitDemo.userID, exerciseID: $0, position: 0)
            }
            let cardioSession = kind.cardioKind.map {
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
                    activeEnergyKcal: energyKcal,
                    avgHR: avgHR,
                    maxHR: maxHR,
                    hrZoneSeconds: zones,
                    effort: estimatedEffort(avgHR: avgHR),
                    tss: estimatedTSS(durationSeconds: durationSeconds, avgHR: avgHR)
                )
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
            context.insert(workout)
            if let cardioSession, kind.cardioKind?.supportsOutdoorRoute == true {
                let locations = await routeLocations(for: healthWorkout, store: healthStore)
                CardioRouteMath.replaceRoute(for: cardioSession, locations: locations, in: context)
            }
            imported += 1
        }

        if imported > 0 { try? context.save() }
        return imported
        #else
        return 0
        #endif
    }

    #if canImport(HealthKit)
    private func fetchWorkouts(from start: Date, to end: Date, store: HKHealthStore) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    private func heartRate(_ option: HKStatisticsOptions, for workout: HKWorkout, store: HKHealthStore) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: option) { _, stats, _ in
                let quantity = option == .discreteMax ? stats?.maximumQuantity() : stats?.averageQuantity()
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func activeEnergyKcal(for workout: HKWorkout) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private func routeLocations(for workout: HKWorkout, store: HKHealthStore) async -> [CLLocation] {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }

        var routeLocations: [CLLocation] = []
        for route in routes {
            routeLocations.append(contentsOf: await locations(for: route, store: store))
        }
        return routeLocations.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(for route: HKWorkoutRoute, store: HKHealthStore) async -> [CLLocation] {
        await withCheckedContinuation { continuation in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                collected.append(contentsOf: locations ?? [])
                if done {
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
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
        case .yoga: "Yoga"
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

    private func estimatedTSS(durationSeconds: Int, avgHR: Int?) -> Double? {
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
