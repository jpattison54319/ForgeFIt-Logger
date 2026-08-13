import SwiftUI
import ForgeCore

/// The live workout on the wrist: vertical pages for metrics, set logging,
/// and session controls — mirroring the phone logger, sized for a watch.
struct WatchActiveWorkoutView: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var selection = 1

    var body: some View {
        Group {
            if let plan = workout.conditioningPlan,
               let progress = workout.conditioningProgress {
                WatchConditioningWorkoutView(store: store, workout: workout, plan: plan, progress: progress)
            } else {
                standardWorkout
            }
        }
        .task { await store.recoverOrStartWorkoutSession() }
    }

    private var standardWorkout: some View {
        TabView(selection: $selection) {
            WatchMetricsPage(store: store, workout: workout).tag(0)
            WatchExercisesPage(store: store, workout: workout).tag(1)
            WatchControlsPage(store: store).tag(2)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            // The rest countdown follows the athlete onto every page. The
            // metrics page (0) has its own big headline, so the compact banner
            // rides the logging + controls pages so you never have to swipe to
            // find it.
            if selection != 0 {
                WatchRestBanner(workout: workout)
            }
        }
    }
}

private struct WatchConditioningWorkoutView: View {
    @Environment(\.dismiss) private var dismiss

    let store: WatchStore
    let workout: WatchWorkoutSnapshot
    let plan: ConditioningPlan
    let progress: ConditioningProgress
    let blockID: UUID?
    let movementNames: [UUID: String]

    @State private var page = 0
    @State private var engine = WatchWorkoutEngine.shared

    init(
        store: WatchStore,
        workout: WatchWorkoutSnapshot,
        plan: ConditioningPlan,
        progress: ConditioningProgress,
        blockID: UUID? = nil,
        movementNames: [UUID: String] = [:]
    ) {
        self.store = store
        self.workout = workout
        self.plan = plan
        self.progress = progress
        self.blockID = blockID
        self.movementNames = movementNames
    }

    private var section: ConditioningSection? {
        plan.sections.indices.contains(progress.sectionIndex) ? plan.sections[progress.sectionIndex] : nil
    }

