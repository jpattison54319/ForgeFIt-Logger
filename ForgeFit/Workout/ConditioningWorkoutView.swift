import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct ConditioningWorkoutView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let onMinimize: () -> Void
    let onFinished: (WorkoutModel) -> Void

    @State private var progress: ConditioningProgress
    @State private var showScore = false
    @State private var partialMovement: ConditioningMovement?
    @State private var saveError: String?
    @State private var didMaterializeFinalPartials = false

    private let plan: ConditioningPlan

    init(
        workout: WorkoutModel,
        exercises: [ExerciseLibraryModel],
        onMinimize: @escaping () -> Void,
        onFinished: @escaping (WorkoutModel) -> Void
    ) {
        self.workout = workout
        self.exercises = exercises
        self.onMinimize = onMinimize
        self.onFinished = onFinished
        let decodedPlan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON)
            ?? ConditioningPlan(sections: [])
        plan = decodedPlan
        _progress = State(initialValue: ConditioningProgress.decode(from: workout.conditioningProgressJSON) ?? ConditioningProgress())
    }

    private var currentSection: ConditioningSection? {
        plan.sections.indices.contains(progress.sectionIndex) ? plan.sections[progress.sectionIndex] : nil
    }

    private var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        ConditioningLiveHeader(
                            title: workout.title ?? "Conditioning",
                            onMinimize: onMinimize,
                            onFinish: { showScore = true }
                        )
                        if let section = currentSection {
                            ConditioningClockCard(section: section, progress: progress)
                            ConditioningMovementList(
                                section: section,
                                progress: progress,
                                exerciseByID: exerciseByID,
                                onToggle: toggleMovement,
                                onPartial: { partialMovement = $0 }
                            )
                        } else {
                            EmptyStateCard(
                                title: "No conditioning section",
                                message: "Add movements in the routine editor before starting.",
                                systemImage: "stopwatch"
                            )
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let section = currentSection, !section.movements.isEmpty {
                    ConditioningLiveActions(
                        section: section,
                        round: progress.round,
                        isPaused: progress.status == .paused,
                        onComplete: completePrimaryAction,
                        onPause: togglePause
                    )
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(.bar)
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await runClock() }
        .sheet(item: $partialMovement) { movement in
            ConditioningPartialEditor(
                movement: movement,
                exerciseName: exerciseByID[movement.exerciseID]?.name ?? "Exercise",
                initialValue: progress.partialValues[movement.id] ?? 0,
                onSave: { value in setPartial(value, for: movement) }
            )
        }
        .sheet(isPresented: $showScore) {
            ConditioningScoreSheet(
                plan: plan,
                progress: $progress,
                exerciseByID: exerciseByID,
                onKeepLogging: { showScore = false },
                onSave: { rounds, movementID, partial, load in
                    apply(ConditioningProgressEvent(action: .setScore(
                        rounds: rounds,
                        partialMovementID: movementID,
                        partialValue: partial,
                        load: load
                    )))
                    finishWorkout()
                }
            )
            .interactiveDismissDisabled()
        }
        .alert("Couldn't Save Workout", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "Your workout is still active.")
        }
    }

    private func runClock() async {
        if progress.status == .ready {
            apply(ConditioningProgressEvent(action: .start))
        }
        while !Task.isCancelled && progress.status != .completed && progress.status != .expired {
            try? await Task.sleep(for: .milliseconds(250))
            guard progress.status == .active, let section = currentSection else { continue }
            let elapsed = sectionElapsed(at: .now)
            let limit: Int? = switch section.format {
            case .amrap, .intervals: section.durationSeconds
            case .emom: (section.rounds ?? 0) * (section.intervalSeconds ?? 60)
            case .forTime, .ladder, .maxLoad: section.timeCapSeconds
            }
            if let limit, limit > 0, elapsed >= limit {
                apply(ConditioningProgressEvent(action: .expire))
                if progress.status == .expired { showScore = true }
            }
        }
        if progress.status == .completed { showScore = true }
    }

    private func sectionElapsed(at date: Date) -> Int {
        guard let start = progress.sectionStartedAt ?? progress.startedAt else { return 0 }
        let end = progress.pausedAt ?? date
        return max(0, Int(end.timeIntervalSince(start) - (progress.sectionAccumulatedPauseSeconds ?? 0)))
    }

    private func toggleMovement(_ movement: ConditioningMovement) {
        apply(ConditioningProgressEvent(action: .toggleMovement(movement.id)))
    }

    private func completePrimaryAction() {
        apply(ConditioningProgressEvent(action: .completeRound))
    }

    private func togglePause() {
        apply(ConditioningProgressEvent(action: progress.status == .paused ? .resume : .pause))
    }

    private func setPartial(_ value: Double, for movement: ConditioningMovement) {
        apply(ConditioningProgressEvent(action: .setPartial(movement.id, value)))
    }

    private func apply(_ event: ConditioningProgressEvent) {
        let before = progress
        let next = ConditioningProgressEngine.apply(event, to: before, plan: plan)
        guard next != before else { return }
        materializeChanges(from: before, to: next, at: event.timestamp)
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) { progress = next }
        workout.conditioningProgressJSON = next.encodedJSON()
        workout.conditioningResultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
        workout.updatedAt = .now
        try? modelContext.save()
        WatchLink.shared.publishState(policy: .immediate)
    }

    private func materializeChanges(from old: ConditioningProgress, to new: ConditioningProgress, at date: Date) {
        for section in plan.sections {
            for movement in section.movements {
                let delta = (new.movementTotals[movement.id] ?? 0) - (old.movementTotals[movement.id] ?? 0)
                guard delta != 0 else { continue }
                if delta > 0 { materialize(movement, value: delta, at: date) }
                else { undoMaterialized(movement, value: -delta) }
            }
        }
        workout.recomputeTotalVolume()
    }

    private func materialize(_ movement: ConditioningMovement, value: Double, at date: Date) {
        guard let exercise = exerciseByID[movement.exerciseID] else { return }
        let workoutExercise = workout.exercises.first { $0.exerciseID == movement.exerciseID }
            ?? makeWorkoutExercise(for: movement.exerciseID)
        if exercise.isCardio || exercise.isYoga {
            let session = workout.cardioSessions.first { $0.workoutExerciseID == workoutExercise.id }
                ?? makeCardioSession(for: workoutExercise, exercise: exercise, at: date)
            if movement.targetUnit == .seconds { session.durationSeconds = (session.durationSeconds ?? 0) + Int(value) }
            if movement.targetUnit == .meters { session.distanceMeters = (session.distanceMeters ?? 0) + value }
            session.endedAt = date
            return
        }
        let set = SetModel(
            userID: workout.userID,
            position: workoutExercise.sets.count,
            weightMode: movement.weightMode,
            reps: movement.targetUnit == .reps ? Int(value) : nil,
            durationSeconds: movement.targetUnit == .seconds ? Int(value) : nil,
            completedAt: date
        )
        set.setModeWeight(movement.targetLoad)
        modelContext.insert(set)
        workoutExercise.sets.append(set)
    }

    private func undoMaterialized(_ movement: ConditioningMovement, value: Double) {
        guard let workoutExercise = workout.exercises.first(where: { $0.exerciseID == movement.exerciseID }) else { return }
        if let set = workoutExercise.sets
            .filter({ $0.completedAt != nil })
            .sorted(by: { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
            .first {
            modelContext.delete(set)
            workoutExercise.sets.removeAll { $0.id == set.id }
        } else if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == workoutExercise.id }) {
            if movement.targetUnit == .seconds { session.durationSeconds = max(0, (session.durationSeconds ?? 0) - Int(value)) }
            if movement.targetUnit == .meters { session.distanceMeters = max(0, (session.distanceMeters ?? 0) - value) }
        }
    }

    private func makeWorkoutExercise(for exerciseID: UUID) -> WorkoutExerciseModel {
        let workoutExercise = WorkoutExerciseModel(
            userID: workout.userID,
            exerciseID: exerciseID,
            position: workout.exercises.count
        )
        modelContext.insert(workoutExercise)
        workout.exercises.append(workoutExercise)
        return workoutExercise
    }

    private func makeCardioSession(
        for workoutExercise: WorkoutExerciseModel,
        exercise: ExerciseLibraryModel,
        at date: Date
    ) -> CardioSessionModel {
        let modality = exercise.isYoga ? CardioSessionModel.yogaModality : CardioKind.infer(name: exercise.name, equipment: exercise.equipment).rawValue
        let session = CardioSessionModel(
            userID: workout.userID,
            workoutExerciseID: workoutExercise.id,
            modality: modality,
            startedAt: workout.startedAt,
            liveStartedAt: workout.startedAt,
            endedAt: date,
            sourceDevice: "iphone-conditioning"
        )
        modelContext.insert(session)
        workout.cardioSessions.append(session)
        return session
    }

    private func finishWorkout() {
        if !didMaterializeFinalPartials {
            for section in plan.sections {
                for movement in section.movements {
                    let partial = progress.partialValues[movement.id] ?? 0
                    if partial > 0 { materialize(movement, value: partial, at: .now) }
                }
            }
            didMaterializeFinalPartials = true
        }
        workout.conditioningResultJSON = ConditioningProgressEngine.result(for: progress, plan: plan).encodedJSON()
        if let error = WorkoutFinisher.finish(workout, in: modelContext) {
            saveError = error
            return
        }
        showScore = false
        onFinished(workout)
    }
}

