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
    private let block: WorkoutBlockModel?
    private let onBlockCompleted: (() -> Void)?

    @State private var progress: ConditioningProgress
    @State private var showScore = false
    @State private var saveError: String?
    /// FF-006 in-flight gate: held from the first Save tap until the sheet
    /// dismisses (success) or the finisher surfaces a failure (release so the
    /// error alert's retry works).
    @State private var finishGate = WorkoutFinisher.InFlightGate()

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
        block = nil
        onBlockCompleted = nil
        let decodedPlan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON)
            ?? ConditioningPlan(sections: [])
        plan = decodedPlan
        _progress = State(initialValue: ConditioningProgress.decode(from: workout.conditioningProgressJSON) ?? ConditioningProgress())
    }

    init(
        workout: WorkoutModel,
        block: WorkoutBlockModel,
        exercises: [ExerciseLibraryModel],
        onMinimize: @escaping () -> Void,
        onCompleted: @escaping () -> Void
    ) {
        self.workout = workout
        self.exercises = exercises
        self.onMinimize = onMinimize
        onFinished = { _ in }
        self.block = block
        onBlockCompleted = onCompleted
        plan = ConditioningPlan.decode(from: block.planSnapshotJSON)
            ?? ConditioningPlan(sections: [])
        _progress = State(initialValue: ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress())
    }

    private var currentSection: ConditioningSection? {
        plan.sections.indices.contains(progress.sectionIndex) ? plan.sections[progress.sectionIndex] : nil
    }

    private var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var completionContext: ConditioningCompletionContext {
        block == nil ? .workout : .block
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        ConditioningLiveHeader(
                            title: blockTitle,
                            completionContext: completionContext,
                            onMinimize: onMinimize,
                            onFinish: { showScore = true }
                        )
                        if let section = currentSection {
                            ConditioningClockCard(section: section, progress: progress)
                            ConditioningMovementList(
                                section: section,
                                progress: progress,
                                exerciseByID: exerciseByID,
                                onToggle: toggleMovement
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
        .sheet(isPresented: $showScore) {
            ConditioningScoreSheet(
                plan: plan,
                progress: $progress,
                completionContext: completionContext,
                isSaving: finishGate.isActive,
                onKeepLogging: { showScore = false },
                onSave: { rounds, load in
                    // Acquired before ANY conditioning mutation so a rapid
                    // second commit cannot re-enter mid-apply (FF-006).
                    guard finishGate.tryBegin() else { return }
                    guard ConditioningProgressEngine.requiredRoundsRemaining(
                        for: progress,
                        plan: plan
                    ) == 0 else {
                        finishGate.end()
                        return
                    }
                    apply(ConditioningProgressEvent(action: .setScore(
                        rounds: rounds,
                        partialMovementID: nil,
                        partialValue: 0,
                        load: load
                    )))
                    finishWorkout()
                }
            )
            .interactiveDismissDisabled()
        }
        .alert(completionContext.failureTitle, isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? completionContext.failureFallback)
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

    private func apply(_ event: ConditioningProgressEvent) {
        let before = progress
        let next = ConditioningProgressEngine.apply(event, to: before, plan: plan)
        guard next != before else { return }
        materializeChanges(from: before, to: next, at: event.timestamp)
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) { progress = next }
        let resultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
        if let block {
            block.progressJSON = next.encodedJSON()
            block.resultJSON = resultJSON
            block.updatedAt = .now
            if before.status == .ready, next.status != .ready {
                startBlockSessionIfNeeded(block)
            }
        } else {
            workout.conditioningProgressJSON = next.encodedJSON()
            workout.conditioningResultJSON = resultJSON
        }
        workout.updatedAt = .now
        try? modelContext.save()
        WatchLink.shared.publishState(policy: .immediate)
        WorkoutActivityController.shared.update(workout: workout, exercises: exercises)
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
        let workoutExercise = workout.exercises.first {
            $0.exerciseID == movement.exerciseID
                && $0.generatedByWorkoutBlockID == block?.id
        }
            ?? makeWorkoutExercise(for: movement.exerciseID)
        if exercise.isCardio || exercise.isYoga {
            let session = workout.cardioSessions.first { $0.workoutExerciseID == workoutExercise.id }
                ?? makeCardioSession(for: workoutExercise, exercise: exercise, at: date)
            if movement.targetUnit == .seconds { session.durationSeconds = (session.durationSeconds ?? 0) + Int(value) }
            if movement.targetUnit == .meters {
                session.distanceMeters = (session.distanceMeters ?? 0) + value
                session.distanceSource = .userEntered
            }
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
        guard let workoutExercise = workout.exercises.first(where: {
            $0.exerciseID == movement.exerciseID
                && $0.generatedByWorkoutBlockID == block?.id
        }) else { return }
        if let set = workoutExercise.sets
            .filter({ $0.completedAt != nil })
            .sorted(by: { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
            .first {
            modelContext.delete(set)
            workoutExercise.sets.removeAll { $0.id == set.id }
        } else if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == workoutExercise.id }) {
            if movement.targetUnit == .seconds { session.durationSeconds = max(0, (session.durationSeconds ?? 0) - Int(value)) }
            if movement.targetUnit == .meters {
                session.distanceMeters = max(0, (session.distanceMeters ?? 0) - value)
                session.distanceSource = .userEntered
            }
        }
    }

    private func makeWorkoutExercise(for exerciseID: UUID) -> WorkoutExerciseModel {
        let workoutExercise = WorkoutExerciseModel(
            userID: workout.userID,
            exerciseID: exerciseID,
            position: block?.position ?? workout.exercises.count,
            generatedByWorkoutBlockID: block?.id
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
        let blockStart = block.flatMap { block in
            workout.cardioSessions.first {
                $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
            }?.liveStartedAt
        }
        let session = CardioSessionModel(
            userID: workout.userID,
            workoutExerciseID: workoutExercise.id,
            workoutBlockID: block?.id,
            modality: modality,
            startedAt: block == nil ? workout.startedAt : (blockStart ?? date),
            liveStartedAt: block == nil ? workout.startedAt : blockStart,
            endedAt: date,
            sourceDevice: "iphone-conditioning"
        )
        modelContext.insert(session)
        workout.cardioSessions.append(session)
        return session
    }

    private func finishWorkout() {
        let resultJSON = ConditioningProgressEngine.result(for: progress, plan: plan).encodedJSON()
        if let block {
            block.progressJSON = progress.encodedJSON()
            block.resultJSON = resultJSON
            block.updatedAt = .now
            completeBlockSession(block)
            workout.updatedAt = .now
            try? modelContext.save()
            showScore = false
            onBlockCompleted?()
            return
        }
        workout.conditioningResultJSON = resultJSON
        if let error = WorkoutFinisher.finish(workout, in: modelContext) {
            saveError = error
            finishGate.end()
            return
        }
        showScore = false
        onFinished(workout)
    }

    private var blockTitle: String {
        guard block != nil else { return workout.title ?? "Conditioning" }
        if plan.sections.count == 1, let name = plan.sections.first?.name, !name.isEmpty {
            return name
        }
        return "Conditioning"
    }

    private func startBlockSessionIfNeeded(_ block: WorkoutBlockModel) {
        let session = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        }
            ?? makeBlockSession(block)
        guard session.liveStartedAt == nil else { return }
        let now = progress.startedAt ?? .now
        session.startedAt = now
        session.liveStartedAt = now
        Task { await HealthService.shared.requestAuthorizationIfNeeded() }
    }

    private func makeBlockSession(_ block: WorkoutBlockModel) -> CardioSessionModel {
        let session = CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: .now,
            sourceDevice: "iphone-conditioning"
        )
        modelContext.insert(session)
        workout.cardioSessions.append(session)
        return session
    }

    private func completeBlockSession(_ block: WorkoutBlockModel) {
        let session = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        }
            ?? makeBlockSession(block)
        let end = progress.completedAt ?? .now
        let start = session.liveStartedAt ?? progress.startedAt ?? end
        session.liveStartedAt = start
        session.startedAt = start
        session.endedAt = end
        session.durationSeconds = max(1, Int(end.timeIntervalSince(start)))

        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        let container = modelContext.container
        Task { @MainActor in
            defer { withExtendedLifetime(container) {} }
            let snapshot = await HealthService.shared.importSnapshot(from: start, to: end, modality: .other)
            if let heartRate = snapshot.avgHR ?? bleStats?.avgHR { session.avgHR = heartRate }
            if let maxHeartRate = snapshot.maxHR ?? bleStats?.maxHR { session.maxHR = maxHeartRate }
            if let energy = snapshot.activeEnergyKcal { session.activeEnergyKcal = energy }
            session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(
                avgHR: session.avgHR,
                durationSeconds: session.durationSeconds
            )
            try? modelContext.save()
            await CardioSeriesService.finalize(
                session: session,
                hadManualIntervalPlan: false,
                in: modelContext
            )
        }
    }
}

