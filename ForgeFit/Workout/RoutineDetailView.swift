import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Hevy-style routine detail: header, Start button, a progress chart with a
/// Volume / Reps / Duration toggle, and the exercise list with target sets.
struct RoutineDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @Bindable var routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @State private var metric: TrainingAnalytics.Metric = .volume
    @State private var chartRange: TimeChartRange = .all
    @State private var editing = false
    @State private var sharePayload: ShareImagePayload?

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var series: [MetricPoint] { chartRange.filtered(analytics.routineVolumeSeries(routineID: routine.id, metric: metric)) }
    private var sortedExercises: [RoutineExerciseModel] { routine.exercises.sorted { $0.position < $1.position } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name).font(.screenTitle).foregroundStyle(theme.textPrimary)
                    Text("Created by you").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                }

                PrimaryButton(title: "Start Routine") { start() }

                chartSection

                HStack {
                    Text("Exercises").font(.sectionTitle).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Edit Routine") { editing = true }
                        .font(.bodyStrong).foregroundStyle(theme.accent)
                }

                if sortedExercises.isEmpty {
                    EmptyStateCard(title: "No exercises", message: "Tap Edit Routine to add exercises.", systemImage: "dumbbell")
                } else {
                    ForEach(sortedExercises) { re in
                        RoutineExerciseSummary(
                            routineExercise: re,
                            exercise: exercises.first { $0.id == re.exerciseID },
                            setupNote: setupNotes.first { $0.exerciseID == re.exerciseID && $0.userID == ForgeFitDemo.userID }
                        )
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.image])
        }
        .navigationDestination(isPresented: $editing) {
            RoutineEditorView(routine: routine, exercises: exercises, setupNotes: setupNotes)
        }
        .navigationDestination(for: UUID.self) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: workouts, exercises: exercises)
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left") { dismiss() }
            Spacer()
            Text("Routine").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            HStack(spacing: Space.sm) {
                Button { shareRoutine() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Share routine")
                Menu {
                    Button("Edit Routine", systemImage: "pencil") { editing = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.top, Space.sm)
    }

    private var chartSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline) {
                        if let last = series.last {
                            Text(metric == .volume ? Fmt.volume(last.value) : "\(Int(last.value)) \(metric.rawValue.lowercased())")
                                .font(.metricValue).foregroundStyle(theme.textPrimary)
                            Text(last.date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                        } else {
                            Text("No data yet").font(.cardTitle).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer(minLength: Space.md)
                    TimeChartRangePicker(selection: $chartRange)
                }

                if series.count >= 2 {
                    LineTrendChart(points: series)
                } else {
                    Text("Complete this routine a few times to chart your progress.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        .frame(height: 80)
                }

                SegmentedPills(options: TrainingAnalytics.Metric.allCases, title: { $0.rawValue }, selection: $metric)
            }
        }
    }

    private func start() {
        appState.requestStart {
            _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
            appState.showingLogger = true
        }
    }

    /// Render the routine to a single tall image and present the share sheet
    /// (Save to Photos, Messages, AirDrop, …).
    private func shareRoutine() {
        if let image = RoutineShareRenderer.image(for: routine, exercises: exercises, theme: theme) {
            sharePayload = ShareImagePayload(image: image)
        }
    }
}

/// A read-only exercise block on the routine detail: name, tags, rest timer and
/// the target set table.
private struct RoutineExerciseSummary: View {
    @Environment(\.theme) private var theme
    let routineExercise: RoutineExerciseModel
    let exercise: ExerciseLibraryModel?
    let setupNote: UserExerciseNoteModel?

    private var sortedSets: [RoutineSetModel] { routineExercise.sets.sorted { $0.position < $1.position } }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: exercise?.isCardio == true ? "figure.run" : "dumbbell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        if let exercise {
                            NavigationLink(value: exercise.id) {
                                HStack(spacing: 4) {
                                    // Matches the live-workout exercise header:
                                    // white name, sage chevron only.
                                    Text(exercise.name)
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Exercise")
                                .font(.bodyStrong).foregroundStyle(theme.accent)
                        }
                        if let equipment = exercise?.equipment {
                            Tag(text: equipment.capitalized)
                        }
                    }
                    Spacer()
                }

                if let setupNote {
                    ExerciseNoteBanner(note: setupNote, context: .routine)
                }

                if exercise?.isCardio == true {
                    cardioSummary
                } else {
                    strengthSummary
                }
            }
        }
        .accessibilityIdentifier("routine-exercise-\(exercise?.name ?? "Exercise")")
    }

    private var strengthSummary: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold))
                Text("Rest Timer: \(restText)").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(theme.accent)

            HStack {
                Text("SET").frame(width: 44, alignment: .leading)
                Text(displayUnit.suffix.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.tag)
            .foregroundStyle(theme.textTertiary)

            ForEach(Array(sortedSets.enumerated()), id: \.element.id) { index, set in
                HStack {
                    Text(set.setType == .warmup ? "W" : "\(index + 1)")
                        .font(.rowValue)
                        .foregroundStyle(set.setType == .warmup ? theme.warmup : theme.textPrimary)
                        .frame(width: 44, alignment: .leading)
                    Text(Fmt.load(set.targetWeight, unit: displayUnit))
                        .font(.rowValue).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(repsText(set))
                        .font(.rowValue).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var restText: String {
        let seconds = SetType.working.defaultRestSeconds ?? 120
        return seconds == 0 ? "Off" : Fmt.restTimer(seconds)
    }

    private var cardioSummary: some View {
        let kind = CardioKind.infer(name: exercise?.name ?? "Cardio", equipment: exercise?.equipment)
        let target = sortedSets.first
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                StatColumn(label: "Target", value: Fmt.durationShort(target?.targetDurationSeconds), valueColor: theme.secondaryAccent)
                StatColumn(label: "Metrics", value: kind.usesPace ? "Pace" : "Speed")
                StatColumn(label: "HR", value: "Zones")
            }

            Text(kind.metricLabels.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryAccent)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kind.musclesWorked, id: \.self) { muscle in
                        Tag(
                            text: muscle.capitalized,
                            color: muscle == "cardiovascular" ? theme.danger : theme.textPrimary,
                            background: muscle == "cardiovascular" ? theme.danger.opacity(0.15) : theme.surfaceHighlight
                        )
                    }
                }
            }
        }
    }

    private func repsText(_ set: RoutineSetModel) -> String {
        switch (set.targetRepsLow, set.targetRepsHigh) {
        case let (lo?, hi?) where lo != hi: "\(lo)–\(hi)"
        case let (lo?, _): "\(lo)"
        case let (_, hi?): "\(hi)"
        default: "—"
        }
    }
}