private struct ConditioningLiveHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let onMinimize: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.down", label: "Minimize workout", action: onMinimize)
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
            Spacer()
            Button("Finish", action: onFinish)
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .buttonBorderShape(.capsule)
        }
        .padding(.top, Space.sm)
    }
}

private struct ConditioningClockCard: View {
    @Environment(\.theme) private var theme
    let section: ConditioningSection
    let progress: ConditioningProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = elapsed(at: context.date)
            Card {
                VStack(spacing: Space.md) {
                    Text(clockText(elapsed: elapsed))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.accent)
                        .contentTransition(.numericText(countsDown: countsDown))
                        .accessibilityLabel(clockAccessibility(elapsed: elapsed))
                    Text(phaseText(elapsed: elapsed))
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                    HStack {
                        StatColumn(label: "Round", value: "\(progress.round)", animatesValue: true)
                        StatColumn(label: "Completed", value: "\(progress.fullRounds)", animatesValue: true)
                        StatColumn(
                            label: "Reps",
                            value: "\(progress.movementTotals.values.reduce(0, +))",
                            animatesValue: true
                        )
                    }
                }
            }
        }
    }

    private var countsDown: Bool { section.format != .forTime || section.timeCapSeconds != nil }

    private func elapsed(at date: Date) -> Int {
        guard let start = progress.sectionStartedAt ?? progress.startedAt else { return 0 }
        let end = progress.pausedAt ?? date
        return max(0, Int(end.timeIntervalSince(start) - (progress.sectionAccumulatedPauseSeconds ?? 0)))
    }

    private func clockText(elapsed: Int) -> String {
        let value: Int
        switch section.format {
        case .amrap, .intervals:
            value = max(0, (section.durationSeconds ?? 0) - elapsed)
        case .emom:
            let interval = max(1, section.intervalSeconds ?? 60)
            value = interval - (elapsed % interval)
        case .forTime, .ladder, .maxLoad:
            value = section.timeCapSeconds.map { max(0, $0 - elapsed) } ?? elapsed
        }
        return Fmt.elapsed(value)
    }

    private func phaseText(elapsed: Int) -> String {
        if progress.status == .paused { return "Paused" }
        if section.format == .emom {
            return "Minute \(elapsed / max(1, section.intervalSeconds ?? 60) + 1) of \(section.rounds ?? 20)"
        }
        if section.format == .intervals, let work = section.workSeconds, let rest = section.restSeconds {
            let cycle = max(1, work + rest)
            return elapsed % cycle < work ? "Work" : "Rest"
        }
        return section.format.title
    }

    private func clockAccessibility(elapsed: Int) -> String {
        "\(phaseText(elapsed: elapsed)), \(clockText(elapsed: elapsed))"
    }
}

