import ForgeCore
import Foundation

/// Pure model ↔ DTO projection for the sanitized backup. The boundary is
/// layered: DTOs omit Health fields, while this mapper removes whole
/// HealthKit-imported workouts and values whose shared model property has
/// HealthKit provenance. The inverse (`workoutModel`) materializes models
/// with their ORIGINAL ids — restore dedup and cross-layer UUID references
/// depend on that.
public enum BackupMapper {

    // MARK: - Model → DTO (export)

    public static func file(
        workouts: [WorkoutModel],
        batches: [WorkoutImportBatchModel],
        exerciseNames: [UUID: String],
        preferences: [String: BackupPreferenceValue],
        userID: UUID,
        appVersion: String?,
        microcycleTrackings: [MicrocycleTrackingModel] = [],
        microcycleWindows: [MicrocycleWindowModel] = [],
        restDays: [RestDayModel] = [],
        now: Date = Date()
    ) -> ForgeFitBackupFile {
        ForgeFitBackupFile(
            exportedAt: now,
            userID: userID,
            appVersion: appVersion,
            preferences: preferences,
            workouts: workouts
                // Apple Health imports can be rebuilt from the user's Health
                // store on the destination device. Their entire record is
                // Health-derived, so none of it belongs in iCloud.
                .filter { !isHealthKitImportedWorkout($0) }
                .sorted { $0.startedAt < $1.startedAt }
                .map { backupWorkout(from: $0, exerciseNames: exerciseNames) },
            importBatches: batches.map(backupBatch(from:)),
            microcycleTrackings: microcycleTrackings.map(backupTracking(from:)),
            microcycleWindows: microcycleWindows.map(backupWindow(from:)),
            restDays: restDays.map(backupRestDay(from:))
        )
    }

    public static func backupWorkout(from workout: WorkoutModel, exerciseNames: [UUID: String]) -> BackupWorkout {
        BackupWorkout(
            id: workout.id,
            routineID: workout.routineID,
            title: workout.title,
            startedAt: workout.startedAt,
            endedAt: workout.endedAt,
            sourceDevice: workout.sourceDevice,
            notes: workout.notes,
            conditioningPlanSnapshotJSON: workout.conditioningPlanSnapshotJSON,
            conditioningProgressJSON: workout.conditioningProgressJSON,
            conditioningResultJSON: workout.conditioningResultJSON,
            wholeSessionRPE: workout.wholeSessionRPE,
            wholeSessionRPERatedAt: workout.wholeSessionRPERatedAt,
            wholeSessionRPEProtocolVersion: workout.wholeSessionRPEProtocolVersion,
            externalSource: workout.externalSource,
            externalID: workout.externalWorkoutID,
            importFingerprint: workout.importFingerprint,
            importBatchID: workout.importBatchID,
            xpAwardedAmount: workout.xpAwardedAmount,
            xpAwardedAt: workout.xpAwardedAt,
            createdAt: workout.createdAt,
            updatedAt: workout.updatedAt,
            deletedAt: workout.deletedAt,
            exercises: workout.exercises
                .sorted { $0.position < $1.position }
                .map { backupExercise(from: $0, exerciseNames: exerciseNames) },
            blocks: workout.blocks
                .sorted { $0.position < $1.position }
                .map(backupBlock(from:)),
            cardioSessions: workout.cardioSessions
                .sorted { $0.startedAt < $1.startedAt }
                .map(backupCardioSession(from:))
        )
    }

    private static func backupExercise(from exercise: WorkoutExerciseModel, exerciseNames: [UUID: String]) -> BackupWorkoutExercise {
        BackupWorkoutExercise(
            id: exercise.id,
            exerciseID: exercise.exerciseID,
            name: exerciseNames[exercise.exerciseID] ?? "",
            position: exercise.position,
            supersetGroup: exercise.supersetGroup,
            notes: exercise.notes,
            notePinned: exercise.notePinned,
            restSeconds: exercise.restSeconds,
            microRestSeconds: exercise.microRestSeconds,
            intervalPlanJSON: exercise.intervalPlanJSON,
            yogaFlowJSON: exercise.yogaFlowJSON,
            generatedByWorkoutBlockID: exercise.generatedByWorkoutBlockID,
            sourceRoutineExerciseID: exercise.sourceRoutineExerciseID,
            createdAt: exercise.createdAt,
            updatedAt: exercise.updatedAt,
            sets: exercise.sets.sorted { $0.position < $1.position }.map(backupSet(from:))
        )
    }

