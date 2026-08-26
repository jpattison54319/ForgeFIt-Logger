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
    @Query(sort: \RoutineModel.position) private var allRoutines: [RoutineModel]
    @Query(sort: \UserExerciseNoteModel.updatedAt, order: .reverse)
    private var storedSetupNotes: [UserExerciseNoteModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse)
    private var alternations: [RoutineAlternationModel]
    @State private var metric: TrainingAnalytics.Metric = .volume
    @State private var chartRange: TimeChartRange = .all
    @State private var editing = false
    @State private var sharePayload: ShareImagePayload?
    @State private var shareErrorMessage: String?

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var series: [MetricPoint] { chartRange.filtered(analytics.routineSeries(routineID: routine.id, metric: metric)) }
    private var sortedExercises: [RoutineExerciseModel] { routine.exercises.sorted { $0.position < $1.position } }
    private var orderedItems: [OrderedRoutineItem] { OrderedRoutineItem.ordered(in: routine) }
    private func unresolvedAdaptiveExerciseNames(
        baselines: [UUID: Double]
    ) -> [String] {
        routine.exercises.compactMap { routineExercise in
            guard routineExercise.sets.contains(where: {
                $0.loadPrescriptionMode == .percentEstimatedOneRepMax
            }) else { return nil }
            let exercise = exercises.first { $0.id == routineExercise.exerciseID }
            let hasIncompletePercentage = routineExercise.sets.contains {
                $0.loadPrescriptionMode == .percentEstimatedOneRepMax
                    && $0.estimatedOneRepMaxPrescription == nil
            }
            guard hasIncompletePercentage
                    || !AdaptiveLoadResolver.supportsPercentagePrescription(exercise)
                    || baselines[routineExercise.exerciseID] == nil else {
                return nil
            }
            return exercise?.name ?? "Exercise"
        }
    }
    private var resolvedSetupNotes: [UserExerciseNoteModel] {
        Array(Dictionary(
            (storedSetupNotes + setupNotes)
                .filter { ExerciseNotePolicy.authoredText($0.note) != nil }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        ).values)
    }

    private func setupNote(for exerciseID: UUID) -> UserExerciseNoteModel? {
        resolvedSetupNotes
            .filter { $0.exerciseID == exerciseID && $0.userID == ForgeFitDemo.userID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    var body: some View {
        let baselines = AdaptiveLoadResolver.bestEstimatedOneRepMaxByExercise(workouts: workouts)
        let unresolvedNames = unresolvedAdaptiveExerciseNames(baselines: baselines)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name).font(.screenTitle).foregroundStyle(theme.textPrimary)
                    Text("Created by you").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                }

                if !unresolvedNames.isEmpty {
                    adaptiveStartNotice(names: unresolvedNames)
                }

                PrimaryButton(title: "Start Routine") { start() }
                    .disabled(orderedItems.isEmpty)

                chartSection

                HStack {
                    Text("Workout").font(.sectionTitle).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button { editing = true } label: {
                        Text("Edit Routine")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
                    }
                }

                if orderedItems.isEmpty {
                    EmptyStateCard(title: "Nothing added", message: "Add an exercise, conditioning block, or Yoga flow.", systemImage: "plus.rectangle.on.rectangle")
                } else {
                    ForEach(orderedItems) { item in
                        switch item {
                        case .exercise(let routineExercise):
                            RoutineExerciseSummary(
                                routineExercise: routineExercise,
                                exercise: exercises.first { $0.id == routineExercise.exerciseID },
                                setupNote: setupNote(for: routineExercise.exerciseID),
                                bestEstimatedOneRepMaxKg: baselines[routineExercise.exerciseID]
                            )
                        case .block(let block):
                            RoutineBlockSummary(block: block, exercises: exercises)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .accessibilityIdentifier("routine-detail")
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .alert(
            "Couldn't share routine",
            isPresented: Binding(
                get: { shareErrorMessage != nil },
                set: { if !$0 { shareErrorMessage = nil } }
            )
        ) { } message: {
            Text(shareErrorMessage ?? "")
        }
        .navigationDestination(isPresented: $editing) {
            RoutineEditorView(routine: routine, exercises: exercises, setupNotes: resolvedSetupNotes)
        }
        .navigationDestination(for: UUID.self) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: workouts, exercises: exercises)
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Text("Routine").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            HStack(spacing: Space.sm) {
                // Same 44 pt glass treatment as the back button — this header
                // used to mix three different circular-button styles.
                CircleIconButton(systemImage: "square.and.arrow.up", label: "Share routine") { shareRoutine() }
                Menu {
                    Button("Edit Routine", systemImage: "pencil") { editing = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Routine options")
            }
        }
        .padding(.top, Space.sm)
    }

    private func adaptiveStartNotice(names: [String]) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warmup)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Adaptive loads need attention")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text("\(names.joined(separator: ", ")) will start with a blank load. You can still begin and enter it during the workout.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review Load Plans") { editing = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentForeground)
                    .minimumTouchTarget()
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review-adaptive-loads")
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(theme.warmup.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adaptive-load-start-warning")
    }

    private var chartSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline) {
                        if let last = series.last {
                            Text(metric.routineFormatted(last.value))
                                .font(.metricValue).foregroundStyle(theme.textPrimary)
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("routine-progress-headline")
                            Text(last.date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentForeground)
                        } else {
                            Text("No data yet").font(.cardTitle).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer(minLength: Space.md)
                    TimeChartRangePicker(selection: $chartRange)
                }

                if series.count >= 2 {
                    // `.id(metric)` swaps the chart identity per metric so the
                    // change reads as a crossfade, not a path morph between
                    // unrelated series.
                    LineTrendChart(
                        points: series,
                        yLabel: metric.rawValue,
                        valueFormatter: { metric.routineFormatted($0) },
                        axisValueFormatter: { metric.routineAxisValue($0) },
                        yAxisUnitLabel: metric.routineAxisLabel,
                        chartAccessibilityIdentifier: "routine-progress-chart"
                    )
                        .id(metric)
                        .transition(.opacity)
                } else {
                    Text("Complete this routine a few times to chart your progress.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        .frame(height: 80)
                }

                SegmentedPills(
                    options: TrainingAnalytics.Metric.allCases,
                    title: { $0.rawValue },
                    selection: $metric,
                    accessibilityID: { "routine-progress-\($0.rawValue.lowercased())" }
                )
            }
            .animation(Motion.stateChange, value: metric)
        }
    }

    private func start() {
        appState.requestStart {
            _ = WorkoutFactory.start(
                routine: routine,
                exercises: exercises,
                setupNotes: resolvedSetupNotes,
                in: modelContext,
                onCommit: { _ in appState.showingLogger = true }
            )
        }
    }

    /// The image stays immediately readable in Messages; the adjacent plan
    /// document is the lossless copy another ForgeFit user can save.
    private func shareRoutine() {
        do {
            guard let image = RoutineShareRenderer.image(for: routine, exercises: exercises, theme: theme) else {
                throw PlanShareService.ShareError.invalidStructuredPlan(routine.name)
            }
            let document = try PlanShareService.routineDocument(
                routine,
                allRoutines: allRoutines,
                alternations: alternations,
                exercises: exercises
            )
            let url = try PlanShareService.write(document)
            sharePayload = ShareImagePayload(image: image, attachments: [url])
        } catch {
            shareErrorMessage = error.localizedDescription
        }
    }
}