private struct ConditioningMovementList: View {
    @Environment(\.theme) private var theme
    let section: ConditioningSection
    let progress: ConditioningProgress
    let exerciseByID: [UUID: ExerciseLibraryModel]
    let onToggle: (ConditioningMovement) -> Void
    let onPartial: (ConditioningMovement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(section.name).font(.sectionTitle).foregroundStyle(theme.textPrimary)
                Spacer()
                Text("Round \(progress.round)").font(.bodyStrong).foregroundStyle(theme.accent)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(section.movements) { movement in
                        let completed = progress.completedMovementIDs.contains(movement.id)
                        Button { onToggle(movement) } label: {
                            HStack(spacing: Space.md) {
                                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(completed ? theme.success : theme.textTertiary)
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text(exerciseByID[movement.exerciseID]?.name ?? "Exercise")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(loadLabel(movement))
                                        .font(.label)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Text(targetLabel(movement))
                                    .font(.rowValue)
                                    .foregroundStyle(theme.accent)
                            }
                            .padding(Space.md)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(exerciseByID[movement.exerciseID]?.name ?? "Exercise"), \(targetLabel(movement))")
                        .accessibilityValue(completed ? "Completed" : "Not completed")
                        .accessibilityIdentifier("conditioning-movement-\(movement.id.uuidString)")
                        Button("Log Partial", systemImage: "plus.forwardslash.minus") { onPartial(movement) }
                            .font(.label)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, Space.md)
                            .padding(.bottom, Space.sm)
                        if movement.id != section.movements.last?.id { Divider().overlay(theme.separator) }
                    }
                }
            }
        }
    }

    private func targetLabel(_ movement: ConditioningMovement) -> String {
        let target = section.target(for: movement, round: progress.round)
        return "\(target.formatted(.number.precision(.fractionLength(target.rounded() == target ? 0 : 1)))) \(movement.targetUnit.shortLabel)"
    }

    private func loadLabel(_ movement: ConditioningMovement) -> String {
        guard let load = movement.targetLoad else {
            return movement.weightMode == .bodyweight ? "Bodyweight" : "No load"
        }
        let unit = exerciseByID[movement.exerciseID]?.effectiveWeightUnit.suffix ?? Fmt.unit.suffix
        return movement.weightMode == .bodyweightAssisted
            ? "Assisted · \(load.formatted(.number)) \(unit)"
            : "\(load.formatted(.number)) \(unit)"
    }
}

