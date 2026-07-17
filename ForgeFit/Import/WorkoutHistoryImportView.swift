import CoreLocation
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WorkoutHistoryImportView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @State private var showReviewQueue = false

    @State private var pickingFile = false
    @State private var loading = false
    @State private var preview: WorkoutHistoryImportPreview?
    @State private var result: WorkoutHistoryImportCommitResult?
    @State private var errorMessage: String?
    @State private var backups: [BackupRestoreService.BackupInfo] = []
    @State private var restoring = false
    @State private var restoreSummary: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if !backups.isEmpty || restoreSummary != nil {
                        restoreCard
                    }
                    introCard
                    if let result {
                        resultCard(result)
                    } else if let preview {
                        previewCard(preview)
                        exerciseMatchCard(preview)
                        warningsCard(preview)
                        PrimaryButton(title: "Import \(preview.importableCount) Workouts", systemImage: "square.and.arrow.down.fill") {
                            commit(preview)
                        }
                        .disabled(loading || preview.importableCount <= 0)
                    } else {
                        emptyPickerCard
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Import History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $pickingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText, .text, .xml]
                + (UTType(filenameExtension: "gpx").map { [$0] } ?? [])
                + (UTType(filenameExtension: BackupExporter.fileExtension).map { [$0] } ?? []),
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .task { backups = await BackupRestoreService.availableBackups() }
    }

    // MARK: - iCloud backup restore

    private var restoreCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.cardTitle)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(theme.secondaryAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore from iCloud Backup")
                            .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Your training log — heart rate and other Health metrics re-attach from Apple Health where available.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let restoreSummary {
                    Text(restoreSummary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if restoring {
                    ProgressView("Restoring…").tint(theme.accent).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(backups) { backup in
                        Button {
                            restore(backup)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(backup.label) — \(backup.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                                    Text("\(backup.workoutCount) workouts")
                                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func restore(_ backup: BackupRestoreService.BackupInfo) {
        restoring = true
        errorMessage = nil
        Task {
            defer { restoring = false }
            do {
                let file = try await BackupRestoreService.loadFile(at: backup.url)
                let outcome = try BackupRestoreService.commit(file, restorePreferences: true, in: modelContext)
                let enrichment = await HealthEnrichmentService().enrich(
                    workoutIDs: outcome.restoredWorkoutIDs, in: modelContext
                )
                restoreSummary = "Restored \(outcome.restoredWorkouts) workouts"
                    + (outcome.skippedDuplicates > 0 ? " (\(outcome.skippedDuplicates) already here)" : "")
                    + (enrichment.sessionsEnriched + enrichment.workoutsEnriched > 0
                        ? " — Health metrics re-attached where available." : ".")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var introCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.cardTitle)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bring your old workouts")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Hevy CSV, common CSV exports, or ForgeFit JSON")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                Text("ForgeFit previews the file, skips duplicate imports, matches exercises to your library, and converts weights into the app’s internal history format.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    result = nil
                    errorMessage = nil
                    pickingFile = true
                } label: {
                    Label(preview == nil ? "Choose File" : "Choose Different File", systemImage: "doc.badge.plus")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
                .disabled(loading)
            }
        }
    }

    private var emptyPickerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Supported in v1")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                VStack(alignment: .leading, spacing: Space.sm) {
                    supportRow("checkmark.circle.fill", "Hevy workouts.csv gets first-class parsing.")
                    supportRow("checkmark.circle.fill", "Strong, Fitbod, HeavySet, and simple custom CSVs use common header detection.")
                    supportRow("checkmark.circle.fill", "GPX files (Strava, Garmin, any GPS app) import as cardio workouts with route, splits, and heart rate.")
                    supportRow("info.circle.fill", "Excel and Google Sheets should be exported as CSV before importing.")
                }
                if loading {
                    ProgressView("Reading file…")
                        .tint(theme.accent)
                        .foregroundStyle(theme.textSecondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.danger)
                }
            }
        }
    }

    private func supportRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(icon.hasPrefix("checkmark") ? theme.success : theme.textTertiary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Preview")
            Card {
                VStack(spacing: Space.md) {
                    summaryRow("Source", preview.parseResult.source.displayName)
                    Divider().overlay(theme.separator)
                    summaryRow("File", preview.parseResult.fileName)
                    Divider().overlay(theme.separator)
                    summaryRow("Workouts", "\(preview.parseResult.workouts.count)")
                    Divider().overlay(theme.separator)
                    summaryRow("Will import", "\(preview.importableCount)")
                    Divider().overlay(theme.separator)
                    summaryRow("Duplicates skipped", "\(preview.duplicateCount)")
                    if let range = preview.dateRange {
                        Divider().overlay(theme.separator)
                        summaryRow("Date range", "\(range.lowerBound.formatted(.dateTime.month(.abbreviated).day().year())) – \(range.upperBound.formatted(.dateTime.month(.abbreviated).day().year()))")
                    }
                }
            }
        }
    }

    private func exerciseMatchCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Exercise Matching")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    summaryRow("Matched", "\(preview.matches.filter { !$0.willCreateCustom }.count)")
                    Divider().overlay(theme.separator)
                    summaryRow("Create custom", "\(preview.customExerciseCount)")
                    if preview.customExerciseCount > 0 {
                        Divider().overlay(theme.separator)
                        ForEach(preview.matches.filter(\.willCreateCustom).prefix(8)) { match in
                            HStack {
                                Text(match.importedName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Tag(text: "New", color: theme.warmup, background: theme.warmup.opacity(0.15))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func warningsCard(_ preview: WorkoutHistoryImportPreview) -> some View {
        if !preview.parseResult.warnings.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                SectionHeader("Warnings")
                Card {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(preview.parseResult.warnings.prefix(6)) { warning in
                            Text(warning.message)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if preview.parseResult.warnings.count > 6 {
                            Text("+\(preview.parseResult.warnings.count - 6) more")
                                .font(.tag)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    /// The payoff moment (2B): a switcher just moved years of training here —
    /// show it working for them (records, volume trend, next step), not a
    /// bookkeeping receipt.
    private func resultCard(_ result: WorkoutHistoryImportCommitResult) -> some View {
        let records = topRecords(limit: 3)
        let weekly = weeklyVolumes(weeks: 12)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.importedWorkouts > 0 ? "Your \(result.importedWorkouts) workouts are here" : "Import complete")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Your history now powers records, charts, and next-session suggestions.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if !records.isEmpty {
                    Divider().overlay(theme.separator)
                    Text("Records found").font(.tag).foregroundStyle(theme.textSecondary)
                    ForEach(records, id: \.name) { record in
                        HStack(spacing: Space.sm) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.warmup)
                            Text(record.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(record.detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                if weekly.contains(where: { $0 > 0 }) {
                    Divider().overlay(theme.separator)
                    Text("Volume · last 12 weeks").font(.tag).foregroundStyle(theme.textSecondary)
                    volumeBars(weekly)
                }
                Divider().overlay(theme.separator)
                summaryRow("Imported workouts", "\(result.importedWorkouts)")
                summaryRow("Duplicates skipped", "\(result.skippedDuplicates)")
                summaryRow("Custom exercises", "\(result.createdExercises)")
                if result.flaggedForReview > 0 {
                    SecondaryButton(title: "Review \(result.flaggedForReview) matched exercise\(result.flaggedForReview == 1 ? "" : "s")", systemImage: "checklist") {
                        showReviewQueue = true
                    }
                }
                PrimaryButton(title: "Start training", systemImage: "arrow.right") { dismiss() }
            }
        }
        .sheet(isPresented: $showReviewQueue) {
            ReviewImportedExercisesView(workouts: workouts)
        }
    }

    /// Heaviest completed set per exercise, best three — weights are already
    /// in the user's display unit, so no conversion (and no 109.9 lb betrayal
    /// of a 110 lb PR).
    private func topRecords(limit: Int) -> [(name: String, detail: String)] {
        var bestByExercise: [UUID: (weight: Double, reps: Int)] = [:]
        for workout in workouts where workout.endedAt != nil && workout.deletedAt == nil {
            for we in workout.exercises {
                for set in we.sets where set.completedAt != nil {
                    guard let weight = set.weight, weight > 0, let reps = set.reps, reps > 0 else { continue }
                    if weight > (bestByExercise[we.exerciseID]?.weight ?? 0) {
                        bestByExercise[we.exerciseID] = (weight, reps)
                    }
                }
            }
        }
        return bestByExercise
            .sorted { $0.value.weight > $1.value.weight }
            .prefix(limit)
            .compactMap { id, best in
                guard let exercise = exercises.first(where: { $0.id == id }) else { return nil }
                return (exercise.name, "\(Fmt.load(best.weight, unit: Fmt.unit)) × \(best.reps)")
            }
    }

    private func weeklyVolumes(weeks: Int) -> [Double] {
        let calendar = Calendar.current
        let now = Date()
        var buckets = [Double](repeating: 0, count: weeks)
        for workout in workouts where workout.endedAt != nil && workout.deletedAt == nil {
            let weeksAgo = calendar.dateComponents([.weekOfYear], from: workout.startedAt, to: now).weekOfYear ?? 0
            guard weeksAgo >= 0, weeksAgo < weeks else { continue }
            let volume = workout.exercises.flatMap(\.sets)
                .filter { $0.completedAt != nil }
                .reduce(0.0) { $0 + ($1.totalVolume ?? 0) }
            buckets[weeks - 1 - weeksAgo] += volume
        }
        return buckets
    }

    private func volumeBars(_ weekly: [Double]) -> some View {
        let peak = max(weekly.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(weekly.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.accent.opacity(value > 0 ? 0.85 : 0.18))
                    .frame(height: max(4, 40 * (value / peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: Space.md)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            load(url)
        }
    }

    private func load(_ url: URL) {
        loading = true
        errorMessage = nil
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            if url.pathExtension.lowercased() == "gpx" {
                importGPX(data: data, fileName: fileName)
                return
            }
            if url.pathExtension.lowercased() == BackupExporter.fileExtension {
                restore(BackupRestoreService.BackupInfo(
                    url: url, exportedAt: Date(), workoutCount: 0, schemaVersion: 1, label: fileName
                ))
                loading = false
                return
            }
            Task {
                do {
                    preview = try await WorkoutHistoryImportService.preview(
                        data: data,
                        fileName: fileName,
                        workouts: workouts,
                        exercises: exercises
                    )
                } catch {
                    preview = nil
                    errorMessage = error.localizedDescription
                }
                loading = false
            }
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    // MARK: - GPX import (T4-2)

    /// One GPX file = one cardio workout, reconstructed with route points,
    /// auto-splits, a sample series (so zones and best efforts work), and
    /// heart rate when the file carries it. No preview step — a GPS track is
    /// unambiguous in a way CSVs aren't.
    private func importGPX(data: Data, fileName: String) {
        defer { loading = false }
        guard let xml = String(data: data, encoding: .utf8),
              let track = GPXCodec.decode(xml) else {
            errorMessage = "Couldn't read a GPS track from \(fileName)."
            return
        }
        let timed = track.points
            .compactMap { point in point.time.map { (time: $0, point: point) } }
            .sorted { $0.time < $1.time }
        guard timed.count >= 2 else {
            errorMessage = "This GPX track has no timestamps, so the workout can't be reconstructed."
            return
        }
        let start = timed[0].time
        let end = timed[timed.count - 1].time
        guard end > start else {
            errorMessage = "This GPX track's timestamps don't move forward."
            return
        }
        if workouts.contains(where: { $0.deletedAt == nil && abs($0.startedAt.timeIntervalSince(start)) < 300 }) {
            errorMessage = "A workout already exists around \(start.formatted(date: .abbreviated, time: .shortened)) — skipped as a duplicate."
            return
        }

        // Cumulative distance + per-point series (t / hr / meters) — the
        // same shape live sessions store, so zones, best efforts, and the
        // detail charts all light up.
        var cumulative = 0.0
        var previous: CLLocation?
        var samples: [CardioSampleSeries.Sample] = []
        for entry in timed {
            let location = CLLocation(latitude: entry.point.latitude, longitude: entry.point.longitude)
            if let previous { cumulative += location.distance(from: previous) }
            previous = location
            samples.append(CardioSampleSeries.Sample(
                t: Int(entry.time.timeIntervalSince(start).rounded()),
                hr: entry.point.heartRate,
                meters: cumulative
            ))
        }
        let series = CardioSampleSeries(samples: samples)
        let heartRates = timed.compactMap { $0.point.heartRate }
        let avgHR = heartRates.isEmpty ? nil : heartRates.reduce(0, +) / heartRates.count
        let durationSeconds = max(1, Int(end.timeIntervalSince(start)))
        // Modality guess from average speed: sustained ≥ 4 m/s is riding
        // territory, ≥ 1.9 m/s a run, below that a walk.
        let speed = cumulative / Double(durationSeconds)
        let modality: CardioKind = speed >= 4 ? .cycle : (speed >= 1.9 ? .run : .walk)

        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: nil,
            modality: modality.rawValue,
            startedAt: start,
            liveStartedAt: start,
            endedAt: end,
            sourceDevice: "gpx-import",
            durationSeconds: durationSeconds,
            distanceMeters: cumulative > 0 ? cumulative : nil,
            avgHR: avgHR,
            maxHR: heartRates.max(),
            hrZoneSeconds: CardioMetrics.measuredZoneSecondsArray(series: series) ?? []
        )
        session.sampleSeriesJSON = series.encodedJSON()
        session.avgPaceSecondsPerKm = cumulative > 100 ? Double(durationSeconds) / (cumulative / 1000) : nil

        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: track.name ?? "\(modality.title) (GPX)",
            startedAt: start,
            endedAt: end,
            sourceDevice: "gpx-import",
            notes: "Imported from \(fileName)",
            avgHR: avgHR,
            maxHR: heartRates.max()
        )
        modelContext.insert(workout)
        modelContext.insert(session)
        session.workout = workout
        for entry in timed {
            let point = CardioRoutePointModel(
                userID: ForgeFitDemo.userID,
                cardioSessionID: session.id,
                timestamp: entry.time,
                latitude: entry.point.latitude,
                longitude: entry.point.longitude,
                altitudeMeters: entry.point.elevationMeters
            )
            modelContext.insert(point)
            session.routePoints.append(point)
        }
        CardioRouteMath.replaceSplits(for: session, in: modelContext)
        do {
            try modelContext.save()
            result = WorkoutHistoryImportCommitResult(
                importedWorkouts: 1,
                skippedDuplicates: 0,
                createdExercises: 0,
                flaggedForReview: 0,
                warningCount: track.points.count == timed.count ? 0 : 1
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit(_ preview: WorkoutHistoryImportPreview) {
        loading = true
        errorMessage = nil
        do {
            result = try WorkoutHistoryImportService.commit(
                preview: preview,
                workouts: workouts,
                exercises: exercises,
                in: modelContext
            )
            self.preview = nil
            BackupScheduler.shared.noteLogDataChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