    private static func backupBlock(from block: WorkoutBlockModel) -> BackupWorkoutBlock {
        BackupWorkoutBlock(
            id: block.id,
            kindRaw: block.kindRaw,
            position: block.position,
            planSnapshotJSON: block.planSnapshotJSON,
            progressJSON: block.progressJSON,
            resultJSON: block.resultJSON,
            sourceRoutineBlockID: block.sourceRoutineBlockID,
            createdAt: block.createdAt,
            updatedAt: block.updatedAt
        )
    }

    private static func backupSet(from set: SetModel) -> BackupSet {
        BackupSet(
            id: set.id,
            position: set.position,
            setType: set.setTypeRaw,
            weightMode: set.weightModeRaw,
            reps: set.reps,
            weightKg: set.weight,
            rpe: set.rpe,
            rir: set.rir,
            durationSeconds: set.durationSeconds,
            holdSeconds: set.holdSeconds,
            partialReps: set.partialReps,
            addedWeight: set.addedWeight,
            assistanceWeight: set.assistanceWeight,
            isUnilateral: set.isUnilateral,
            implementWeight: set.implementWeight,
            limbCount: set.limbCount,
            isEccentric: set.isEccentric,
            isPaused: set.isPaused,
            machineSettingsJSON: set.machineSettingsJSON,
            sourceRoutineSetID: set.sourceRoutineSetID,
            miniRepsJSON: set.miniRepsJSON,
            side2Reps: set.side2Reps,
            side2MiniRepsJSON: set.side2MiniRepsJSON,
            plannedMiniSetCount: set.plannedMiniSetCount,
            plannedMiniRepsJSON: set.plannedMiniRepsJSON,
            prescribedLoadModeRaw: set.prescribedLoadModeRaw,
            prescribed1RMPercentLow: set.prescribed1RMPercentLow,
            prescribed1RMPercentHigh: set.prescribed1RMPercentHigh,
            prescribed1RMBaselineKg: set.prescribed1RMBaselineKg,
            prescribedLoadLowKg: set.prescribedLoadLowKg,
            prescribedLoadHighKg: set.prescribedLoadHighKg,
            completedAt: set.completedAt,
            createdAt: set.createdAt,
            updatedAt: set.updatedAt
        )
    }

    private static func backupCardioSession(from session: CardioSessionModel) -> BackupCardioSession {
        let safeSplits = session.splits.filter { !$0.autoDetected }
        return BackupCardioSession(
            id: session.id,
            workoutExerciseID: session.workoutExerciseID,
            workoutBlockID: session.workoutBlockID,
            modality: session.modality,
            startedAt: session.startedAt,
            liveStartedAt: session.liveStartedAt,
            endedAt: session.endedAt,
            sourceDevice: session.sourceDevice,
            durationSeconds: session.durationSeconds,
            distanceMeters: backupDistance(from: session),
            effort: session.effort,
            avgPaceSecondsPerKm: session.avgPaceSecondsPerKm,
            split500mSeconds: session.split500mSeconds,
            strokeRate: session.strokeRate,
            avgPowerWatts: session.avgPowerWatts,
            avgCadence: session.avgCadence,
            resistanceLevel: session.resistanceLevel,
            inclinePercent: session.inclinePercent,
            elevationGainMeters: session.elevationGainMeters,
            // Auto-detected intervals can be derived from HealthKit heart-rate
            // samples. Omit their applied marker with the rows so restore can
            // re-run detection only after local Health enrichment.
            intervalsAutoApplied: false,
            yogaStyleRaw: session.yogaStyleRaw,
            posesCompleted: session.logicalYogaPosesCompleted,
            poolLengthMeters: session.poolLengthMeters,
            lengthsCompleted: session.lengthsCompleted,
            totalStrokes: session.totalStrokes,
            strokeStyleRaw: session.strokeStyleRaw,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            deletedAt: session.deletedAt,
            splits: safeSplits.sorted { $0.index < $1.index }.map(backupSplit(from:)),
            routePoints: session.routePoints
                .sorted { $0.timestamp < $1.timestamp }
                .map(backupRoutePoint(from:))
        )
    }

