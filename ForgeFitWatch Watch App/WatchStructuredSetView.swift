import ForgeCore
import SwiftUI

/// Full wrist execution for Myo-rep, legacy rest-pause, and cluster blocks.
/// Activation and each mini-set are explicit performed actions; completing
/// the enclosing set remains a separate, persistent final action.
struct WatchStructuredSetView: View {
    let store: WatchStore
    let exerciseID: UUID
    let setID: UUID

    @State private var selectedSide: Int
    @State private var activationDraft: Int
    @State private var miniDraft: Int
    @State private var weightDisplay: Double

    private static let poundsPerKilogram = 2.2046226218

    init(store: WatchStore, exercise: WatchExerciseSnapshot, set: WatchSetSnapshot) {
        self.store = store
        self.exerciseID = exercise.id
        self.setID = set.id
        let progress = set.structuredProgress
        let initialSide = set.usesSides && (
            progress.side2ActivationReps != nil || !progress.side2MiniReps.isEmpty
        ) ? 2 : 1
        _selectedSide = State(initialValue: initialSide)
        _activationDraft = State(initialValue: Self.activationSuggestion(
            set: set,
            exercise: exercise,
            progress: progress,
            side: initialSide
        ))
        _miniDraft = State(initialValue: Self.miniSuggestion(
            set: set,
            exercise: exercise,
            progress: progress,
            side: initialSide
        ))
        _weightDisplay = State(initialValue: set.weight ?? 0)
    }

    private var exercise: WatchExerciseSnapshot? {
        store.activeWorkout?.exercises.first { $0.id == exerciseID }
    }

    private var set: WatchSetSnapshot? {
        exercise?.sets.first { $0.id == setID }
    }

    var body: some View {
        ScrollView {
            if let exercise, let set {
                VStack(alignment: .leading, spacing: 10) {
                    statusHeader(set)

                    if set.usesSides {
                        Picker("Side", selection: $selectedSide) {
                            Text("Side 1").tag(1)
                            Text("Side 2").tag(2)
                        }
                        .accessibilityIdentifier("structured-set-side")
                    }

                    if set.supportsLoadEntry {
                        loadStepper(set)
                    }

                    if set.setType == .cluster {
                        miniSetSection(set, exercise: exercise)
                    } else {
                        activationSection(set, exercise: exercise)
                        if set.structuredProgress.activation(for: selectedSide) != nil {
                            miniSetSection(set, exercise: exercise)
                        }
                    }

                    Button {
                        store.toggleSet(set, in: exercise)
                    } label: {
                        Label(
                            set.completed ? "Reopen \(typeTitle(set.setType))" : "Complete \(typeTitle(set.setType))",
                            systemImage: set.completed ? "arrow.uturn.backward" : "checkmark"
                        )
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(set.completed ? WTheme.surface : WTheme.success)
                    .accessibilityIdentifier("complete-structured-set")
                }
                .padding(.horizontal, 5)
                .onChange(of: selectedSide) { _, side in
                    activationDraft = Self.activationSuggestion(
                        set: set,
                        exercise: exercise,
                        progress: set.structuredProgress,
                        side: side
                    )
                    miniDraft = Self.miniSuggestion(
                        set: set,
                        exercise: exercise,
                        progress: set.structuredProgress,
                        side: side
                    )
                }
            }
        }
        .navigationTitle(set.map { typeTitle($0.setType) } ?? "Set")
    }

    private func statusHeader(_ set: WatchSetSnapshot) -> some View {
        HStack {
            Text(typeTitle(set.setType))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(typeTint(set.setType))
            Spacer()
            if set.completed {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WTheme.success)
            }
        }
    }

    private func loadStepper(_ set: WatchSetSnapshot) -> some View {
        Stepper(value: $weightDisplay, in: 0...2_000, step: loadStep(set)) {
            HStack {
                Text(loadLabel(set))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(WFmt.weight(weightDisplay)) \(set.unitSuffix ?? "lb")")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WTheme.accent)
            }
        }
        .disabled(set.completed)
        .accessibilityIdentifier("structured-set-load")
    }

    private func activationSection(
        _ set: WatchSetSnapshot,
        exercise: WatchExerciseSnapshot
    ) -> some View {
        let progress = set.structuredProgress
        let isLogged = progress.activation(for: selectedSide) != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Activation")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isLogged ? WTheme.success : .secondary)

            Stepper(value: $activationDraft, in: 0...100) {
                HStack {
                    Text("Reps").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(activationDraft)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WTheme.teal)
                }
            }
            .disabled(set.completed)