private struct ConditioningLiveHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let completionContext: ConditioningCompletionContext
    let onMinimize: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack {
            CircleIconButton(
                systemImage: "chevron.down",
                label: completionContext.minimizeAccessibilityLabel,
                action: onMinimize
            )
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
            Spacer()
            Button(completionContext.liveActionTitle, action: onFinish)
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
                        LiveWorkoutHeartRateStat()
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(section.name).font(.sectionTitle).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(roundLabel).font(.bodyStrong).foregroundStyle(theme.accent)
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

    private var roundLabel: String {
        guard let rounds = section.prescribedRounds else { return "Round \(progress.round)" }
        if let target = section.repScheme.indices.contains(progress.round - 1)
            ? section.repScheme[progress.round - 1]
            : nil {
            return "Round \(progress.round) of \(rounds) · \(target) reps"
        }
        return "Round \(progress.round) of \(rounds)"
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

private struct ConditioningScoreSheet: View {
    @Environment(\.theme) private var theme
    let plan: ConditioningPlan
    @Binding var progress: ConditioningProgress
    let completionContext: ConditioningCompletionContext
    /// True while a finish is committing: the commit control disables and
    /// reads "Saving…" so a rapid second tap cannot re-enter (FF-006).
    let isSaving: Bool
    let onKeepLogging: () -> Void
    let onSave: (Int, Double?) -> Void

    @State private var rounds: Int
    @State private var load: Double?

    init(
        plan: ConditioningPlan,
        progress: Binding<ConditioningProgress>,
        completionContext: ConditioningCompletionContext,
        isSaving: Bool,
        onKeepLogging: @escaping () -> Void,
        onSave: @escaping (Int, Double?) -> Void
    ) {
        self.plan = plan
        _progress = progress
        self.completionContext = completionContext
        self.isSaving = isSaving
        self.onKeepLogging = onKeepLogging
        self.onSave = onSave
        let current = progress.wrappedValue
        _rounds = State(initialValue: current.fullRounds)
        _load = State(initialValue: current.recordedLoad)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text(completionContext.resultTitle).font(.screenTitle).foregroundStyle(theme.textPrimary)
                    ForEach(results) { result in
                        Card {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(plan.sections.first(where: { $0.id == result.id })?.name ?? result.format.title)
                                    .font(.cardTitle)
                                Text(score(result))
                                    .font(.metricValue)
                                    .foregroundStyle(theme.accent)
                                if let status = statusText(for: result) {
                                    Text(status).font(.body).foregroundStyle(theme.textSecondary)
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
                    if requiredRoundsRemaining > 0 {
                        Card {
                            HStack(alignment: .top, spacing: Space.sm) {
                                Image(systemName: "target")
                                    .foregroundStyle(theme.warmup)
                                Text(requiredTargetMessage)
                                    .font(.body)
                                    .foregroundStyle(theme.textPrimary)
                            }
                        }
                    }
                    PrimaryButton(title: isSaving ? "Saving…" : completionContext.commitTitle, systemImage: "checkmark") {
                        onSave(rounds, load)
                    }
                    .disabled(requiredRoundsRemaining > 0 || isSaving)
                    SecondaryButton(
                        title: completionContext.returnTitle,
                        systemImage: "arrow.uturn.backward",
                        action: onKeepLogging
                    )
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

    private var requiredRoundsRemaining: Int {
        ConditioningProgressEngine.requiredRoundsRemaining(for: progress, plan: plan)
    }

    private var requiredTargetMessage: String {
        let rounds = requiredRoundsRemaining
        return "Complete \(rounds) more round\(rounds == 1 ? "" : "s") before saving. The clock keeps running until the target is complete."
    }

    private func statusText(for result: ConditioningSectionResult) -> String? {
        guard !result.completed else { return nil }
        guard let section = plan.sections.first(where: { $0.id == result.id }) else {
            return "Incomplete"
        }
        return ConditioningSharePresentation.completionStatus(section: section, result: result).label
    }

    private func score(_ result: ConditioningSectionResult) -> String {
        switch result.scoreKind {
        case .roundsAndReps:
            return "\(result.fullRounds ?? 0) rounds"
        case .elapsedTime: return Fmt.elapsed(result.elapsedSeconds ?? 0)
        case .totalReps: return "\(result.totalReps ?? 0) reps"
        case .completedIntervals: return "\(result.completedIntervals ?? 0) intervals"
        case .load: return result.load.map { Fmt.loadUnit($0) } ?? "No load"
        }
    }

}
