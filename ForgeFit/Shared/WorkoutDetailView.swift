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
                        try? modelContext.save()
                    }
                } footer: {
                    Text("Rename a lap or swipe to delete. Reverting from the workout restores plain laps.")
                }
            }
            .navigationTitle("Edit intervals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? modelContext.save(); dismiss() }.font(.bodyStrong)
                }
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

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }

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
                Card {
                    HStack {
                        StatColumn(label: "Duration", value: Fmt.durationShort(s.durationSeconds))
                        if s.isCardio {
                            StatColumn(label: "Avg HR", value: Fmt.bpm(s.avgHR))
                            StatColumn(label: "Distance", value: Fmt.distance(workout.cardioSessions.first?.distanceMeters))
                        } else {
                            StatColumn(label: "Volume", value: Fmt.volume(s.volume))
                            StatColumn(label: "Sets", value: "\(s.sets)")
                        }
                    }
                }

                if workout.avgHR != nil || workout.activeEnergyKcal != nil || workout.readinessAtStart != nil {
                    sessionMetricsCard
                }

                if hrLoaded, !hrSamples.isEmpty {
                    heartRateCard
                }

                if !s.isCardio, recoveryPoints.contains(where: { $0.recoveryBPM != nil }) {
                    betweenSetRecoveryCard
                }

                if !s.isCardio {
                    let muscleRows = analytics.muscleVolume(for: workout)
                    if !muscleRows.isEmpty {
                        muscleWorkedCard(muscleRows)
                    }
                }

                ForEach(workout.exercises.sorted { $0.position < $1.position }) { we in
                    if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == we.id }) {
                        cardioCard(session, exercise: exercises.first { $0.id == we.exerciseID })
                    } else {
                        exerciseCard(we)
                    }
                }
                // Legacy cardio sessions not linked to an exercise.
                ForEach(workout.cardioSessions.filter { $0.workoutExerciseID == nil }) { session in
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
            CircleIconButton(systemImage: "chevron.left") { dismiss() }
            Spacer()
            Text("Workout").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
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
                    CircleIconButton(systemImage: "square.and.arrow.up") {
                        Task { await prepareShare() }
                    }
                        .accessibilityLabel("Share workout")
                }
                CircleIconButton(systemImage: "square.and.pencil") { showEditor = true }
                    .accessibilityLabel("Edit workout")
                CircleIconButton(systemImage: isDeleting ? "hourglass" : "trash") {
                    guard !isDeleting else { return }
                    showDeleteConfirm = true
                }
                    .accessibilityLabel("Delete workout")
            }
        }
        .padding(.top, Space.sm)
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
        do {
            try modelContext.save()
        } catch {
            // Roll the tombstone back instead of leaving a phantom-deleted row
            // in memory that a later unrelated save would silently commit.
            workout.deletedAt = nil
            isDeleting = false
            deleteError = error.localizedDescription
            return
        }
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.readinessColor(Double(readiness) / 100))
                    }
                }
                HStack {
                    StatColumn(label: "Avg HR", value: Fmt.bpm(workout.avgHR))
                    StatColumn(label: "Max HR", value: Fmt.bpm(workout.maxHR))
                    StatColumn(label: "Energy", value: workout.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
                }
                if workout.hrZoneSeconds.contains(where: { $0 > 0 }) {
                    ZoneSecondsBar(zoneSeconds: workout.hrZoneSeconds)
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.danger)
                    }
                }
                HeartRateTrendChart(samples: hrSamples)
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
                .font(.system(size: 12, weight: .semibold))
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
                        exerciseTitle(name, color: theme.accent, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    exerciseTitle(name, color: theme.accent)
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
        return HStack(spacing: Space.sm) {
            if set.setType == .drop {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(style.color)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14)
            }

            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isPlainWorking ? theme.textPrimary : style.color)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.loadUnit(set.weight, unit: unit))
                    .font(.rowValue)
                    .foregroundStyle(theme.textPrimary)
                if !isPlainWorking {
                    Text(style.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(historicalSetOutput(set))
                .font(.rowValue)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func historicalSetLabel(for set: SetModel, index: Int, sets: [SetModel]) -> String {
        let style = SetTypeStyle.of(set.setType)
        guard style.numbered else { return style.badge.isEmpty ? "•" : style.badge }
        let number = sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
        return "\(number)\(style.badge)"
    }

    private func historicalSetOutput(_ set: SetModel) -> String {
        if !set.miniReps.isEmpty {
            let activation = set.reps.map(String.init)
            let minis = set.miniReps.map(String.init).joined(separator: "+")
            return [activation, minis].compactMap(\.self).joined(separator: "+") + " reps"
        }
        if let seconds = set.durationSeconds, seconds > 0 {
            return Fmt.durationShort(seconds)
        }
        return "\(set.reps.map(String.init) ?? "—") reps"
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
                        .font(.system(size: 12, weight: .semibold))
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

    private func cardioCard(_ cardio: CardioSessionModel, exercise: ExerciseLibraryModel?) -> some View {
        let kind = CardioKind.from(modality: cardio.modality)
        let name = exercise?.name ?? kind.title
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: kind.systemImage).foregroundStyle(theme.secondaryAccent)
                        .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
                    if let exercise {
                        NavigationLink(value: exercise.id) {
                            exerciseTitle(name, color: theme.secondaryAccent, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        exerciseTitle(name, color: theme.secondaryAccent)
                    }
                }

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

                if let hr = cardio.avgHR {
                    HRZoneBar(avgHR: hr, maxHR: cardio.maxHR, durationSeconds: cardio.durationSeconds)
                }
                MuscleChips(muscles: kind.musclesWorked)
            }
        }
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

    private func exerciseTitle(_ name: String, color: Color, showsChevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.bodyStrong)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(color)
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
                .font(.system(size: 12, weight: .semibold))
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