    private static func isHealthKitImportedWorkout(_ workout: WorkoutModel) -> Bool {
        workout.sourceDevice?.hasPrefix("healthkit") == true
    }

    /// A generic distance value is not proof of safe provenance: HealthKit
    /// fills the same local property used by manual/machine entry. New writes
    /// carry an explicit source. For legacy rows without one, preserve only
    /// cases whose local/file provenance is independently evident.
    private static func backupDistance(from session: CardioSessionModel) -> Double? {
        guard let distance = session.distanceMeters else { return nil }
        switch session.distanceSource {
        case .healthKit:
            return nil
        case .userEntered, .route, .watchInput, .importedFile, .restoredBackup:
            return distance
        case nil:
            if session.routePoints.count >= 2 { return distance }
            if session.poolLengthMeters != nil, session.lengthsCompleted != nil { return distance }
            if session.sourceDevice?.hasPrefix("import-") == true
                || session.sourceDevice == "gpx-import" {
                return distance
            }
            // Pre-provenance post-hoc/manual records never entered a live
            // HealthKit window. A legacy live session without a route is
            // ambiguous and is conservatively omitted.
            return session.liveStartedAt == nil ? distance : nil
        }
    }

    private static func backupSplit(from split: CardioSplitModel) -> BackupCardioSplit {
        BackupCardioSplit(
            id: split.id,
            index: split.index,
            distanceMeters: split.distanceMeters,
            durationSeconds: split.durationSeconds,
            paceSecondsPerKm: split.paceSecondsPerKm,
            elevationGainMeters: split.elevationGainMeters,
            label: split.label,
            autoDetected: split.autoDetected,
            startedAt: split.startedAt,
            endedAt: split.endedAt
        )
    }

    private static func backupRoutePoint(from point: CardioRoutePointModel) -> BackupRoutePoint {
        BackupRoutePoint(
            t: point.timestamp,
            lat: round6(point.latitude),
            lon: round6(point.longitude),
            alt: point.altitudeMeters.map(round2),
            acc: point.horizontalAccuracyMeters.map(round2),
            spd: point.speedMetersPerSecond.map(round2)
        )
    }

    private static func backupBatch(from batch: WorkoutImportBatchModel) -> BackupImportBatch {
        BackupImportBatch(
            id: batch.id,
            source: batch.source,
            fileName: batch.fileName,
            importedCount: batch.importedCount,
            skippedDuplicateCount: batch.skippedDuplicateCount,
            warningCount: batch.warningCount,
            startedAt: batch.startedAt,
            endedAt: batch.endedAt,
            createdAt: batch.createdAt
        )
    }

    public static func backupTracking(from tracking: MicrocycleTrackingModel) -> BackupMicrocycleTracking {
        BackupMicrocycleTracking(
            id: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            anchorDate: tracking.anchorDate,
            durationDays: tracking.durationDays,
            timeZoneIdentifier: tracking.timeZoneIdentifier,
            stateRaw: tracking.stateRaw,
            showsOnHome: tracking.showsOnHome,
            showsFolderHeader: tracking.showsFolderHeader,
            endedAt: tracking.endedAt,
            createdAt: tracking.createdAt,
            updatedAt: tracking.updatedAt,
            deletedAt: tracking.deletedAt
        )
    }

    public static func backupWindow(from window: MicrocycleWindowModel) -> BackupMicrocycleWindow {
        BackupMicrocycleWindow(
            id: window.id,
            trackingID: window.trackingID,
            folderID: window.folderID,
            folderName: window.folderName,
            index: window.index,
            startsAt: window.startsAt,
            endsAt: window.endsAt,
            timeZoneIdentifier: window.timeZoneIdentifier,
            routineSnapshotJSON: window.routineSnapshotJSON,
            dayAssignmentSnapshotJSON: window.dayAssignmentSnapshotJSON,
            createdAt: window.createdAt,
            updatedAt: window.updatedAt,
            deletedAt: window.deletedAt
        )
    }

