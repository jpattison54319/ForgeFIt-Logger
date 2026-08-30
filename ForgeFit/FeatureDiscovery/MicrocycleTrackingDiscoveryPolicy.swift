import ForgeData
import Foundation

@MainActor
enum MicrocycleTrackingDiscoveryPolicy {
    static let requiredWorkoutCount = 3
    static let windowDayCount = 9

    static func evaluate(
        workouts: [WorkoutModel],
        routines: [RoutineModel],
        folders: [RoutineFolderModel],
        trackings: [MicrocycleTrackingModel],
        enrolledAt: Date,
        isSuppressed: Bool,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> FeatureDiscoveryDecision {
        guard !isSuppressed else { return .doNotOffer(.suppressed) }
        let retainedTrackings = trackings.filter { $0.deletedAt == nil }
        guard MicrocycleTrackingService.activeTracking(retainedTrackings) == nil else {
            return .doNotOffer(.activeTracking)
        }
        guard retainedTrackings.isEmpty else { return .doNotOffer(.alreadyUsed) }

        let canonicalFolders = RoutineDeduplicator.canonicalFolders(folders)
        let liveFolders = canonicalFolders.filter {
            $0.deletedAt == nil && $0.archivedAt == nil
        }
        let parentIDs = Set(liveFolders.compactMap(\.parentID))
        let eligibleFoldersByID = Dictionary(
            uniqueKeysWithValues: liveFolders.lazy
                .filter { !parentIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        guard !eligibleFoldersByID.isEmpty else {
            return .doNotOffer(.noQualifyingTarget)
        }

        let routineFolderByID = Dictionary(
            uniqueKeysWithValues: RoutineDeduplicator.canonicalRoutines(routines).lazy
                .filter {
                    $0.deletedAt == nil
                        && $0.archivedAt == nil
                        && $0.folderID.flatMap { eligibleFoldersByID[$0] } != nil
                }
                .map { ($0.id, $0.folderID!) }
        )
        guard !routineFolderByID.isEmpty else {
            return .doNotOffer(.noQualifyingTarget)
        }

        let today = calendar.startOfDay(for: now)
        let rollingStart = calendar.date(
            byAdding: .day,
            value: -(windowDayCount - 1),
            to: today
        ) ?? today
        let cutoff = max(rollingStart, enrolledAt)
        var completionsByFolderID: [UUID: [Date]] = [:]
        var seenWorkoutIDs: Set<UUID> = []

        // Home receives workouts newest-first. Stop after crossing the rolling
        // boundary so evaluation cost is bounded by recent human activity.
        for workout in workouts {
            guard let endedAt = workout.endedAt else { continue }
            if workout.startedAt < cutoff, endedAt < cutoff { break }
            guard endedAt >= cutoff,
                  endedAt <= now,
                  workout.deletedAt == nil,
                  !workout.isImportedHistory,
                  seenWorkoutIDs.insert(workout.id).inserted,
                  let routineID = workout.routineID,
                  let folderID = routineFolderByID[routineID] else { continue }
            completionsByFolderID[folderID, default: []].append(endedAt)
        }

        let candidate = completionsByFolderID.compactMap {
            folderID, dates -> (folder: RoutineFolderModel, count: Int, qualifiedAt: Date)? in
            guard dates.count >= requiredWorkoutCount,
                  let folder = eligibleFoldersByID[folderID] else { return nil }
            let chronological = dates.sorted()
            return (folder, dates.count, chronological[requiredWorkoutCount - 1])
        }
        .max {
            if $0.qualifiedAt != $1.qualifiedAt { return $0.qualifiedAt < $1.qualifiedAt }
            return $0.folder.id.uuidString < $1.folder.id.uuidString
        }

        guard let candidate else { return .doNotOffer(.noQualifyingTarget) }
        return .offer(FeatureDiscoveryOffer(
            feature: .microcycleTracking,
            targetID: candidate.folder.id,
            title: "Track your microcycle",
            whyNow: "You’ve trained \(candidate.folder.name) \(candidate.count) times in the last 9 days.",
            benefit: "Track what’s due and see each cycle’s progress.",
            qualifiedAt: candidate.qualifiedAt
        ))
    }
}
