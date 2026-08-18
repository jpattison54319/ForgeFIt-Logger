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
        .accessibilityIdentifier("conditioning-workout-theme-\(theme.family.rawValue)")
        .interactiveDismissDisabled()
        .task { await runClock() }
        .sheet(isPresented: $showScore) {
            ConditioningScoreSheet(
                plan: plan,
                progress: $progress,
                exerciseByID: exerciseByID,
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
                    let committed = apply(ConditioningProgressEvent(action: .setScore(
                        rounds: rounds,
                        partialMovementID: nil,
                        partialValue: 0,
                        load: load
                    ))) { applied in
                        guard applied else {
                            finishGate.end()
                            return
                        }
                        finishWorkout()
                    }
                    if !committed {
                        // The global persistence alert owns the exact retry.
                        // Release the local tap gate so Keep Editing remains
                        // usable while the durable model stays unchanged.
                        finishGate.end()
                    }
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

    @discardableResult
    private func apply(
        _ event: ConditioningProgressEvent,
        onCommit: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Bool {
        let workoutID = workout.id
        let blockID = block?.id
        return ConditioningEventPersistence.perform(
            container: modelContext.container,
            workoutID: workoutID,
            blockID: blockID,
            event: event,
            sourceDevice: "iphone-conditioning",
            distanceSource: .userEntered
        ) { outcome in
            guard outcome.applied else {
                onCommit(false)
                return
            }
            withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
                progress = outcome.progress
            }
            if outcome.startedSessionID != nil,
               outcome.startedSessionID != outcome.completedSessionID {
                Task { await HealthService.shared.requestAuthorizationIfNeeded() }
            }
            if let completedSessionID = outcome.completedSessionID {
                scheduleBlockEnrichment(
                    sessionID: completedSessionID,
                    progress: outcome.progress,
                    fallbackEnd: event.timestamp
                )
            }
            WatchLink.shared.publishDurableState()
            let readContext = ModelContext(modelContext.container)
            readContext.autosaveEnabled = false
            let committedWorkout = try? readContext.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first
            WorkoutActivityController.shared.update(
                workout: committedWorkout ?? workout,
                exercises: exercises
            )
            onCommit(true)
        }
    }

    private func finishWorkout() {
        if block != nil {
            showScore = false
            finishGate.end()
            onBlockCompleted?()
            return
        }
        if let error = WorkoutFinisher.finish(workoutID: workout.id, in: modelContext) {
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

    private func scheduleBlockEnrichment(
        sessionID: UUID,
        progress: ConditioningProgress,
        fallbackEnd: Date
    ) {
        guard block != nil else { return }
        let end = progress.completedAt ?? fallbackEnd
        let start = progress.startedAt ?? end
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
            .init(
                sessionID: sessionID,
                start: start,
                end: end,
                modality: .other,
                fallbackAvgHR: bleStats?.avgHR,
                fallbackMaxHR: bleStats?.maxHR,
                importsDistance: false,
                providesGPSDistance: false,
                hadManualIntervalPlan: false
            ),
            container: modelContext.container
        )
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
            Button(action: onFinish) {
                Text(completionContext.liveActionTitle)
                    .minimumTouchTarget()
            }
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
                        .foregroundStyle(theme.accentForeground)
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
    @AppStorage(ResistanceBandProfileStore.key) private var storedBandProfile = Data()
    let section: ConditioningSection
    let progress: ConditioningProgress
    let exerciseByID: [UUID: ExerciseLibraryModel]
    let onToggle: (ConditioningMovement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(section.name).font(.sectionTitle).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(roundLabel).font(.bodyStrong).foregroundStyle(theme.accentForeground)
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
                                    HStack(spacing: Space.xs) {
                                        if let preset = bandPreset(for: movement) {
                                            ResistanceBandSwatch(hue: preset.hue)
                                                .frame(width: 12, height: 12)
                                        }
                                        Text(loadLabel(movement))
                                            .font(.label)
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                }
                                Spacer()
                                Text(targetLabel(movement))
                                    .font(.rowValue)
                                    .foregroundStyle(theme.accentForeground)
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
        let exercise = exerciseByID[movement.exerciseID]
        let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
        let loadText = Fmt.loadUnit(load, unit: unit)
        let bandName = bandPreset(for: movement)?.name
        let resolvedLoad = bandName.map { "\($0) · \(loadText)" } ?? loadText
        return movement.weightMode == .bodyweightAssisted
            ? "Assisted · \(resolvedLoad)"
            : resolvedLoad
    }

    private var bandProfile: ResistanceBandProfile {
        (try? JSONDecoder().decode(ResistanceBandProfile.self, from: storedBandProfile))
            ?? ResistanceBandProfileStore.load()
    }

    private func bandPreset(for movement: ConditioningMovement) -> ResistanceBandPreset? {
        guard let exercise = exerciseByID[movement.exerciseID],
              ResistanceBandSupport.isBandExercise(name: exercise.name, equipment: exercise.equipment) else {
            return nil
        }
        return bandProfile.matching(weightKilograms: movement.targetLoad)
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
    let exerciseByID: [UUID: ExerciseLibraryModel]
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
        exerciseByID: [UUID: ExerciseLibraryModel],
        completionContext: ConditioningCompletionContext,
        isSaving: Bool,
        onKeepLogging: @escaping () -> Void,
        onSave: @escaping (Int, Double?) -> Void
    ) {
        self.plan = plan
        _progress = progress
        self.exerciseByID = exerciseByID
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
                                    .foregroundStyle(theme.accentForeground)
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
                                        Text("\(rounds)").font(.rowValue).foregroundStyle(theme.accentForeground)
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
                                    OptionalLoadField(
                                        placeholder: "0",
                                        value: $load,
                                        unit: scoreExercise?.effectiveWeightUnit ?? Fmt.unit,
                                        width: 112,
                                        supportsResistanceBands: scoreExercise.map {
                                            ResistanceBandSupport.isBandExercise(
                                                name: $0.name,
                                                equipment: $0.equipment
                                            )
                                        } ?? false
                                    )
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

    private var scoreExercise: ExerciseLibraryModel? {
        guard let movement = currentSection?.movements.first else { return nil }
        return exerciseByID[movement.exerciseID]
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