    public static func backupRestDay(from restDay: RestDayModel) -> BackupRestDay {
        BackupRestDay(
            id: restDay.id,
            date: restDay.date,
            timeZoneIdentifier: restDay.timeZoneIdentifier,
            createdAt: restDay.createdAt,
            updatedAt: restDay.updatedAt,
            deletedAt: restDay.deletedAt
        )
    }

    private static func round6(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: - DTO → Model (restore)

    public static func trackingModel(
        from backup: BackupMicrocycleTracking,
        userID: UUID
    ) -> MicrocycleTrackingModel {
        MicrocycleTrackingModel(
            id: backup.id,
            userID: userID,
            folderID: backup.folderID,
            folderName: backup.folderName,
            anchorDate: backup.anchorDate,
            durationDays: backup.durationDays,
            timeZoneIdentifier: backup.timeZoneIdentifier,
            stateRaw: backup.stateRaw,
            showsOnHome: backup.showsOnHome ?? true,
            showsFolderHeader: backup.showsFolderHeader ?? true,
            endedAt: backup.endedAt,
            createdAt: backup.createdAt,
            updatedAt: backup.updatedAt,
            deletedAt: backup.deletedAt
        )
    }

    public static func windowModel(
        from backup: BackupMicrocycleWindow,
        userID: UUID
    ) -> MicrocycleWindowModel {
        let model = MicrocycleWindowModel(
            id: backup.id,
            userID: userID,
            trackingID: backup.trackingID,
            folderID: backup.folderID,
            folderName: backup.folderName,
            index: backup.index,
            startsAt: backup.startsAt,
            endsAt: backup.endsAt,
            timeZoneIdentifier: backup.timeZoneIdentifier,
            routines: [],
            createdAt: backup.createdAt,
            updatedAt: backup.updatedAt,
            deletedAt: backup.deletedAt
        )
        model.routineSnapshotJSON = backup.routineSnapshotJSON
        model.dayAssignmentSnapshotJSON = backup.dayAssignmentSnapshotJSON ?? "[]"
        return model
    }

    public static func restDayModel(
        from backup: BackupRestDay,
        userID: UUID
    ) -> RestDayModel {
        RestDayModel(
            id: backup.id,
            userID: userID,
            date: backup.date,
            timeZoneIdentifier: backup.timeZoneIdentifier,
            createdAt: backup.createdAt,
            updatedAt: backup.updatedAt,
            deletedAt: backup.deletedAt
        )
    }

    /// Materializes the full workout graph with ORIGINAL ids. Health fields
    /// start nil/empty and are refilled from Apple Health by the enrichment
    /// pass. Derived metrics are recomputed. The caller inserts everything
    /// into a context and wires the relationships' inverse side.
    public static func workoutModel(from backup: BackupWorkout, userID: UUID) -> (workout: WorkoutModel, blocks: [WorkoutBlockModel], exercises: [WorkoutExerciseModel], sets: [SetModel], sessions: [CardioSessionModel], splits: [CardioSplitModel], points: [CardioRoutePointModel]) {
        let workout = WorkoutModel(userID: userID, title: backup.title, startedAt: backup.startedAt)
        workout.id = backup.id
        workout.routineID = backup.routineID
        workout.endedAt = backup.endedAt
        workout.sourceDevice = backup.sourceDevice
        workout.notes = backup.notes
        workout.conditioningPlanSnapshotJSON = backup.conditioningPlanSnapshotJSON
        workout.conditioningProgressJSON = backup.conditioningProgressJSON
        workout.conditioningResultJSON = backup.conditioningResultJSON
        workout.wholeSessionRPE = backup.wholeSessionRPE
        workout.wholeSessionRPERatedAt = backup.wholeSessionRPERatedAt
        workout.wholeSessionRPEProtocolVersion = backup.wholeSessionRPEProtocolVersion
        workout.externalSource = backup.externalSource
        workout.externalWorkoutID = backup.externalID
        workout.importFingerprint = backup.importFingerprint
        workout.importBatchID = backup.importBatchID
        workout.xpAwardedAmount = backup.xpAwardedAmount
        workout.xpAwardedAt = backup.xpAwardedAt
        workout.createdAt = backup.createdAt
        workout.updatedAt = backup.updatedAt
        workout.deletedAt = backup.deletedAt

        var exercises: [WorkoutExerciseModel] = []
        var sets: [SetModel] = []
        for backupExercise in backup.exercises {
            let exercise = WorkoutExerciseModel(userID: userID, exerciseID: backupExercise.exerciseID, position: backupExercise.position)
            exercise.id = backupExercise.id
            exercise.supersetGroup = backupExercise.supersetGroup
            exercise.notes = backupExercise.notes
            exercise.notePinned = backupExercise.notePinned
            exercise.restSeconds = backupExercise.restSeconds
            exercise.microRestSeconds = backupExercise.microRestSeconds
            exercise.intervalPlanJSON = backupExercise.intervalPlanJSON
            exercise.yogaFlowJSON = backupExercise.yogaFlowJSON
            exercise.generatedByWorkoutBlockID = backupExercise.generatedByWorkoutBlockID
            exercise.sourceRoutineExerciseID = backupExercise.sourceRoutineExerciseID
            exercise.createdAt = backupExercise.createdAt
            exercise.updatedAt = backupExercise.updatedAt
            exercises.append(exercise)

            for backupSet in backupExercise.sets {
                let set = SetModel(userID: userID, position: backupSet.position)
                set.id = backupSet.id
                set.setTypeRaw = backupSet.setType
                set.weightModeRaw = backupSet.weightMode
                set.reps = backupSet.reps
                set.weight = backupSet.weightKg
                set.rpe = backupSet.rpe
                set.rir = backupSet.rir
                set.durationSeconds = backupSet.durationSeconds
                set.holdSeconds = backupSet.holdSeconds
                set.partialReps = backupSet.partialReps
                set.addedWeight = backupSet.addedWeight
                set.assistanceWeight = backupSet.assistanceWeight
                set.isUnilateral = backupSet.isUnilateral
                set.implementWeight = backupSet.implementWeight
                set.limbCount = backupSet.limbCount
                set.isEccentric = backupSet.isEccentric
                set.isPaused = backupSet.isPaused
                set.machineSettingsJSON = backupSet.machineSettingsJSON
                set.sourceRoutineSetID = backupSet.sourceRoutineSetID
                set.miniRepsJSON = backupSet.miniRepsJSON
                set.side2Reps = backupSet.side2Reps
                set.side2MiniRepsJSON = backupSet.side2MiniRepsJSON
                set.plannedMiniSetCount = backupSet.plannedMiniSetCount
                set.plannedMiniRepsJSON = backupSet.plannedMiniRepsJSON
                set.prescribedLoadModeRaw = backupSet.prescribedLoadModeRaw
                    ?? LoadPrescriptionMode.fixed.rawValue
                set.prescribed1RMPercentLow = backupSet.prescribed1RMPercentLow
                set.prescribed1RMPercentHigh = backupSet.prescribed1RMPercentHigh
                set.prescribed1RMBaselineKg = backupSet.prescribed1RMBaselineKg
                set.prescribedLoadLowKg = backupSet.prescribedLoadLowKg
                set.prescribedLoadHighKg = backupSet.prescribedLoadHighKg
                set.completedAt = backupSet.completedAt
                set.createdAt = backupSet.createdAt
                set.updatedAt = backupSet.updatedAt
                set.recomputeDerivedMetrics()
                sets.append(set)
            }
        }

        let blocks = (backup.blocks ?? []).map { backupBlock -> WorkoutBlockModel in
            let kind = WorkoutBlockKind(rawValue: backupBlock.kindRaw) ?? .conditioning
            return WorkoutBlockModel(
                id: backupBlock.id,
                userID: userID,
                kind: kind,
                position: backupBlock.position,
                planSnapshotJSON: backupBlock.planSnapshotJSON,
                progressJSON: backupBlock.progressJSON,
                resultJSON: backupBlock.resultJSON,
                sourceRoutineBlockID: backupBlock.sourceRoutineBlockID,
                createdAt: backupBlock.createdAt,
                updatedAt: backupBlock.updatedAt
            )
        }

        var sessions: [CardioSessionModel] = []
        var splits: [CardioSplitModel] = []
        var points: [CardioRoutePointModel] = []
        for backupSession in backup.cardioSessions {
            let session = CardioSessionModel(
                userID: userID,
                workoutExerciseID: backupSession.workoutExerciseID,
                workoutBlockID: backupSession.workoutBlockID,
                modality: backupSession.modality,
                startedAt: backupSession.startedAt
            )
            session.id = backupSession.id
            session.liveStartedAt = backupSession.liveStartedAt
            session.endedAt = backupSession.endedAt
            session.sourceDevice = backupSession.sourceDevice
            session.durationSeconds = backupSession.durationSeconds
            session.distanceMeters = backupSession.distanceMeters
            session.distanceSource = backupSession.distanceMeters == nil ? nil : .restoredBackup
            session.effort = backupSession.effort
            session.avgPaceSecondsPerKm = backupSession.avgPaceSecondsPerKm
            session.split500mSeconds = backupSession.split500mSeconds
            session.strokeRate = backupSession.strokeRate
            session.avgPowerWatts = backupSession.avgPowerWatts
            session.avgCadence = backupSession.avgCadence
            session.resistanceLevel = backupSession.resistanceLevel
            session.inclinePercent = backupSession.inclinePercent
            session.elevationGainMeters = backupSession.elevationGainMeters
            session.intervalsAutoApplied = backupSession.intervalsAutoApplied
            session.yogaStyleRaw = backupSession.yogaStyleRaw
            session.posesCompleted = backupSession.posesCompleted
            session.poolLengthMeters = backupSession.poolLengthMeters
            session.lengthsCompleted = backupSession.lengthsCompleted
            session.totalStrokes = backupSession.totalStrokes
            session.strokeStyleRaw = backupSession.strokeStyleRaw
            session.createdAt = backupSession.createdAt
            session.updatedAt = backupSession.updatedAt
            session.deletedAt = backupSession.deletedAt
            sessions.append(session)

            for backupSplit in backupSession.splits {
                let split = CardioSplitModel(
                    userID: userID,
                    cardioSessionID: backupSession.id,
                    index: backupSplit.index,
                    distanceMeters: backupSplit.distanceMeters,
                    durationSeconds: backupSplit.durationSeconds,
                    paceSecondsPerKm: backupSplit.paceSecondsPerKm,
                    elevationGainMeters: backupSplit.elevationGainMeters,
                    startedAt: backupSplit.startedAt,
                    endedAt: backupSplit.endedAt
                )
                split.id = backupSplit.id
                split.label = backupSplit.label
                split.autoDetected = backupSplit.autoDetected
                splits.append(split)
            }

            for backupPoint in backupSession.routePoints {
                let point = CardioRoutePointModel(
                    userID: userID,
                    cardioSessionID: backupSession.id,
                    timestamp: backupPoint.t,
                    latitude: backupPoint.lat,
                    longitude: backupPoint.lon,
                    altitudeMeters: backupPoint.alt,
                    horizontalAccuracyMeters: backupPoint.acc,
                    speedMetersPerSecond: backupPoint.spd
                )
                points.append(point)
            }
        }

        return (workout, blocks, exercises, sets, sessions, splits, points)
    }

    public static func batchModel(from backup: BackupImportBatch, userID: UUID) -> WorkoutImportBatchModel {
        let batch = WorkoutImportBatchModel(
            userID: userID,
            source: backup.source,
            fileName: backup.fileName ?? "",
            importedCount: backup.importedCount,
            skippedDuplicateCount: backup.skippedDuplicateCount,
            warningCount: backup.warningCount,
            startedAt: backup.startedAt,
            endedAt: backup.endedAt
        )
        batch.id = backup.id
        batch.createdAt = backup.createdAt
        return batch
    }

    // MARK: - Encoding policy

    /// Deterministic bytes: ISO-8601 dates, sorted keys — same file for the
    /// same data, useful diffs, stable absence-tests.
    public static func encode(_ file: ForgeFitBackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> ForgeFitBackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ForgeFitBackupFile.self, from: data)
    }
}
