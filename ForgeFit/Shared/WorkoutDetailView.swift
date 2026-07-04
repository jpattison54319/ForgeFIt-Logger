import ForgeCore
import ForgeData
import MapKit
import SwiftData
import SwiftUI

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
    @State private var routePointsMemo = MemoTable<UUID, [CardioRoutePointModel]>()
    @State private var routeCoordinatesMemo = MemoTable<UUID, [CLLocationCoordinate2D]>()
    @State private var splitsMemo = MemoTable<UUID, [CardioSplitModel]>()

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
                            StatColumn(label: "Distance", value: Fmt.distanceKm(workout.cardioSessions.first?.distanceMeters))
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
        hrLoaded = true
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
                           ? CardioMetrics.paceString(distanceMeters: cardio.distanceMeters, durationSeconds: cardio.durationSeconds, unit: kind.distanceUnit)
                           : CardioMetrics.speedString(distanceMeters: cardio.distanceMeters, durationSeconds: cardio.durationSeconds),
                           color: theme.secondaryAccent)
                    metric("Distance", Fmt.distanceKm(cardio.distanceMeters))
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

                routeSection(for: cardio, kind: kind)

                if let hr = cardio.avgHR {
                    HRZoneBar(avgHR: hr, maxHR: cardio.maxHR, durationSeconds: cardio.durationSeconds)
                }
                MuscleChips(muscles: kind.musclesWorked)
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
                Map {
                    MapPolyline(coordinates: coordinates)
                        .stroke(theme.secondaryAccent, lineWidth: 4)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(theme.separator, lineWidth: 1)
                }

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
                        Text(Fmt.distanceKm(split.distanceMeters))
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
        let pace = split.paceSecondsPerKm
        guard pace.isFinite, pace > 0 else { return "—" }
        let minutes = Int(pace) / 60
        let seconds = Int(pace) % 60
        return "\(minutes):\(String(format: "%02d", seconds))/km"
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