private struct RoutineBlockSummary: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: RoutineBlockModel
    let exercises: [ExerciseLibraryModel]

    @State private var isExpanded = false

    private var conditioningPlan: ConditioningPlan? {
        guard block.kind == .conditioning else { return nil }
        return ConditioningPlan.decode(from: block.planJSON)
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                if conditioningPlan != nil {
                    Button {
                        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
                            isExpanded.toggle()
                        }
                    } label: {
                        header(showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityLabel("\(title) details")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
                    .accessibilityIdentifier("routine-conditioning-details")
                } else {
                    header(showsChevron: false)
                }

                if let conditioningPlan, isExpanded {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)

                    conditioningDetails(conditioningPlan)
                        .transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .top)))
                }
            }
        }
    }

    private func header(showsChevron: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: block.kind == .conditioning ? "stopwatch" : "figure.yoga")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(block.kind == .conditioning ? theme.warmup : theme.accent)
                .frame(width: 40, height: 40)
                .background(theme.surfaceElevated)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                Text(summary)
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: Space.sm)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private func conditioningDetails(_ plan: ConditioningPlan) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(Array(plan.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(section.name.isEmpty ? "Section \(sectionIndex + 1)" : section.name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: Space.sm)
                        Tag(text: section.format.title, color: theme.warmup, background: theme.warmup.opacity(0.14))
                    }

                    HStack(spacing: Space.sm) {
                        Text(ConditioningSharePresentation.prescription(section))
                        if section.ordering == .partitionable {
                            Text(section.ordering.title)
                        }
                    }
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)

                    VStack(spacing: Space.sm) {
                        ForEach(Array(section.movements.enumerated()), id: \.element.id) { movementIndex, movement in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Text("\(movementIndex + 1)")
                                    .font(.tag)
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 18, alignment: .leading)
                                Text(exerciseName(for: movement.exerciseID))
                                    .font(.label)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer(minLength: Space.sm)
                                Text(
                                    ConditioningSharePresentation.movement(
                                        movement,
                                        section: section,
                                        exercise: exercise(for: movement.exerciseID)
                                    )
                                )
                                .font(.label)
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if sectionIndex < plan.sections.count - 1 {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                }
            }
        }
        .accessibilityIdentifier("routine-conditioning-plan")
    }

    private var title: String {
        RoutineBlockPresentation.title(for: block)
    }

    private func exercise(for id: UUID) -> ExerciseLibraryModel? {
        exercises.first { $0.id == id }
    }

    private func exerciseName(for id: UUID) -> String {
        exercise(for: id)?.name ?? "Exercise"
    }

    private var summary: String {
        if block.kind == .conditioning,
           let plan = ConditioningPlan.decode(from: block.planJSON) {
            let movements = Set(plan.sections.flatMap(\.movements).map(\.exerciseID)).count
            return "\(plan.sections.count) section\(plan.sections.count == 1 ? "" : "s") · \(movements) movement\(movements == 1 ? "" : "s")"
        }
        if let plan = YogaFlowPlan.decode(from: block.planJSON) {
            return "\(plan.structureSummary) · \(plan.style.title)"
        }
        return "Not configured"
    }
}