            Button {
                logActivation(set, in: exercise, wasLogged: isLogged)
            } label: {
                Label(
                    isLogged ? "Update Activation" : "Log Activation",
                    systemImage: isLogged ? "checkmark.circle.fill" : "bolt.fill"
                )
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isLogged ? WTheme.surface : WTheme.accent)
            .disabled(set.completed || activationDraft <= 0)
            .accessibilityIdentifier("log-watch-activation")
        }
    }

    private func miniSetSection(
        _ set: WatchSetSnapshot,
        exercise: WatchExerciseSnapshot
    ) -> some View {
        let minis = set.structuredProgress.minis(for: selectedSide)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mini Sets")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text(miniProgress(set, count: minis.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if !minis.isEmpty {
                Text(minis.map(String.init).joined(separator: "  ·  "))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(WTheme.teal)
                    .lineLimit(2)
            }

            Stepper(value: $miniDraft, in: 1...100) {
                HStack {
                    Text(nextMiniLabel(set, count: minis.count))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(miniDraft)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WTheme.teal)
                }
            }
            .disabled(set.completed)

            Button {
                logMiniSet(set, in: exercise)
            } label: {
                Label("Log Mini Set", systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WTheme.teal)
            .disabled(set.completed)
            .accessibilityIdentifier("log-watch-mini-set")

            if !minis.isEmpty {
                Button("Undo Last Mini Set", systemImage: "arrow.uturn.backward") {
                    undoLastMiniSet(set, in: exercise)
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(set.completed)
                .accessibilityIdentifier("undo-watch-mini-set")
            }
        }
    }

    private func logActivation(
        _ set: WatchSetSnapshot,
        in exercise: WatchExerciseSnapshot,
        wasLogged: Bool
    ) {
        var progress = set.structuredProgress
        progress.setActivation(activationDraft, for: selectedSide)
        store.updateStructuredSet(
            set,
            in: exercise,
            progress: progress,
            event: wasLogged ? .correction : .activation,
            side: selectedSide,
            weightKg: weightKilograms(set)
        )
        miniDraft = Self.miniSuggestion(
            set: set,
            exercise: exercise,
            progress: progress,
            side: selectedSide
        )
    }

    private func logMiniSet(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot) {
        var progress = set.structuredProgress
        var minis = progress.minis(for: selectedSide)
        minis.append(miniDraft)
        progress.setMinis(minis, for: selectedSide)
        store.updateStructuredSet(
            set,
            in: exercise,
            progress: progress,
            event: .miniSet,
            side: selectedSide,
            weightKg: weightKilograms(set)
        )
        miniDraft = Self.miniSuggestion(
            set: set,
            exercise: exercise,
            progress: progress,
            side: selectedSide
        )
    }

    private func undoLastMiniSet(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot) {
        var progress = set.structuredProgress
        var minis = progress.minis(for: selectedSide)
        guard let removed = minis.popLast() else { return }
        progress.setMinis(minis, for: selectedSide)
        miniDraft = removed
        store.updateStructuredSet(
            set,
            in: exercise,
            progress: progress,
            event: .correction,
            side: selectedSide,
            weightKg: weightKilograms(set)
        )
    }

    private func miniProgress(_ set: WatchSetSnapshot, count: Int) -> String {
        let planned = set.setType == .cluster
            ? (set.plannedMiniReps?.count ?? 0)
            : (set.plannedMiniSetCount ?? 0)
        return planned > 0 ? "\(count)/\(planned)" : "\(count) logged"
    }

    private func nextMiniLabel(_ set: WatchSetSnapshot, count: Int) -> String {
        if set.setType == .cluster, let plan = set.plannedMiniReps, plan.indices.contains(count) {
            return "Mini \(count + 1) · goal \(plan[count])"
        }
        return "Mini \(count + 1) reps"
    }

    private func loadStep(_ set: WatchSetSnapshot) -> Double {
        set.unitSuffix == "kg" ? 2.5 : 5
    }

    private func loadLabel(_ set: WatchSetSnapshot) -> String {
        switch set.weightMode {
        case .bodyweightAdded: "Added Load"
        case .bodyweightAssisted: "Assistance"
        default: "Load"
        }
    }

    private func weightKilograms(_ set: WatchSetSnapshot) -> Double? {
        guard set.supportsLoadEntry, weightDisplay > 0 else { return nil }
        return set.unitSuffix == "kg"
            ? weightDisplay
            : weightDisplay / Self.poundsPerKilogram
    }

    private func typeTitle(_ type: SetType) -> String {
        switch type {
        case .myoRep: "Myo-Reps"
        case .restPause: "Rest-Pause"
        case .cluster: "Cluster"
        default: "Structured Set"
        }
    }

    private func typeTint(_ type: SetType) -> Color {
        type == .cluster ? WTheme.gold : WTheme.teal
    }

    private static func activationSuggestion(
        set: WatchSetSnapshot,
        exercise: WatchExerciseSnapshot,
        progress: WatchStructuredSetProgress,
        side: Int
    ) -> Int {
        if let logged = progress.activation(for: side) { return logged }
        if side == 2, let sideOne = progress.activationReps { return sideOne }
        guard let index = exercise.sets.firstIndex(where: { $0.id == set.id }) else { return 0 }
        return exercise.sets[..<index].reversed().first {
            $0.setType == set.setType && $0.reps != nil
        }?.reps ?? 0
    }

    private static func miniSuggestion(
        set: WatchSetSnapshot,
        exercise: WatchExerciseSnapshot,
        progress: WatchStructuredSetProgress,
        side: Int
    ) -> Int {
        let minis = progress.minis(for: side)
        if set.setType == .cluster,
           let plan = set.plannedMiniReps,
           plan.indices.contains(minis.count) {
            return max(1, plan[minis.count])
        }
        if let last = minis.last { return last }
        if side == 2, let sideOne = progress.miniReps.first { return sideOne }
        if let index = exercise.sets.firstIndex(where: { $0.id == set.id }),
           let previous = exercise.sets[..<index].reversed().first(where: {
               $0.setType == set.setType && !($0.miniReps ?? []).isEmpty
           }),
           let reps = previous.miniReps?.first {
            return reps
        }
        return 3
    }
}