private struct ConditioningLiveActions: View {
    let section: ConditioningSection
    let round: Int
    let isPaused: Bool
    let onComplete: () -> Void
    let onPause: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            PrimaryButton(title: primaryTitle, systemImage: "checkmark", action: onComplete)
                .accessibilityIdentifier("complete-conditioning-round")
            SecondaryButton(title: isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill", action: onPause)
                .accessibilityIdentifier("pause-conditioning-workout")
        }
    }

    private var primaryTitle: String {
        if section.format == .forTime, section.movements.count == 1,
           let movement = section.movements.first {
            return "Complete \(Int(section.target(for: movement, round: round))) \(movement.targetUnit.shortLabel)"
        }
        return "Complete Round \(round)"
    }
}

private struct ConditioningPartialEditor: View {
    @Environment(\.dismiss) private var dismiss
    let movement: ConditioningMovement
    let exerciseName: String
    let initialValue: Double
    let onSave: (Double) -> Void
    @State private var value: Double

    init(movement: ConditioningMovement, exerciseName: String, initialValue: Double, onSave: @escaping (Double) -> Void) {
        self.movement = movement
        self.exerciseName = exerciseName
        self.initialValue = initialValue
        self.onSave = onSave
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent(exerciseName) {
                    TextField("Completed", value: $value, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Text(movement.targetUnit.shortLabel)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Partial Work")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(max(0, value)); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ConditioningScoreSheet: View {
    @Environment(\.theme) private var theme
    let plan: ConditioningPlan
    @Binding var progress: ConditioningProgress
    let exerciseByID: [UUID: ExerciseLibraryModel]
    let onKeepLogging: () -> Void
    let onSave: (Int, UUID?, Double, Double?) -> Void

    @State private var rounds: Int
    @State private var partialMovementID: UUID?
    @State private var partialValue: Double
    @State private var load: Double?

    init(
        plan: ConditioningPlan,
        progress: Binding<ConditioningProgress>,
        exerciseByID: [UUID: ExerciseLibraryModel],
        onKeepLogging: @escaping () -> Void,
        onSave: @escaping (Int, UUID?, Double, Double?) -> Void
    ) {
        self.plan = plan
        _progress = progress
        self.exerciseByID = exerciseByID
        self.onKeepLogging = onKeepLogging
        self.onSave = onSave
        let current = progress.wrappedValue
        _rounds = State(initialValue: current.fullRounds)
        let partial = current.partialValues.first(where: { $0.value > 0 })
        _partialMovementID = State(initialValue: partial?.key)
        _partialValue = State(initialValue: partial?.value ?? 0)
        _load = State(initialValue: current.recordedLoad)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Workout Score").font(.screenTitle).foregroundStyle(theme.textPrimary)
                    ForEach(results) { result in
                        Card {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(plan.sections.first(where: { $0.id == result.id })?.name ?? result.format.title)
                                    .font(.cardTitle)
                                Text(score(result))
                                    .font(.metricValue)
                                    .foregroundStyle(theme.accent)
                                if !result.completed && result.format == .forTime {
                                    Text("Time cap reached").font(.body).foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                    }
                    if let section = currentSection, section.scoreKind == .roundsAndReps || section.scoreKind == .completedIntervals {
                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                Text("Confirm Score").font(.cardTitle)
                                Stepper(value: $rounds, in: 0...999) {
                                    LabeledContent(section.format == .emom ? "Intervals" : "Full rounds") {
                                        Text("\(rounds)").font(.rowValue).foregroundStyle(theme.accent)
                                    }
                                }
                                if section.scoreKind == .roundsAndReps {
                                    Picker("Partial movement", selection: $partialMovementID) {
                                        Text("No partial work").tag(nil as UUID?)
                                        ForEach(section.movements) { movement in
                                            Text(exerciseByID[movement.exerciseID]?.name ?? "Exercise")
                                                .tag(Optional(movement.id))
                                        }
                                    }
                                    if partialMovementID != nil {
                                        LabeledContent("Partial reps") {
                                            TextField("0", value: $partialValue, format: .number)
                                                .keyboardType(.decimalPad)
                                                .multilineTextAlignment(.trailing)
                                                .frame(width: 90)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if currentSection?.scoreKind == .load {
                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                Text("Confirm Score").font(.cardTitle)
                                LabeledContent("Best load") {
                                    TextField("0", value: $load, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 90)
                                }
                            }
                        }
                    }
                    PrimaryButton(title: "Save Workout", systemImage: "checkmark") {
                        onSave(rounds, partialMovementID, max(0, partialValue), load)
                    }
                    SecondaryButton(title: "Keep Logging", systemImage: "arrow.uturn.backward", action: onKeepLogging)
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var results: [ConditioningSectionResult] {
        ConditioningProgressEngine.result(for: progress, plan: plan).sectionResults
    }

    private var currentSection: ConditioningSection? {
        plan.sections.indices.contains(progress.sectionIndex) ? plan.sections[progress.sectionIndex] : nil
    }

    private func score(_ result: ConditioningSectionResult) -> String {
        switch result.scoreKind {
        case .roundsAndReps:
            let partial = result.partialValue.map { " + \(Int($0)) \(partialUnit(result))" } ?? ""
            return "\(result.fullRounds ?? 0) rounds\(partial)"
        case .elapsedTime: return Fmt.elapsed(result.elapsedSeconds ?? 0)
        case .totalReps: return "\(result.totalReps ?? 0) reps"
        case .completedIntervals: return "\(result.completedIntervals ?? 0) intervals"
        case .load: return result.load.map { Fmt.loadUnit($0) } ?? "No load"
        }
    }

    private func partialUnit(_ result: ConditioningSectionResult) -> String {
        guard let movementID = result.partialMovementID,
              let movement = plan.sections.flatMap(\.movements).first(where: { $0.id == movementID }) else { return "reps" }
        return movement.targetUnit.shortLabel
    }
}