/// A read-only exercise block on the routine detail: name, tags, rest timer and
/// the target set table.
private struct RoutineExerciseSummary: View {
    @Environment(\.theme) private var theme
    let routineExercise: RoutineExerciseModel
    let exercise: ExerciseLibraryModel?
    let setupNote: UserExerciseNoteModel?
    let bestEstimatedOneRepMaxKg: Double?

    private var sortedSets: [RoutineSetModel] { routineExercise.sets.sorted { $0.position < $1.position } }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    // The same thumbnail the picker and the live logger show,
                    // so an exercise the user photographed is recognizable in
                    // the routine too. Falls back to the modality icon.
                    if let exercise {
                        ExerciseThumbnail(exercise: exercise, size: 40)
                    } else {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let exercise {
                            NavigationLink(value: exercise.id) {
                                ExerciseNameLabel(name: exercise.name)
                                    .minimumTouchTarget()
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Exercise")
                                .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                        if let equipment = exercise?.equipment {
                            Tag(text: equipment.capitalized)
                        }
                        if let group = routineExercise.supersetGroup {
                            SupersetChip(group: group)
                        }
                    }
                    Spacer()
                }

                if let setupNote {
                    ExerciseNoteBanner(note: setupNote, context: .routine)
                }

                if exercise?.isYoga == true {
                    yogaSummary
                } else if exercise?.isCardio == true {
                    cardioSummary
                } else {
                    strengthSummary
                }
            }
        }
        .accessibilityIdentifier("routine-exercise-\(exercise?.name ?? "Exercise")")
    }

    /// Yoga block: the attached flow's shape (or the pose's default hold) —
    /// no set rows, matching the editor.
    private var yogaSummary: some View {
        let plan = YogaFlowPlan.decode(from: routineExercise.yogaFlowJSON)
        return HStack(spacing: 6) {
            Image(systemName: (plan?.style ?? .hatha).systemImage)
                .font(.system(size: 13, weight: .semibold))
            if let plan, plan.hasSteps {
                Text("\(plan.structureSummary) · \(plan.style.title)")
                    .font(.system(size: 14, weight: .semibold))
            } else if let hold = exercise?.defaultHoldSeconds {
                Text("Single pose · \(hold)s hold")
                    .font(.system(size: 14, weight: .semibold))
            } else {
                Text("Guided pose")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
        }
        .foregroundStyle(theme.accentForeground)
    }

    private var strengthSummary: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold))
                Text("Rest Timer: \(restText)").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(theme.accentForeground)

            HStack(spacing: 8) {
                Text("SET").frame(width: 44, alignment: .leading)
                Text("LOAD").frame(maxWidth: .infinity, alignment: .leading)
                Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
                Text("EFFORT").frame(width: 64, alignment: .trailing)
            }
            .font(.tag)
            .foregroundStyle(theme.textTertiary)

            ForEach(Array(sortedSets.enumerated()), id: \.element.id) { index, set in
                let style = SetTypeStyle.of(set.setType, theme: theme)
                HStack(alignment: .top, spacing: 8) {
                    Text(RoutineSetPresentation.badgeText(for: set, at: index, in: sortedSets))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(set.setType == .working ? theme.textPrimary : style.color)
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loadPrimaryText(for: set))
                            .font(.rowValue)
                            .foregroundStyle(theme.textPrimary)
                        if let adaptiveDetail = adaptiveDetailText(for: set) {
                            Text(adaptiveDetail)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(bestEstimatedOneRepMaxKg == nil ? theme.warmup : theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if set.setType != .working {
                            Text(style.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(style.color)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(RoutineSetPresentation.repsText(for: set))
                        .font(.rowValue).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RoutineSetPresentation.effortText(for: set))
                        .font(.tag)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(style.label), \(accessibleLoadText(for: set)), "
                        + "\(RoutineSetPresentation.repsText(for: set)), "
                        + RoutineSetPresentation.effortText(for: set)
                )
            }
        }
    }

    private func loadPrimaryText(for set: RoutineSetModel) -> String {
        guard set.loadPrescriptionMode == .percentEstimatedOneRepMax else {
            return Fmt.load(set.targetWeight, unit: displayUnit)
        }
        guard let prescription = set.estimatedOneRepMaxPrescription else { return "% e1RM" }
        return LoadPrescriptionPresentation.percentLabel(prescription)
    }

    private func adaptiveDetailText(for set: RoutineSetModel) -> String? {
        LoadPrescriptionPresentation.currentLoadLabel(
            for: set,
            exercise: exercise,
            bestEstimatedOneRepMaxKg: bestEstimatedOneRepMaxKg,
            unit: displayUnit
        )
    }

    private func accessibleLoadText(for set: RoutineSetModel) -> String {
        [loadPrimaryText(for: set), adaptiveDetailText(for: set)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var restText: String {
        // Derive from the exercise's actual sets — a hardcoded "2:00" showed
        // a specific number that nothing configured. First working set wins;
        // an exercise of only specialty sets falls back to its first set.
        let type = sortedSets.first { $0.setType == .working }?.setType
            ?? sortedSets.first?.setType
            ?? .working
        let seconds = type.defaultRestSeconds ?? 120
        return seconds == 0 ? "Off" : Fmt.restTimer(seconds)
    }

    private var cardioSummary: some View {
        let kind = CardioKind.infer(name: exercise?.name ?? "Cardio", equipment: exercise?.equipment)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                StatColumn(
                    label: "Goal",
                    value: cardioGoalValue(kind: kind),
                    valueColor: theme.secondaryAccent
                )
                StatColumn(label: "Metrics", value: kind.usesPace ? "Pace" : "Speed")
                StatColumn(label: "HR", value: "Zones")
            }

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

    /// The routine card shows only authored session intent. Legacy set targets
    /// are not proof that the athlete chose a cardio goal.
    private func cardioGoalValue(kind: CardioKind) -> String {
        if let plan = IntervalPlan.decode(from: routineExercise.intervalPlanJSON),
           plan.isMeaningful {
            if plan.hasSteps { return "Intervals" }
            if let goal = plan.goal {
                switch goal.kind {
                case .distance:
                    return Fmt.cardioDistance(goal.value, kind: kind)
                case .duration:
                    return Fmt.durationShort(Int(goal.value))
                case .calories:
                    return "\(Int(goal.value.rounded())) kcal"
                case .elevation:
                    return "\(Int(goal.value.rounded())) m"
                }
            }
            if let zone = plan.hrZoneTarget { return "Zone \(zone)" }
            if let target = plan.target, target.isMeaningful {
                switch target.metric {
                case .pace: return "Pace"
                case .power: return "Power"
                case .cadence: return "Cadence"
                }
            }
        }

        return "Open"
    }

}