    var body: some View {
        TabView(selection: $page) {
            workPage.tag(0)
            controlPage.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .task {
            await store.recoverOrStartWorkoutSession()
            if progress.status == .ready { store.applyConditioning(.start, blockID: blockID) }
        }
    }

    private var workPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let heartRate = engine.liveHeartRate(at: context.date)
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section?.format.title ?? "WORKOUT")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(WTheme.accent)
                            Text(clock(at: context.date))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(WTheme.gold)
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 0) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(WTheme.danger)
                                .symbolEffect(.pulse, isActive: heartRate != nil)
                            Text(heartRate.map(String.init) ?? "—")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(heartRate == nil ? .secondary : WTheme.danger)
                            Text("bpm").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            heartRate.map { "Live heart rate, \($0) beats per minute" }
                                ?? "Live heart rate, acquiring"
                        )
                    }
                }

                HStack {
                    Text(roundLabel)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text(roundTargetLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if let section {
                    ForEach(section.movements) { movement in
                        Button {
                            store.applyConditioning(.toggleMovement(movement.id), blockID: blockID)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: progress.completedMovementIDs.contains(movement.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(progress.completedMovementIDs.contains(movement.id) ? WTheme.teal : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name(for: movement)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(target(for: movement, in: section))
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: WTheme.minimumTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    store.applyConditioning(.completeRound, blockID: blockID)
                } label: {
                    Label(section?.format == .emom ? "Complete Interval" : "Complete Round", systemImage: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WTheme.accent)
            }
            .padding(.horizontal, 5)
        }
    }

    private var controlPage: some View {
        VStack(spacing: 10) {
            Image(systemName: "stopwatch.fill").font(.system(size: 30)).foregroundStyle(WTheme.gold)
            Text(section?.name ?? workout.title ?? "Conditioning")
                .font(.system(size: 16, weight: .bold)).multilineTextAlignment(.center)
            Button(progress.status == .paused ? "Resume" : "Pause") {
                store.applyConditioning(progress.status == .paused ? .resume : .pause, blockID: blockID)
            }
            .buttonStyle(.bordered)
            Button(blockID == nil ? "Finish Workout" : "Finish Conditioning") {
                if let blockID {
                    store.finishConditioningBlock(blockID)
                    dismiss()
                } else {
                    store.finishWorkout()
                }
            }
                .buttonStyle(.borderedProminent).tint(WTheme.teal)
                .disabled(requiredRoundsRemaining > 0 || store.isAwaitingWorkoutIdentity)
            if requiredRoundsRemaining > 0 {
                Text("\(requiredRoundsRemaining) round\(requiredRoundsRemaining == 1 ? "" : "s") left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
    }

    private var requiredRoundsRemaining: Int {
        ConditioningProgressEngine.requiredRoundsRemaining(for: progress, plan: plan)
    }

    private func clock(at date: Date) -> String {
        guard let section else { return "0:00" }
        let elapsed = ConditioningProgressEngine.elapsedSeconds(for: progress, at: date)
        let limit = section.durationSeconds ?? section.timeCapSeconds
        if [.amrap, .emom, .intervals].contains(section.format), let limit {
            return WFmt.rest(max(0, limit - elapsed))
        }
        return WFmt.elapsed(elapsed)
    }

    private func name(for movement: ConditioningMovement) -> String {
        movementNames[movement.exerciseID]
            ?? workout.exercises.first { $0.exerciseID == movement.exerciseID }?.name
            ?? "Exercise"
    }

    private func target(for movement: ConditioningMovement, in section: ConditioningSection) -> String {
        let amount = section.target(for: movement, round: progress.round)
            .formatted(.number.precision(.fractionLength(0...1)))
        let load = movement.targetLoad.map {
            " · \($0.formatted(.number.precision(.fractionLength(0...1)))) \(store.context?.unitSuffix ?? "lb")"
        } ?? ""
        return "\(amount) \(movement.targetUnit.shortLabel)\(load)"
    }

    private var roundLabel: String {
        guard let rounds = section?.prescribedRounds else { return "Round \(progress.round)" }
        return "Round \(progress.round)/\(rounds)"
    }

    private var roundTargetLabel: String {
        guard let section,
              section.repScheme.indices.contains(progress.round - 1) else {
            return "\(progress.fullRounds) done"
        }
        return "\(section.repScheme[progress.round - 1]) reps"
    }
}

/// A compact, always-on rest countdown shown over the logging/controls pages.
/// Display-only (never intercepts touches); the phone owns the timer.
private struct WatchRestBanner: View {
    let workout: WatchWorkoutSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let endsAt = workout.restEndsAt, endsAt > context.date {
                let remaining = max(0, Int(endsAt.timeIntervalSince(context.date).rounded(.up)))
                let isMicro = workout.restIsMicro == true
                let isAMRAP = workout.restLabel == "AMRAP"
                let tint = isAMRAP ? WTheme.gold : (isMicro ? WTheme.teal : WTheme.accent)
                HStack(spacing: 5) {
                    Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    Text(isAMRAP ? "AMRAP" : (isMicro ? "MINI" : "REST"))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(tint)
                    Spacer(minLength: 4)
                    Text(WFmt.rest(remaining))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(countsDown: true))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Metrics page

struct WatchMetricsPage: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var engine = WatchWorkoutEngine.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let heartRate = engine.liveHeartRate(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                // Interval step, then rest countdown, take over the headline —
                // whichever number the athlete needs right now.
                if let stepName = workout.intervalStepName,
                   let stepEndsAt = workout.intervalStepEndsAt, stepEndsAt > context.date {
                    intervalHeadline(
                        name: stepName, endsAt: stepEndsAt, now: context.date,
                        kind: workout.intervalStepKind,
                        round: workout.intervalRound,
                        next: workout.intervalNextName)
                } else if let restEndsAt = workout.restEndsAt, restEndsAt > context.date {
                    restHeadline(
                        endsAt: restEndsAt,
                        now: context.date,
                        isMicro: workout.restIsMicro == true,
                        label: workout.restLabel
                    )
                } else {
                    Text(WFmt.elapsed(max(0, Int(context.date.timeIntervalSince(workout.startedAt)))))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WTheme.gold)
                }

                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WTheme.danger)
                        .symbolEffect(.pulse, isActive: heartRate != nil)
                    Text(heartRate.map(String.init) ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm").font(.system(size: 13)).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    metric("kcal", engine.activeEnergyKcal.map { String(Int($0)) } ?? "—", WTheme.teal)
                    metric("avg", engine.avgHR.map(String.init) ?? "—", .secondary)
                    metric("max", engine.maxHR.map(String.init) ?? "—", .secondary)
                }

                if let distance = engine.distanceMeters, distance > 0 {
                    metric("dist",
                           WFmt.distance(distance, unit: store.context?.effectiveDistanceUnit ?? .km),
                           WTheme.accent)
                }

                Spacer(minLength: 0)

                Text("\(workout.completedSets)/\(workout.totalSets) sets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WTheme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("")
    }

    private func intervalHeadline(
        name: String, endsAt: Date, now: Date,
        kind: String? = nil, round: String? = nil, next: String? = nil
    ) -> some View {
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        // Work runs hot (teal), recovery cools down (sage), book-ends gold —
        // the wrist reads the state from color alone.
        let tint: Color = switch kind {
        case "work": WTheme.teal
        case "recover": WTheme.accent
        case "warmup", "cooldown": WTheme.gold
        case "pose": WTheme.accent   // yoga hold — calm sage, not work-teal
        default: WTheme.teal
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(name.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let round {
                    Text("· \(round)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(WFmt.rest(remaining))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
            if let next {
                Text("Next: \(next)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func restHeadline(endsAt: Date, now: Date, isMicro: Bool, label: String?) -> some View {
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        let isAMRAP = label == "AMRAP"
        let tint = isAMRAP ? WTheme.gold : (isMicro ? WTheme.teal : WTheme.accent)
        return VStack(alignment: .leading, spacing: 0) {
            Text(isAMRAP ? "AMRAP" : (isMicro ? "MINI-REST" : "REST"))
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(tint)
            Text(WFmt.rest(remaining))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Exercises / set logging page

struct WatchExercisesPage: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var engine = WatchWorkoutEngine.shared

    var body: some View {
        NavigationStack {
            List {
                heartRateRow

                ForEach(workout.exercises) { exercise in
                    if exercise.workoutBlockKindRaw == "conditioning",
                       let plan = exercise.conditioningPlan,
                       let progress = exercise.conditioningProgress {
                        NavigationLink {
                            WatchConditioningWorkoutView(
                                store: store,
                                workout: workout,
                                plan: plan,
                                progress: progress,
                                blockID: exercise.id,
                                movementNames: exercise.conditioningMovementNames ?? [:]
                            )
                        } label: {
                            blockRow(exercise, systemImage: "stopwatch.fill")
                        }
                    } else if exercise.isCardio {
                        cardioRow(exercise)
                    } else {
                        NavigationLink {
                            WatchSetListView(store: store, exerciseID: exercise.id)
                        } label: {
                            exerciseRow(exercise)
                        }
                    }
                }
            }
            .navigationTitle("Exercises")
        }
    }

    private func blockRow(_ exercise: WatchExerciseSnapshot, systemImage: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(cardioSubtitle(exercise.cardioState))
                    .font(.system(size: 12))
                    .foregroundStyle(WTheme.teal)
            }
            Spacer()
            Image(systemName: systemImage)
                .foregroundStyle(WTheme.teal)
        }
    }

    private var heartRateRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let heartRate = engine.liveHeartRate(at: context.date)
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WTheme.danger)
                    .symbolEffect(.pulse, isActive: heartRate != nil)
                Text(heartRate.map { "\($0) bpm" } ?? (engine.hasReceivedHeartRate ? "Reacquiring HR…" : "Starting HR…"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(heartRate == nil ? .secondary : WTheme.danger)
                Spacer()
                if let avg = engine.avgHR {
                    Text("avg \(avg)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .listRowBackground(WTheme.surface)
    }

    private func exerciseRow(_ exercise: WatchExerciseSnapshot) -> some View {
        let done = exercise.sets.filter(\.completed).count
        return VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 5) {
                if let group = exercise.supersetGroup {
                    Text("Superset \(supersetLetter(group))")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(WTheme.teal)
                }
                Text("\(done)/\(exercise.sets.count) sets")
                    .font(.system(size: 12))
                    .foregroundStyle(done == exercise.sets.count && !exercise.sets.isEmpty ? WTheme.success : .secondary)
            }
        }
    }

    /// Cardio never shows sets — it's a Start/Complete segment, auto-filled
    /// from the session's health data.
    private func cardioRow(_ exercise: WatchExerciseSnapshot) -> some View {
        Button {
            switch exercise.cardioState {
            case .notStarted, nil: store.startCardio(exercise)
            case .running: store.completeCardio(exercise)
            case .completed: break
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        if let group = exercise.supersetGroup {
                            Text("Superset \(supersetLetter(group))")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(WTheme.teal)
                        }
                        Text(cardioSubtitle(exercise.cardioState))
                            .font(.system(size: 12))
                            .foregroundStyle(WTheme.teal)
                    }
                }
                Spacer()
                Image(systemName: cardioIcon(exercise.cardioState))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(exercise.cardioState == .completed ? WTheme.success : WTheme.teal)
            }
        }
    }

    private func cardioSubtitle(_ state: WatchExerciseSnapshot.CardioState?) -> String {
        switch state {
        case .running: "Recording…"
        case .completed: "Completed"
        default: "Ready"
        }
    }

    private func cardioIcon(_ state: WatchExerciseSnapshot.CardioState?) -> String {
        switch state {
        case .running: "stop.circle.fill"
        case .completed: "checkmark.circle.fill"
        default: "play.circle.fill"
        }
    }

    private func supersetLetter(_ group: Int) -> String {
        guard group >= 0, group < 26 else { return "\(group + 1)" }
        let scalar = UnicodeScalar(65 + group)!
        return String(Character(scalar))
    }
}

/// One exercise's sets. Flat rows complete directly; structured and timed
/// types visibly navigate into their full execution flow instead of treating
/// the entire protocol as one checkmark.
struct WatchSetListView: View {
    let store: WatchStore
    let exerciseID: UUID

    @State private var editingSet: WatchSetSnapshot?

    private var exercise: WatchExerciseSnapshot? {
        store.activeWorkout?.exercises.first { $0.id == exerciseID }
    }

    /// The flat set the double-tap gesture targets. A structured/AMRAP block
    /// must never be collapsed into the whole-set completion shortcut.
    private var firstUncompletedSetID: UUID? {
        exercise?.sets.first { !$0.completed && !$0.isStructured && !$0.isAMRAP }?.id
    }

    var body: some View {
        List {
            if let exercise {
                ForEach(exercise.sets) { set in
                    if set.isStructured {
                        NavigationLink {
                            WatchStructuredSetView(store: store, exercise: exercise, set: set)
                        } label: {
                            specialtySetLabel(set)
                        }
                        .listRowBackground(specialtyRowBackground(set))
                    } else if set.isAMRAP {
                        NavigationLink {
                            WatchAMRAPSetView(store: store, exercise: exercise, set: set)
                        } label: {
                            specialtySetLabel(set)
                        }
                        .listRowBackground(specialtyRowBackground(set))
                    } else {
                        HStack(spacing: 6) {
                            Button {
                                store.toggleSet(set, in: exercise)
                            } label: {
                                HStack(spacing: 8) {
                                    setBadge(set)
                                    Text(setDescription(set))
                                        .font(.system(size: 15, weight: .semibold))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer()
                                    Image(systemName: set.completed ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(set.completed ? WTheme.success : .secondary)
                                }
                                .frame(minHeight: WTheme.minimumTouchTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Long-press stays as a shortcut — the pencil is
                            // the discoverable path.
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    editingSet = set
                                }
                            )
                            .handGestureShortcut(.primaryAction, isEnabled: set.id == firstUncompletedSetID)
                            Button {
                                editingSet = set
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(WTheme.accent)
                                    .frame(width: 28, height: 28)
                                    .frame(minWidth: WTheme.minimumTouchTarget, minHeight: WTheme.minimumTouchTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit load and reps")
                        }
                        .listRowBackground(specialtyRowBackground(set))
                    }
                }
            }
        }
        .navigationTitle(exercise?.name ?? "Sets")
        .sheet(item: $editingSet) { set in
            if let exercise {
                WatchSetEditView(store: store, exercise: exercise, set: set)
            }
        }
    }

    private func setDescription(_ set: WatchSetSnapshot) -> String {
        if set.isStructured {
            let progress = set.structuredProgress
            let sideOne: String
            if set.setType == .cluster {
                sideOne = progress.miniReps.map(String.init).joined(separator: "+")
            } else {
                let activation = progress.activationReps.map(String.init) ?? "—"
                let minis = progress.miniReps.map(String.init).joined(separator: "+")
                sideOne = minis.isEmpty ? activation : "\(activation) + \(minis)"
            }
            if set.usesSides, !progress.side2MiniReps.isEmpty || progress.side2ActivationReps != nil {
                return "S1 \(sideOne) · S2 logged"
            }
            return sideOne.isEmpty ? "Ready" : sideOne
        }
        if set.isAMRAP {
            let window = set.durationSeconds.map {
                "\($0 / 60):\(String(format: "%02d", $0 % 60))"
            } ?? "—"
            let reps = set.reps.map { " · \($0) reps" } ?? ""
            return "\(window)\(reps)"
        }
        let unit = set.unitSuffix ?? store.context?.unitSuffix ?? "lb"
        let weight = set.weight.map { "\(WFmt.weight($0))\(unit)" }
        let reps = set.reps.map { "× \($0)" }
        let parts = [weight, reps].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    private func specialtySetLabel(_ set: WatchSetSnapshot) -> some View {
        HStack(spacing: 8) {
            setBadge(set)
            VStack(alignment: .leading, spacing: 1) {
                Text(set.isAMRAP ? "AMRAP" : structuredTitle(set.setType))
                    .font(.system(size: 13, weight: .bold))
                Text(setDescription(set))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: set.completed ? "checkmark.circle.fill" : "chevron.right.circle")
                .foregroundStyle(set.completed ? WTheme.success : WTheme.teal)
        }
    }

    private func setBadge(_ set: WatchSetSnapshot) -> some View {
        Text(set.label.isEmpty ? "–" : set.label)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(set.completed ? WTheme.success : WTheme.accent)
            .frame(width: 26, alignment: .leading)
    }

    private func specialtyRowBackground(_ set: WatchSetSnapshot) -> some View {
        (set.completed ? WTheme.success.opacity(0.12) : WTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func structuredTitle(_ type: SetType) -> String {
        switch type {
        case .myoRep: "Myo-Reps"
        case .restPause: "Rest-Pause"
        case .cluster: "Cluster"
        default: "Structured Set"
        }
    }
}

// MARK: - Controls page

struct WatchControlsPage: View {
    let store: WatchStore
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                confirmFinish = true
            } label: {
                Label("Finish", systemImage: "checkmark")
                    .font(.system(size: 16, weight: .bold))
            }
            .tint(WTheme.success)
            .buttonStyle(.borderedProminent)
            .disabled(store.conditioningFinishBlocker != nil || store.isAwaitingWorkoutIdentity)

            if let blocker = store.conditioningFinishBlocker {
                Text(blocker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if store.isAwaitingWorkoutIdentity {
                Text("Syncing workout…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                confirmDiscard = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(WTheme.danger)
            .disabled(store.isAwaitingWorkoutIdentity)
        }
        .padding(.horizontal, 4)
        .confirmationDialog("Finish workout?", isPresented: $confirmFinish) {
            Button("Finish Workout") { store.finishWorkout() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Discard workout?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { store.discardWorkout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Same stakes-warning the phone shows — discard is irreversible.
            Text("All logged sets from this session will be lost.")
        }
    }
}

// MARK: - Summary

/// Post-workout reflection: what you did and how your body responded.
struct WatchSummaryView: View {
    let store: WatchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Workout Complete", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WTheme.success)

                if let summary = store.summary {
                    summaryRow("Duration", WFmt.elapsed(summary.durationSeconds), WTheme.gold)
                    summaryRow("Sets", "\(summary.completedSets)", WTheme.accent)
                    summaryRow("Avg HR", summary.metrics.avgHR.map { "\($0) bpm" } ?? "—", WTheme.danger)
                    summaryRow("Max HR", summary.metrics.maxHR.map { "\($0) bpm" } ?? "—", WTheme.danger)
                    summaryRow("Energy", summary.metrics.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—", WTheme.teal)
                }

                Button("Done") { store.summary = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(WTheme.accent)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
