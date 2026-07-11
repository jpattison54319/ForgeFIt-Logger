import ForgeCore
import ForgeData
import MapKit
import SwiftData
import SwiftUI

/// Identifiable wrapper so the share sheet can be driven by `.sheet(item:)`.
private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Identifiable wrapper so the interval-splits editor can be driven by
/// `.sheet(item:)` (SwiftData models aren't Identifiable for that API).
private struct EditSplitsTarget: Identifiable {
    let id = UUID()
    let session: CardioSessionModel
}

/// Identifiable wrapper so tapping the inline route thumbnail can drive a
/// full-screen expanded map via `.sheet(item:)`.
private struct ExpandedRouteTarget: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let kind: CardioKind
}

/// Lightweight editor for a cardio session's laps: rename or delete individual
/// segments. Used to confirm/adjust auto-detected intervals.
private struct IntervalSplitsEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: CardioSessionModel
    @State private var saveError: String?

    private var laps: [CardioSplitModel] {
        session.splits.sorted { $0.index < $1.index }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(laps) { split in
                        HStack(spacing: Space.md) {
                            TextField("Label", text: Binding(
                                get: { split.label ?? "" },
                                set: { split.label = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(Fmt.durationShort(split.durationSeconds))
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .onDelete { offsets in
                        let ordered = laps
                        for index in offsets {
                            let split = ordered[index]
                            session.splits.removeAll { $0.id == split.id }
                            modelContext.delete(split)
                        }
                        saveError = modelContext.saveReportingFailure()
                    }
                } footer: {
                    Text("Rename a lap or swipe to delete. Reverting from the workout restores plain laps.")
                }
            }
            .navigationTitle("Edit intervals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let failure = modelContext.saveReportingFailure() {
                            saveError = failure
                        } else {
                            dismiss()
                        }
                    }
                    .font(.bodyStrong)
                }
            }
            .alert(
                "Couldn't Save",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}

/// Read-only breakdown of a completed workout: headline stats plus each
/// exercise's logged sets.
struct WorkoutDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    var history: [WorkoutModel] = []

    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var hrSamples: [(date: Date, bpm: Int)] = []
    @State private var hrLoaded = false
    @State private var recoveryPoints: [SetRecoveryPoint] = []
    @State private var isSharing = false
    @State private var sharePayload: SharePayload?
    @State private var editingSplits: EditSplitsTarget?
    @State private var routePointsMemo = MemoTable<UUID, [CardioRoutePointModel]>()
    @State private var routeCoordinatesMemo = MemoTable<UUID, [CLLocationCoordinate2D]>()
    @State private var splitsMemo = MemoTable<UUID, [CardioSplitModel]>()
    @State private var expandedRoute: ExpandedRouteTarget?
    /// Cardio blocks currently expanded inline (mixed workouts only) —
    /// independent per session, collapsed by default.
    @State private var expandedCardioIDs: Set<UUID> = []

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }

    /// Mixed = strength and cardio in one session. Only then do cardio cards
    /// collapse to compact rows; cardio-only workouts keep the full detail
    /// rendering as the always-open source of truth.
    private var isMixedWorkout: Bool {
        CardioBlockSupport.isMixedWorkout(
            exerciseIDs: workout.exercises.map(\.id),
            cardioLinkedExerciseIDs: Set(workout.cardioSessions.compactMap(\.workoutExerciseID)),
            cardioSessionCount: workout.cardioSessions.count
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.title ?? "Workout").font(.screenTitle).foregroundStyle(theme.textPrimary)
                    Text(workout.startedAt.formatted(date: .complete, time: .shortened))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                }

                let s = analytics.summary(for: workout)
                overallStatsCard(s)

                if workout.avgHR != nil || workout.activeEnergyKcal != nil || workout.readinessAtStart != nil {
                    sessionMetricsCard
                }

                if hrLoaded, !hrSamples.isEmpty {
                    heartRateCard
                }

                if s.hasStrength, recoveryPoints.contains(where: { $0.recoveryBPM != nil }) {
                    betweenSetRecoveryCard
                }

                if s.hasStrength {
                    let muscleRows = analytics.muscleVolume(for: workout)
                    if !muscleRows.isEmpty {
                        muscleWorkedCard(muscleRows)
                    }
                }

                ForEach(workout.exercises.sorted { $0.position < $1.position }) { we in
                    if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == we.id }) {
                        if session.isYogaSession {
                            yogaCard(session, exercise: exercises.first { $0.id == we.exerciseID })
                        } else {
                            cardioCard(session, exercise: exercises.first { $0.id == we.exerciseID })
                        }
                    } else {
                        exerciseCard(we)
                    }
                }
                // Yoga sessions without an anchor exercise (Health imports).
                ForEach(workout.cardioSessions.filter { $0.workoutExerciseID == nil && $0.isYogaSession }) { session in
                    yogaCard(session, exercise: nil)
                }
                // Legacy cardio sessions not linked to an exercise.
                ForEach(workout.cardioSessions.filter { $0.workoutExerciseID == nil && !$0.isYogaSession }) { session in
                    cardioCard(session, exercise: nil)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .task(id: workout.id) { await loadHeartRateSamples() }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .sheet(item: $editingSplits) { target in
            IntervalSplitsEditor(session: target.session)
        }
        .sheet(item: $expandedRoute) { target in
            ExpandedRouteMapView(coordinates: target.coordinates, kind: target.kind)
        }
        .fullScreenCover(isPresented: $showEditor) {
            ActiveWorkoutLoggerView(
                workout: workout,
                exercises: exercises,
                setupNotes: [],
                history: history,
                mode: .historicalEdit
            )
        }
        .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) { scheduleDeleteWorkout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the workout from ForgeFit. Apple Health workout records and metadata are not deleted.")
        }
        .alert("Couldn’t delete workout", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Try again in a moment.")
        }
        .navigationDestination(for: UUID.self) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: history.isEmpty ? [workout] : history, exercises: exercises)
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Text("Workout").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            HStack(spacing: Space.xs) {
                // The share image includes an async GPS route snapshot
                // (MKMapSnapshotter), so preparing it can take a beat — an
                // icon swap alone is easy to miss; say so in words.
                if isSharing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Preparing…").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preparing share image")
                } else {
                    CircleIconButton(systemImage: "square.and.arrow.up", label: "Share workout") {
                        Task { await prepareShare() }
                    }
                        .accessibilityLabel("Share workout")
                }
                CircleIconButton(systemImage: "square.and.pencil", label: "Edit workout") { showEditor = true }
                    .accessibilityLabel("Edit workout")
                CircleIconButton(systemImage: isDeleting ? "hourglass" : "trash", label: "Delete workout") {
                    guard !isDeleting else { return }
                    showDeleteConfirm = true
                }
                    .accessibilityLabel("Delete workout")
            }
        }
        .padding(.top, Space.sm)
    }

    /// Whole-workout facts only. Cardio pace, distance, HR, laps, and route
    /// stay with their cardio block—especially important for mixed sessions.
    private func overallStatsCard(_ summary: TrainingAnalytics.Summary) -> some View {
        Card {
            if summary.hasStrength, summary.hasCardio {
                // Mixed sessions have three distinct stories: the whole
                // session, strength output, and time spent doing cardio.
                // A 2×2 grid keeps all four readouts legible at Dynamic Type.
                Grid(horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                    GridRow {
                        StatColumn(label: "Total time", value: Fmt.durationShort(summary.durationSeconds))
                        StatColumn(label: "Cardio", value: Fmt.durationShort(totalCardioSeconds))
                    }
                    GridRow {
                        StatColumn(label: "Volume", value: Fmt.volume(summary.volume))
                        StatColumn(label: "Sets", value: Fmt.sets(summary.sets))
                    }
                }
            } else {
                HStack {
                    StatColumn(label: "Total time", value: Fmt.durationShort(summary.durationSeconds))
                    if summary.hasStrength {
                        StatColumn(label: "Volume", value: Fmt.volume(summary.volume))
                        StatColumn(label: "Sets", value: Fmt.sets(summary.sets))
                    } else {
                        let linkedIDs = Set(workout.cardioSessions.compactMap(\.workoutExerciseID))
                        let activities = linkedIDs.count
                            + workout.cardioSessions.count(where: { $0.workoutExerciseID == nil })
                        StatColumn(label: "Activities", value: "\(max(activities, 1))")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(overallStatsAccessibilityLabel(summary))
    }

    private var totalCardioSeconds: Int {
        workout.cardioSessions.compactMap(\.durationSeconds).reduce(0, +)
    }

    private func overallStatsAccessibilityLabel(_ summary: TrainingAnalytics.Summary) -> String {
        var label = "Workout summary. Total time \(Fmt.durationShort(summary.durationSeconds))"
        if summary.hasStrength {
            label += ", volume \(Fmt.volume(summary.volume)), \(Fmt.sets(summary.sets)) sets"
        }
        if summary.hasStrength, summary.hasCardio {
            label += ", cardio \(Fmt.durationShort(totalCardioSeconds))"
        }
        return label
    }

    private func scheduleDeleteWorkout() {
        guard !isDeleting else { return }
        showDeleteConfirm = false
        isDeleting = true
        Task { @MainActor in
            // Let the confirmation dialog finish dismissing before SwiftData
            // invalidates the presenting history list.
            try? await Task.sleep(for: .milliseconds(120))
            deleteWorkout()
        }
    }

    private func deleteWorkout() {
        let now = Date()
        workout.updatedAt = now
        workout.deletedAt = now
        // Rollback-on-failure keeps a phantom-deleted row from riding a later
        // unrelated save (and undoes `updatedAt` too, unlike a manual revert).
        if let failure = modelContext.saveReportingFailure() {
            isDeleting = false
            deleteError = failure
            return
        }
        BackupScheduler.shared.noteLogDataChanged()
        dismiss()
    }

    /// Health metrics captured live during the session (Apple Watch /
    /// HealthKit) — the reflect-back-later view of how the body responded.
    private var sessionMetricsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.danger)
                    Text("Session metrics").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    if let readiness = workout.readinessAtStart {
                        Text("Started at \(readiness)% ready")
                            .font(.tag)
                            .foregroundStyle(theme.readinessColor(Double(readiness) / 100))
                    }
                }
                HStack {
                    StatColumn(label: "Avg HR", value: Fmt.bpm(workout.avgHR))
                    StatColumn(label: "Max HR", value: Fmt.bpm(workout.maxHR))
                    StatColumn(label: "Energy", value: workout.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
                }
                if workout.hrZoneSeconds.contains(where: { $0 > 0 }) {
                    ZoneSecondsBar(
                        zoneSeconds: workout.hrZoneSeconds,
                        totalDurationSeconds: analytics.summary(for: workout).durationSeconds
                    )
                }
            }
        }
    }

    /// Fetches the per-sample heart-rate series for this workout's window from
    /// HealthKit on demand. Nothing is stored — a manual/no-watch workout simply
    /// returns no samples and the graph stays hidden.
    private func loadHeartRateSamples() async {
        guard !hrLoaded else { return }
        let end = workout.endedAt ?? workout.startedAt
        let samples = await HealthService.shared.heartRateSamples(from: workout.startedAt, to: end)
        hrSamples = samples
        recoveryPoints = betweenSetRecovery(from: samples)
        hrLoaded = true
    }

    /// Per-set between-set HR recovery for this workout's strength sets, derived
    /// from the HR series and each set's `completedAt`. Cardio sessions are
    /// excluded — this is a resistance-training conditioning read.
    private func betweenSetRecovery(from samples: [(date: Date, bpm: Int)]) -> [SetRecoveryPoint] {
        guard !samples.isEmpty else { return [] }
        let cardioExerciseIDs = Set(workout.cardioSessions.compactMap { $0.workoutExerciseID })
        let sets = workout.exercises
            .filter { !cardioExerciseIDs.contains($0.id) }
            .flatMap(\.sets)
            .compactMap { set -> (id: UUID, completedAt: Date)? in
                set.completedAt.map { (set.id, $0) }
            }
        return SetHRRecovery.analyze(samples: samples, sets: sets)
    }

    /// Heart-rate-over-time graph for the session (Apple Watch samples).
    private var heartRateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.danger)
                    Text("Heart rate").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    if let peak = hrSamples.map(\.bpm).max() {
                        Text("peak \(peak) bpm")
                            .font(.tag)
                            .foregroundStyle(theme.danger)
                    }
                }
                HeartRateTrendChart(samples: hrSamples, bands: HeartRateTrendChart.cardioBands(for: workout))
            }
        }
    }

    /// How far HR fell during rest after each set — a between-set recovery /
    /// conditioning read, distinct from set effort (which RPE/RIR cover).
    private var betweenSetRecoveryCard: some View {
        let dict = Dictionary(recoveryPoints.map { ($0.setID, $0) }, uniquingKeysWith: { first, _ in first })
        let drops = recoveryPoints.compactMap(\.recoveryBPM)
        let avg = drops.isEmpty ? 0 : Int((Double(drops.reduce(0, +)) / Double(drops.count)).rounded())
        let best = drops.max() ?? 0
        let maxDrop = max(1, best)
        let cardioExerciseIDs = Set(workout.cardioSessions.compactMap { $0.workoutExerciseID })
        let strengthExercises = workout.exercises
            .filter { !cardioExerciseIDs.contains($0.id) }
            .sorted { $0.position < $1.position }
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.danger)
                    Text("Between-set recovery").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                HStack {
                    StatColumn(label: "Avg drop", value: "\(avg) bpm")
                    StatColumn(label: "Best drop", value: "\(best) bpm")
                    StatColumn(label: "Sets", value: "\(drops.count)")
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(strengthExercises) { we in
                        let sets = we.sets.sorted { $0.position < $1.position }
                        let rows = Array(sets.enumerated()).compactMap { index, set -> (label: String, point: SetRecoveryPoint)? in
                            dict[set.id].map { (historicalSetLabel(for: set, index: index, sets: sets), $0) }
                        }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(exercises.first { $0.id == we.exerciseID }?.name ?? "Exercise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                    recoveryRow(label: row.label, point: row.point, maxDrop: maxDrop)
                                }
                            }
                        }
                    }
                }
                Text("Peak HR at the end of each set and how far it fell before the next set. Bigger drops mean faster recovery — a conditioning signal, not a measure of how hard the set was.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func recoveryRow(label: String, point: SetRecoveryPoint, maxDrop: Int) -> some View {
        HStack(spacing: Space.sm) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 32, alignment: .leading)
            HStack(spacing: 3) {
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(theme.danger)
                Text("\(point.peakHR)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            }
            .frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceHighlight)
                    Capsule().fill(theme.success)
                        .frame(width: geo.size.width * CGFloat(point.recoveryBPM ?? 0) / CGFloat(maxDrop))
                }
            }
            .frame(height: 8)
            Text(point.recoveryBPM.map { "▼\($0)" } ?? "—")
                .font(.tag)
                .foregroundStyle(point.recoveryBPM != nil ? theme.success : theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// Fractional-set volume by muscle for this workout — a quick read on what
    /// the session actually trained.
    private func muscleWorkedCard(_ rows: [(muscle: String, sets: Double)]) -> some View {
        let maxSets = rows.map(\.sets).max() ?? 1
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("Muscles worked").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                VStack(spacing: 8) {
                    ForEach(rows, id: \.muscle) { row in
                        VStack(spacing: 5) {
                            HStack {
                                Text(row.muscle.capitalized)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text("\(row.sets.formatted(.number.precision(.fractionLength(0...1)))) sets")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.surfaceHighlight)
                                    Capsule().fill(theme.accent)
                                        .frame(width: geo.size.width * (row.sets / max(1, maxSets)))
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
                Text("1 set per primary muscle, ½ per secondary. Warm-ups don’t count.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func exerciseCard(_ we: WorkoutExerciseModel) -> some View {
        let exercise = exercises.first { $0.id == we.exerciseID }
        let name = exercise?.name ?? "Exercise"
        let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
        let sets = we.sets.sorted { $0.position < $1.position }
        return Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                if let exercise {
                    NavigationLink(value: exercise.id) {
                        ExerciseNameLabel(name: name)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    historicalSetRow(set, index: index, sets: sets, unit: unit)
                }
            }
        }
    }

    private func historicalSetRow(_ set: SetModel, index: Int, sets: [SetModel], unit: WeightUnit) -> some View {
        let style = SetTypeStyle.of(set.setType)
        let label = historicalSetLabel(for: set, index: index, sets: sets)
        let isPlainWorking = set.setType == .working
        let isCompleted = HistoricalSetPresentation.isCompleted(set)
        let valueColor = isCompleted ? theme.textPrimary : theme.textTertiary
        let outputColor = isCompleted ? theme.textSecondary : theme.textTertiary
        return HStack(spacing: Space.sm) {
            if set.setType == .drop {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCompleted ? style.color : theme.textTertiary)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14)
            }

            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    isCompleted
                        ? (isPlainWorking ? theme.textPrimary : style.color)
                        : theme.textTertiary
                )
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(HistoricalSetPresentation.loadText(set, unit: unit))
                    .font(.rowValue)
                    .foregroundStyle(valueColor)
                if !isPlainWorking {
                    Text(style.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCompleted ? style.color : theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(HistoricalSetPresentation.outputText(set))
                .font(.rowValue)
                .foregroundStyle(outputColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(isCompleted ? 1 : 0.72)
        .accessibilityLabel(isCompleted ? "\(label), completed" : "\(label), not done")
    }

    private func historicalSetLabel(for set: SetModel, index: Int, sets: [SetModel]) -> String {
        let style = SetTypeStyle.of(set.setType)
        guard style.numbered else { return style.badge.isEmpty ? "•" : style.badge }
        let number = sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
        return "\(number)\(style.badge)"
    }

    /// Banner shown when ForgeFit optimistically applied detected interval laps
    /// to a free-form run — the user can edit or revert to plain laps.
    @ViewBuilder
    private func autoIntervalBanner(_ cardio: CardioSessionModel) -> some View {
        let workCount = cardio.splits.filter { $0.autoDetected && ($0.label?.hasPrefix("Work") == true) }.count
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(theme.secondaryAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Detected \(workCount) interval\(workCount == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("Auto-segmented from your effort — edit or revert to plain laps.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            Button("Edit") { editingSplits = EditSplitsTarget(session: cardio) }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.secondaryAccent)
            Button("Revert") { CardioSeriesService.revertAutoIntervals(for: cardio, in: modelContext) }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.danger)
        }
        .padding(10)
        .background(theme.secondaryAccent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Efficiency Factor for an aerobic session, with a 30-day comparison —
    /// cardio's "am I getting fitter" line.
    @ViewBuilder
    private func efficiencyRow(for cardio: CardioSessionModel) -> some View {
        let config = HRZoneConfigStore.load()
        if let ef = analytics.efficiencyFactor(for: cardio), analytics.isAerobicSession(cardio, config: config) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.heart.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                Text("Efficiency \(ef.formatted(.number.precision(.fractionLength(2))))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                if let baseline = aerobicEFBaseline(kind: CardioKind.from(modality: cardio.modality)), baseline > 0 {
                    let pct = (ef - baseline) / baseline * 100
                    Text(pct >= 0
                         ? "▲ \(pct.formatted(.number.precision(.fractionLength(0))))% vs 30-day"
                         : "▼ \(abs(pct).formatted(.number.precision(.fractionLength(0))))% vs 30-day")
                        .font(.tag)
                        .foregroundStyle(pct >= 0 ? theme.success : theme.danger)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func aerobicEFBaseline(kind: CardioKind) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: workout.startedAt) ?? .distantPast
        let config = HRZoneConfigStore.load()
        let efs = history
            .filter { $0.startedAt >= cutoff && $0.startedAt < workout.startedAt }
            .flatMap(\.cardioSessions)
            .filter { CardioKind.from(modality: $0.modality) == kind && analytics.isAerobicSession($0, config: config) }
            .compactMap { analytics.efficiencyFactor(for: $0) }
        guard efs.count >= 2 else { return nil }
        return efs.reduce(0, +) / Double(efs.count)
    }

    /// A completed yoga session: style, duration/poses/HR, and the pose-by-
    /// pose hold list — the history mirror of the live yoga card.
    private func yogaCard(_ session: CardioSessionModel, exercise: ExerciseLibraryModel?) -> some View {
        let style = session.resolvedYogaStyle
        let name = exercise.map { ex in
            YogaFlowPlan.decode(from: workout.exercises.first { $0.exerciseID == ex.id }?.yogaFlowJSON)?.steps.count ?? 1 > 1
                ? "Guided Flow" : ex.name
        } ?? "Yoga"
        let splits = session.splits.filter { $0.label != nil }.sorted { $0.index < $1.index }
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: style.systemImage).foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
                    if let exercise {
                        NavigationLink(value: exercise.id) {
                            ExerciseNameLabel(name: name)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    }
                    Spacer()
                    Tag(text: "\(style.title) Yoga", color: theme.accent, background: theme.accentSoft)
                }
                HStack {
                    StatColumn(label: "Duration", value: Fmt.durationShort(session.durationSeconds), valueColor: theme.accent)
                    StatColumn(label: "Poses", value: session.posesCompleted.map(String.init) ?? "—")
                    StatColumn(label: "Avg HR", value: session.avgHR.map(String.init) ?? "—", valueColor: theme.danger)
                    StatColumn(label: "kcal", value: session.activeEnergyKcal.map { String(Int($0)) } ?? "—")
                }
                if let hr = session.avgHR {
                    HRZoneBar(avgHR: hr, maxHR: session.maxHR, durationSeconds: session.durationSeconds)
                }
                if !splits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Poses").font(.tag).foregroundStyle(theme.textSecondary)
                        ForEach(splits) { split in
                            HStack {
                                Text(split.label ?? "Pose \(split.index + 1)")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(Fmt.durationShort(split.durationSeconds))
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cardioCard(_ cardio: CardioSessionModel, exercise: ExerciseLibraryModel?) -> some View {
        let kind = CardioKind.from(modality: cardio.modality)
        let name = exercise?.name ?? kind.title
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                if isMixedWorkout {
                    // In a mixed session the cardio block collapses to a
                    // compact row so the strength timeline stays scannable;
                    // expanding reveals the full cardio detail inline.
                    let isExpanded = expandedCardioIDs.contains(cardio.id)
                    cardioBlockHeader(cardio, kind: kind, name: name, isExpanded: isExpanded)
                    if isExpanded {
                        cardioDetailContent(cardio, kind: kind, showPerBlockHR: true)
                        if let exercise {
                            cardioLibraryLink(exercise, name: name)
                        }
                    }
                } else {
                    HStack(spacing: Space.sm) {
                        Image(systemName: kind.systemImage).foregroundStyle(theme.secondaryAccent)
                            .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
                        if let exercise {
                            NavigationLink(value: exercise.id) {
                                ExerciseNameLabel(name: name)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                    }

                    cardioDetailContent(cardio, kind: kind, showPerBlockHR: false)
                }
            }
        }
    }

    /// Compact collapsed row for a cardio block in a mixed workout:
    /// "18min Run", a one-line metric summary, and a rotating chevron. The
    /// whole row toggles the inline detail.
    private func cardioBlockHeader(_ cardio: CardioSessionModel, kind: CardioKind, name: String, isExpanded: Bool) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                if isExpanded {
                    expandedCardioIDs.remove(cardio.id)
                } else {
                    expandedCardioIDs.insert(cardio.id)
                }
            }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: kind.systemImage).foregroundStyle(theme.secondaryAccent)
                    .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(CardioBlockSupport.compactTitle(durationSeconds: cardio.durationSeconds, name: name))
                        .font(.bodyStrong)
                        .foregroundStyle(theme.secondaryAccent)
                    if let subtitle = CardioBlockSupport.compactSubtitle(
                        distance: cardio.distanceMeters.map { Fmt.cardioDistance($0, kind: kind) },
                        avgHR: cardio.avgHR,
                        calories: cardio.activeEnergyKcal,
                        effort: cardio.effort
                    ) {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) cardio block")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
        .accessibilityIdentifier("cardio-block-header")
    }

    /// Library navigation for an expanded block — lives at the bottom of the
    /// detail so the header tap can unambiguously mean expand/collapse.
    private func cardioLibraryLink(_ exercise: ExerciseLibraryModel, name: String) -> some View {
        NavigationLink(value: exercise.id) {
            HStack(spacing: 4) {
                Text("View \(name) history")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.secondaryAccent)
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    /// The full cardio detail experience — identical for cardio-only workouts
    /// and expanded mixed blocks. `showPerBlockHR` adds this block's slice of
    /// the workout HR series (mixed only; cardio-only workouts already show it
    /// at the workout level).
    @ViewBuilder
    private func cardioDetailContent(_ cardio: CardioSessionModel, kind: CardioKind, showPerBlockHR: Bool) -> some View {
        // Primary Strava-style read-outs
        HStack {
            metric(kind.usesPace ? "Pace" : "Speed",
                   kind.usesPace
                   ? CardioMetrics.paceString(distanceMeters: cardio.distanceMeters, durationSeconds: cardio.durationSeconds, kind: kind)
                   : CardioMetrics.speedString(distanceMeters: cardio.distanceMeters, durationSeconds: cardio.durationSeconds),
                   color: theme.secondaryAccent)
            metric("Distance", Fmt.distance(cardio.distanceMeters))
            metric("Time", Fmt.durationShort(cardio.durationSeconds))
        }

        // Secondary metrics
        HStack {
            if let hr = cardio.avgHR { metric("Avg HR", "\(hr)") }
            if let cal = cardio.activeEnergyKcal { metric("Calories", "\(Int(cal))") }
            if let elev = cardio.elevationGainMeters { metric("Elev", "\(Int(elev)) m") }
            if let power = cardio.avgPowerWatts { metric("Power", "\(Int(power)) W") }
            if let effort = cardio.effort { metric("Effort", "\(effort)/10") }
        }

        efficiencyRow(for: cardio)

        if cardio.intervalsAutoApplied {
            autoIntervalBanner(cardio)
        }

        routeSection(for: cardio, kind: kind)

        // Interval laps for sessions without a GPS map (e.g. treadmill)
        // — the route section already renders laps under the map.
        if cardio.routePoints.count < 2 {
            let laps = cardio.splits.filter { $0.label != nil }.sorted { $0.index < $1.index }
            if !laps.isEmpty { splitsTable(laps) }
        }

        bestEffortsSection(for: cardio)

        if cardio.routePoints.count >= 2 {
            SecondaryButton(title: "Export GPX", systemImage: "square.and.arrow.up.on.square") {
                exportGPX(cardio, kind: kind)
            }
            .accessibilityHint("Creates a GPX file to share with Strava or any training app")
        }

        // Show one zone story. Prefer the measured per-sample distribution;
        // fall back to the stored distribution, then estimate from average HR.
        let measuredZones = CardioMetrics.measuredZoneSecondsArray(seriesJSON: cardio.sampleSeriesJSON)
        let storedZones = cardio.hrZoneSeconds.contains(where: { $0 > 0 }) ? cardio.hrZoneSeconds : nil
        if let hr = cardio.avgHR {
            HRZoneBar(
                avgHR: hr,
                maxHR: cardio.maxHR,
                durationSeconds: cardio.durationSeconds,
                zoneSeconds: measuredZones ?? storedZones,
                source: measuredZones == nil ? .estimated : .measured
            )
        }

        if showPerBlockHR {
            // This block's slice of the whole-workout HR series. The zone
            // distribution above already represents this block.
            if let window = CardioBlockSupport.blockWindow(
                startedAt: cardio.startedAt,
                liveStartedAt: cardio.liveStartedAt,
                endedAt: cardio.endedAt,
                durationSeconds: cardio.durationSeconds
            ) {
                let slice = CardioBlockSupport.hrSlice(samples: hrSamples, window: window)
                if slice.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Heart rate")
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                        HeartRateTrendChart(samples: slice)
                    }
                }
            }
        }

        MuscleChips(muscles: kind.musclesWorked)
    }

    // MARK: - Best efforts (T4-3)

    /// This session's fastest windows over standard distances, with a PR
    /// badge when a window beats every other stored session — Strava's most
    /// loved feature, computed locally from the stored sample series.
    @ViewBuilder
    private func bestEffortsSection(for cardio: CardioSessionModel) -> some View {
        let efforts = CardioSampleSeries.decode(from: cardio.sampleSeriesJSON)
            .map(DistanceBestEfforts.fromSeries) ?? []
        if !efforts.isEmpty {
            let records = historicalBestEfforts(excluding: cardio.id)
            VStack(alignment: .leading, spacing: 8) {
                Text("Best efforts")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
                ForEach(efforts, id: \.label) { effort in
                    let isPR = (records[effort.label].map { effort.seconds < $0 }) ?? true
                    HStack {
                        Text(effort.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if isPR {
                            Tag(text: "PR", color: .white, background: theme.accent)
                        }
                        Text(Fmt.durationShort(Int(effort.seconds.rounded())))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isPR ? theme.accent : theme.textPrimary)
                    }
                }
            }
        }
    }

    /// All-time fastest seconds per distance label across every OTHER stored
    /// session — the bar this session's efforts must beat to badge PR.
    private func historicalBestEfforts(excluding sessionID: UUID) -> [String: Double] {
        let source = history.isEmpty ? [workout] : history
        var best: [String: Double] = [:]
        for past in source where past.endedAt != nil && past.deletedAt == nil {
            for session in past.cardioSessions where session.id != sessionID && !session.isYogaSession {
                guard let series = CardioSampleSeries.decode(from: session.sampleSeriesJSON) else { continue }
                for effort in DistanceBestEfforts.fromSeries(series) {
                    best[effort.label] = min(best[effort.label] ?? .infinity, effort.seconds)
                }
            }
        }
        return best
    }

    // MARK: - GPX export (T4-1)

    /// Writes the session as a GPX file (route + heart rate) and hands it to
    /// the share sheet — Strava, email, Files, any training app.
    private func exportGPX(_ cardio: CardioSessionModel, kind: CardioKind) {
        let points = cardio.routePoints.sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2 else { return }
        // HR by nearest sample time (±5 s) from the stored series, keyed off
        // the session start so route timestamps and series offsets line up.
        let series = CardioSampleSeries.decode(from: cardio.sampleSeriesJSON)
        let start = cardio.liveStartedAt ?? cardio.startedAt
        let hrByOffset: [Int: Int] = series.map {
            Dictionary($0.samples.compactMap { s in s.hr.map { (s.t, $0) } }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        let track = GPXCodec.Track(
            name: workout.title ?? kind.title,
            points: points.map { point in
                let offset = Int(point.timestamp.timeIntervalSince(start).rounded())
                let hr = (offset - 5...offset + 5).lazy.compactMap { hrByOffset[$0] }.first
                return GPXCodec.Point(
                    time: point.timestamp,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    elevationMeters: point.altitudeMeters,
                    heartRate: hr
                )
            }
        )
        let stamp = cardio.startedAt.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeFit-\(kind.title)-\(stamp).gpx")
        guard (try? GPXCodec.encode(track: track).write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        sharePayload = SharePayload(items: [url])
    }

    /// Start (green) / finish (red) markers for a route — without them a bare
    /// polyline doesn't say which end is which.
    @MapContentBuilder
    private func routeEndpointMarkers(_ coordinates: [CLLocationCoordinate2D]) -> some MapContent {
        if let start = coordinates.first {
            Annotation("Start", coordinate: start) {
                Circle().fill(theme.success)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        if let end = coordinates.last {
            Annotation("Finish", coordinate: end) {
                Circle().fill(theme.danger)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
    }

    @ViewBuilder
    private func routeSection(for cardio: CardioSessionModel, kind: CardioKind) -> some View {
        let generation = "\(cardio.id)|\(cardio.routePoints.count)|\(cardio.splits.count)"
        let points = routePointsMemo.value(for: cardio.id, generation: generation) {
            cardio.routePoints.sorted { $0.timestamp < $1.timestamp }
        }
        if points.count >= 2 {
            let coordinates = routeCoordinatesMemo.value(for: cardio.id, generation: generation) {
                points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
            VStack(alignment: .leading, spacing: Space.md) {
                Button {
                    expandedRoute = ExpandedRouteTarget(coordinates: coordinates, kind: kind)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Map(interactionModes: []) {
                            MapPolyline(coordinates: coordinates)
                                .stroke(theme.secondaryAccent, lineWidth: 4)
                            routeEndpointMarkers(coordinates)
                        }
                        .frame(height: 180)
                        .allowsHitTesting(false)

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(8)
                    }
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(theme.separator, lineWidth: 1)
                }
                .accessibilityLabel("Route map, \(Fmt.distance(cardio.distanceMeters))")
                .accessibilityHint("Double tap to view full screen")
                .accessibilityIdentifier("route-map-thumbnail")

                let splits = splitsMemo.value(for: cardio.id, generation: generation) {
                    cardio.splits.sorted { $0.index < $1.index }
                }
                if !splits.isEmpty {
                    splitsTable(splits)
                }
            }
        } else if kind.supportsOutdoorRoute {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .foregroundStyle(theme.textTertiary)
                Text("No route available for this workout. Summary metrics still count toward training load.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }

    private func splitsTable(_ splits: [CardioSplitModel]) -> some View {
        // Structured interval sessions carry step labels; GPS laps don't.
        let structured = splits.contains { $0.label != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text(structured ? "Intervals" : "Splits")
                .font(.tag)
                .foregroundStyle(theme.textSecondary)
            ForEach(splits) { split in
                HStack {
                    if let label = split.label {
                        Text(label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.secondaryAccent)
                    } else {
                        Text("\(split.index + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.secondaryAccent)
                            .frame(width: 24, alignment: .leading)
                        Text(Fmt.distance(split.distanceMeters))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer()
                    if split.label == nil {
                        Text(paceString(split))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text(Fmt.durationShort(split.durationSeconds))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
        .padding(.top, 2)
    }

    private func paceString(_ split: CardioSplitModel) -> String {
        CardioMetrics.paceString(distanceMeters: split.distanceMeters, durationSeconds: split.durationSeconds)
    }

    /// Render the full-length workout card to a single tall image and present
    /// the share sheet (Save to Photos, Messages, AirDrop, …). Shares only the
    /// image so exactly one artifact is produced, and passes the already-loaded
    /// HR series / recovery points so the picture matches what's on screen.
    ///
    /// Async because GPS routes are snapshotted first via `MKMapSnapshotter`
    /// (MapKit can't be rasterized off-screen by `ImageRenderer`). Indoor /
    /// strength workouts have no routes, so this returns near-instantly.
    private func prepareShare() async {
        isSharing = true
        defer { isSharing = false }
        var routeMaps: [UUID: UIImage] = [:]
        for session in workout.cardioSessions {
            let coordinates = session.routePoints
                .sorted { $0.timestamp < $1.timestamp }
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            if coordinates.count >= 2,
               let map = await RouteMapSnapshot.image(coordinates: coordinates, size: WorkoutShareCard.routeMapSize, theme: theme) {
                routeMaps[session.id] = map
            }
        }
        guard let image = WorkoutShareRenderer.image(
            for: workout,
            exercises: exercises,
            theme: theme,
            hrSamples: hrSamples,
            recoveryPoints: recoveryPoints,
            routeMaps: routeMaps
        ) else { return }
        sharePayload = SharePayload(items: [image])
    }

    private func metric(_ label: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.label).foregroundStyle(theme.textSecondary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(color ?? theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-screen, fully interactive (pan/zoom) route review — the 180pt inline
/// thumbnail is disabled to avoid intercepting the scroll view's gestures, so
/// closer route inspection (checking a specific turn, comparing against a
/// planned route) needs its own screen.
private struct ExpandedRouteMapView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let coordinates: [CLLocationCoordinate2D]
    let kind: CardioKind

    private var region: MKCoordinateRegion {
        var minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude); maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude); maxLon = max(maxLon, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.003, (maxLat - minLat) * 1.3),
                longitudeDelta: max(0.003, (maxLon - minLon) * 1.3)
            )
        )
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(region)) {
                MapPolyline(coordinates: coordinates)
                    .stroke(theme.secondaryAccent, lineWidth: 5)
                if let start = coordinates.first {
                    Annotation("Start", coordinate: start) {
                        Circle().fill(theme.success)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                }
                if let end = coordinates.last {
                    Annotation("Finish", coordinate: end) {
                        Circle().fill(theme.danger)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewContainer() -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try! ModelContainer(for: Schema(ForgeDataSchema.models), configurations: config)
}

/// Mixed session: strength + cardio interleaved — cardio blocks collapse.
@MainActor
private func previewMixedWorkout(userID: UUID) -> (WorkoutModel, [ExerciseLibraryModel]) {
    let start = Date(timeIntervalSinceNow: -7200)
    let bench = ExerciseLibraryModel(name: "Bench Press", primaryMuscles: ["Chest"])
    let run = ExerciseLibraryModel(name: "Treadmill Run", isCardio: true)
    let pulldown = ExerciseLibraryModel(name: "Lat Pulldown", primaryMuscles: ["Lats"])
    let bike = ExerciseLibraryModel(name: "Bike", isCardio: true)

    let benchWE = WorkoutExerciseModel(userID: userID, exerciseID: bench.id, position: 0, sets: [
        SetModel(userID: userID, position: 0, reps: 8, weight: 80, rpe: 7, completedAt: start.addingTimeInterval(300)),
        SetModel(userID: userID, position: 1, reps: 8, weight: 82.5, rpe: 8, completedAt: start.addingTimeInterval(600)),
        SetModel(userID: userID, position: 2, reps: 7, weight: 82.5, rpe: 9, completedAt: start.addingTimeInterval(900)),
    ])
    let runWE = WorkoutExerciseModel(userID: userID, exerciseID: run.id, position: 1)
    let pulldownWE = WorkoutExerciseModel(userID: userID, exerciseID: pulldown.id, position: 2, sets: [
        SetModel(userID: userID, position: 0, reps: 10, weight: 60, completedAt: start.addingTimeInterval(2600)),
        SetModel(userID: userID, position: 1, reps: 10, weight: 62.5, completedAt: start.addingTimeInterval(2900)),
    ])
    let bikeWE = WorkoutExerciseModel(userID: userID, exerciseID: bike.id, position: 3)

    let runStart = start.addingTimeInterval(1000)
    var runRoutePoints: [CardioRoutePointModel] = []
    for i in 0..<20 {
        let latJitter: Double = i % 3 == 0 ? 0.0004 : 0
        let lonJitter: Double = i % 4 == 0 ? 0.0006 : 0
        runRoutePoints.append(CardioRoutePointModel(
            userID: userID, cardioSessionID: UUID(),
            timestamp: runStart.addingTimeInterval(Double(i) * 54),
            latitude: 37.334 + Double(i) * 0.0008 + latJitter,
            longitude: -122.009 + Double(i) * 0.0005 - lonJitter))
    }
    var runSplits: [CardioSplitModel] = []
    for i in 0..<3 {
        runSplits.append(CardioSplitModel(
            userID: userID, cardioSessionID: UUID(), index: i,
            distanceMeters: 1000, durationSeconds: 330 + i * 8, paceSecondsPerKm: Double(330 + i * 8),
            startedAt: runStart.addingTimeInterval(Double(i) * 340),
            endedAt: runStart.addingTimeInterval(Double(i + 1) * 340)))
    }
    let runSession = CardioSessionModel(
        userID: userID, workoutExerciseID: runWE.id, modality: "run",
        startedAt: runStart, liveStartedAt: runStart, endedAt: runStart.addingTimeInterval(1080),
        durationSeconds: 1080, distanceMeters: 3200, activeEnergyKcal: 240,
        avgHR: 152, maxHR: 171, hrZoneSeconds: [60, 240, 480, 240, 60],
        routePoints: runRoutePoints,
        splits: runSplits)

    let bikeStart = start.addingTimeInterval(3100)
    var bikeSplits: [CardioSplitModel] = []
    for i in 0..<4 {
        let label = i.isMultiple(of: 2) ? "Work \(i / 2 + 1)" : "Recovery \(i / 2 + 1)"
        bikeSplits.append(CardioSplitModel(
            userID: userID, cardioSessionID: UUID(), index: i,
            distanceMeters: 1000, durationSeconds: 150, paceSecondsPerKm: 150,
            label: label,
            autoDetected: true,
            startedAt: bikeStart.addingTimeInterval(Double(i) * 150),
            endedAt: bikeStart.addingTimeInterval(Double(i + 1) * 150)))
    }
    let bikeSession = CardioSessionModel(
        userID: userID, workoutExerciseID: bikeWE.id, modality: "cycle",
        startedAt: bikeStart, liveStartedAt: bikeStart, endedAt: bikeStart.addingTimeInterval(600),
        durationSeconds: 600, distanceMeters: 4000, activeEnergyKcal: 110, avgHR: 138, effort: 6,
        intervalsAutoApplied: true,
        splits: bikeSplits)

    // Legacy whole-workout cardio session (not linked to an exercise).
    let legacySession = CardioSessionModel(
        userID: userID, modality: "row",
        startedAt: start.addingTimeInterval(3800),
        durationSeconds: 480, distanceMeters: 1200, avgHR: 129)

    let workout = WorkoutModel(
        userID: userID, title: "Push + Engine", startedAt: start, endedAt: start.addingTimeInterval(4400),
        avgHR: 128, maxHR: 171, activeEnergyKcal: 520, hrZoneSeconds: [600, 1200, 1400, 300, 80],
        exercises: [benchWE, runWE, pulldownWE, bikeWE],
        cardioSessions: [runSession, bikeSession, legacySession])
    return (workout, [bench, run, pulldown, bike])
}

#Preview("Mixed workout") {
    let container = previewContainer()
    let (workout, exercises) = previewMixedWorkout(userID: UUID())
    container.mainContext.insert(workout)
    exercises.forEach { container.mainContext.insert($0) }
    return NavigationStack {
        WorkoutDetailView(workout: workout, exercises: exercises)
    }
    .modelContainer(container)
}

/// Cardio-only session — must render exactly like production today: full
/// detail, no chevron, no collapse.
#Preview("Cardio only") {
    let container = previewContainer()
    let userID = UUID()
    let run = ExerciseLibraryModel(name: "Outdoor Run", isCardio: true)
    let runWE = WorkoutExerciseModel(userID: userID, exerciseID: run.id, position: 0)
    let start = Date(timeIntervalSinceNow: -3600)
    let session = CardioSessionModel(
        userID: userID, workoutExerciseID: runWE.id, modality: "run",
        startedAt: start, liveStartedAt: start, endedAt: start.addingTimeInterval(1620),
        durationSeconds: 1620, distanceMeters: 5000, activeEnergyKcal: 380,
        avgHR: 156, maxHR: 178, hrZoneSeconds: [120, 300, 720, 360, 120])
    let workout = WorkoutModel(
        userID: userID, title: "Morning Run", startedAt: start, endedAt: start.addingTimeInterval(1700),
        avgHR: 156, maxHR: 178, activeEnergyKcal: 380,
        exercises: [runWE], cardioSessions: [session])
    container.mainContext.insert(workout)
    container.mainContext.insert(run)
    return NavigationStack {
        WorkoutDetailView(workout: workout, exercises: [run])
    }
    .modelContainer(container)
}
#endif
