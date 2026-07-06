import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Full exercise picker: search, filter by muscle/equipment, multi-select, and
/// create custom exercises. Returns the chosen exercises to the caller.
struct ExercisePickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]

    /// When true the picker returns exactly one exercise (used by "Replace").
    var singleSelection = false
    /// Exercises already in the routine/workout being added to — drives the
    /// muscle profile behind "Suggested".
    var context: [ExerciseLibraryModel] = []
    /// Completed workouts, for ranking by the user's most-used exercises.
    var history: [WorkoutModel] = []
    let onAdd: ([ExerciseLibraryModel]) -> Void

    @State private var search = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var selected: Set<UUID> = []
    @State private var showCreate = false
    @State private var detailExercise: ExerciseLibraryModel?
    @State private var filteredMemo = Memo<String, [ExerciseLibraryModel]>()
    @State private var suggestedMemo = Memo<String, [ExerciseLibraryModel]>()

    private var exerciseFingerprint: String {
        var liveCount = 0
        var latest = Date.distantPast
        for exercise in exercises where exercise.deletedAt == nil {
            liveCount += 1
            latest = max(latest, exercise.updatedAt)
        }
        return "\(liveCount)|\(latest.timeIntervalSince1970)"
    }

    private var historyFingerprint: String {
        var completed = 0
        var latest = Date.distantPast
        for workout in history where workout.endedAt != nil && workout.deletedAt == nil {
            completed += 1
            latest = max(latest, workout.updatedAt)
        }
        return "\(completed)|\(latest.timeIntervalSince1970)"
    }

    private var contextFingerprint: String {
        context.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
    }

    private var filtered: [ExerciseLibraryModel] {
        let normalizedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(exerciseFingerprint)|\(normalizedSearch.lowercased())|\(muscle ?? "")|\(equipment ?? "")"
        return filteredMemo(key) {
            let base = exercises.filter { ex in
                guard ex.deletedAt == nil else { return false }
                if let muscle, !ex.primaryMuscles.contains(muscle), !ex.secondaryMuscles.contains(muscle) { return false }
                if let equipment, ex.equipment != equipment { return false }
                return true
            }
            guard !normalizedSearch.isEmpty else { return base }
            let snapshot = ExerciseLibrarySnapshot(
                exercises: base.map(\.domainInfo),
                aliases: GlobalExerciseLibrary.snapshot.aliases
            )
            let rankedIDs = snapshot.search(normalizedSearch, limit: base.count).map(\.exercise.id)
            let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return rankedIDs.compactMap { byID[$0] }
        }
    }

    /// Smart suggestions: score every exercise against (a) the muscle profile
    /// of what's already in the routine/workout — primaries loudest, secondary
    /// overlap (e.g. chest → push) quieter — and (b) how often the user has
    /// actually logged it. Renders nothing when there's no signal.
    private var suggested: [ExerciseLibraryModel] {
        guard search.isEmpty, muscle == nil, equipment == nil else { return [] }

        let key = "\(exerciseFingerprint)|\(historyFingerprint)|\(contextFingerprint)"
        return suggestedMemo(key) {
            var usage: [UUID: Int] = [:]
            for workout in history where workout.endedAt != nil && workout.deletedAt == nil {
                for we in workout.exercises { usage[we.exerciseID, default: 0] += 1 }
            }
            var muscleScore: [String: Double] = [:]
            for ex in context {
                for m in ex.primaryMuscles { muscleScore[m, default: 0] += 2 }
                for m in ex.secondaryMuscles { muscleScore[m, default: 0] += 1 }
            }
            guard !muscleScore.isEmpty || !usage.isEmpty else { return [] }

            let alreadyIn = Set(context.map(\.id))
            let scored: [(ExerciseLibraryModel, Double)] = exercises.compactMap { ex in
                guard ex.deletedAt == nil, !alreadyIn.contains(ex.id) else { return nil }
                var score = 0.0
                for m in ex.primaryMuscles { score += (muscleScore[m] ?? 0) }
                for m in ex.secondaryMuscles { score += (muscleScore[m] ?? 0) * 0.4 }
                score += Double(usage[ex.id] ?? 0) * 3
                guard score > 0 else { return nil }
                return (ex, score)
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterBar
                    Divider().overlay(theme.separator)
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }

                if !selected.isEmpty {
                    PrimaryButton(title: "Add \(selected.count) exercise\(selected.count == 1 ? "" : "s")") {
                        commit(exercises.filter { selected.contains($0.id) })
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateExerciseView { created in commit([created]) }
            }
            .sheet(item: $detailExercise) { exercise in
                NavigationStack {
                    ExerciseDetailView(exerciseID: exercise.id, workouts: history, exercises: exercises)
                }
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Menu {
                        Button("All muscles") { muscle = nil }
                        ForEach(ExerciseCatalog.muscleGroups, id: \.self) { m in
                            Button(m.capitalized) { muscle = m }
                        }
                    } label: {
                        FilterChip(title: muscle?.capitalized ?? "Muscle", active: muscle != nil, systemImage: "figure.arms.open")
                    }
                    Menu {
                        Button("All equipment") { equipment = nil }
                        ForEach(ExerciseCatalog.equipmentTypes, id: \.self) { e in
                            Button(e.capitalized) { equipment = e }
                        }
                    } label: {
                        FilterChip(title: equipment?.capitalized ?? "Equipment", active: equipment != nil, systemImage: "dumbbell")
                    }
                    if muscle != nil || equipment != nil {
                        Button {
                            muscle = nil; equipment = nil
                        } label: {
                            FilterChip(title: "Clear", active: false, systemImage: "xmark")
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: Space.sm) {
                let picks = suggested
                if !picks.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                        Text("Suggested").font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, Space.lg)

                    ForEach(picks) { exercise in
                        ExerciseRowLabel(
                            exercise: exercise,
                            selected: selected.contains(exercise.id),
                            onSelect: { toggle(exercise) },
                            onInfo: { detailExercise = exercise }
                        )
                        .padding(.horizontal, Space.lg)
                    }
                }

                HStack {
                    Text(picks.isEmpty ? "\(filtered.count) exercises" : "All exercises")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, picks.isEmpty ? 0 : Space.sm)

                ForEach(filtered) { exercise in
                    ExerciseRowLabel(
                        exercise: exercise,
                        selected: selected.contains(exercise.id),
                        onSelect: { toggle(exercise) },
                        onInfo: { detailExercise = exercise }
                    )
                    .padding(.horizontal, Space.lg)
                }
            }
            .padding(.vertical, Space.sm)
            .padding(.bottom, 90)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(theme.textTertiary)
            Text("No matches").font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Text("Try a different search or create a custom exercise.")
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            SecondaryButton(title: "Create \"\(search)\"", systemImage: "plus") { showCreate = true }
                .padding(.horizontal, Space.xxl)
            Spacer()
        }
        .padding(Space.lg)
    }

    private func toggle(_ exercise: ExerciseLibraryModel) {
        if singleSelection { commit([exercise]); return }
        if selected.contains(exercise.id) { selected.remove(exercise.id) }
        else { selected.insert(exercise.id) }
    }

    private func commit(_ list: [ExerciseLibraryModel]) {
        onAdd(list)
        dismiss()
    }
}

private struct ExerciseRowLabel: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    let selected: Bool
    let onSelect: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onSelect) {
                HStack(spacing: Space.md) {
                    ExerciseThumbnail(exercise: exercise)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(exercise.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            if exercise.ownerID != nil { Tag(text: "Custom", color: theme.accent, background: theme.accentSoft) }
                        }
                        Text([exercise.primaryMuscles.first?.capitalized, exercise.equipment?.capitalized]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        if exercise.isCardio {
                            Text(CardioKind.infer(name: exercise.name, equipment: exercise.equipment).metricLabels.prefix(4).joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(theme.secondaryAccent).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exercise details")
        }
        .padding(Space.md)
        .background(selected ? theme.accentSoft : theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

struct FilterChip: View {
    @Environment(\.theme) private var theme
    let title: String
    let active: Bool
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(active ? .white : theme.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(
            active ? .regular.tint(theme.accent.opacity(0.5)).interactive() : .regular.interactive(),
            in: Capsule()
        )
    }
}

/// Create a user-owned custom exercise.
struct CreateExerciseView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// When non-nil, the form edits this existing exercise in place instead of
    /// inserting a new one. Callback fires with the saved model in both modes.
    let editing: ExerciseLibraryModel?
    let onCreate: (ExerciseLibraryModel) -> Void

    @State private var name = ""
    @State private var primaryMuscle = "chest"
    @State private var secondaryMuscles: Set<String> = []
    @State private var equipment = "barbell"
    @State private var weightMode: WeightMode = .external
    @State private var preferredUnit: WeightUnit = Fmt.unit
    @State private var isCardio = false
    @State private var secondaryMusclesExpanded = false

    private var isEditing: Bool { editing != nil }

    init(editing: ExerciseLibraryModel? = nil, onCreate: @escaping (ExerciseLibraryModel) -> Void) {
        self.editing = editing
        self.onCreate = onCreate
        if let editing {
            _name = State(initialValue: editing.name)
            _primaryMuscle = State(initialValue: editing.primaryMuscles.first ?? "chest")
            _secondaryMuscles = State(initialValue: Set(editing.secondaryMuscles))
            _equipment = State(initialValue: editing.equipment ?? "barbell")
            _weightMode = State(initialValue: editing.defaultWeightMode)
            _preferredUnit = State(initialValue: WeightUnit(rawValue: editing.preferredWeightUnitRaw ?? "") ?? Fmt.unit)
            _isCardio = State(initialValue: editing.isCardio)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            FieldLabel("Name")
                            DarkTextField(text: $name, placeholder: "e.g. Atlantis Leg Press")
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            pickerRow("Primary muscle", selection: $primaryMuscle, options: ExerciseCatalog.muscleGroups)
                            Divider().overlay(theme.separator)
                            secondaryMuscleRow
                            Divider().overlay(theme.separator)
                            pickerRow("Equipment", selection: $equipment, options: ExerciseCatalog.equipmentTypes)
                            Divider().overlay(theme.separator)
                            HStack {
                                Text("Weight mode").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Menu {
                                    ForEach(WeightModeOption.allCases) { opt in
                                        Button(opt.label) { weightMode = opt.mode }
                                    }
                                } label: {
                                    Text(WeightModeOption.from(weightMode).label)
                                        .font(.bodyStrong).foregroundStyle(theme.accent)
                                }
                            }
                            Divider().overlay(theme.separator)
                            HStack {
                                Text("Weight unit").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Picker("Weight unit", selection: $preferredUnit) {
                                    Text("lb").tag(WeightUnit.lb)
                                    Text("kg").tag(WeightUnit.kg)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                                .disabled(isCardio)
                                .opacity(isCardio ? 0.45 : 1)
                            }
                            Divider().overlay(theme.separator)
                            Toggle(isOn: $isCardio) {
                                Text("Cardio exercise").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            }
                            .tint(theme.accent)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Exercise" : "New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Multi-select secondary muscles — each counts as half a set toward that
    /// muscle's weekly volume.
    private var secondaryMuscleRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    secondaryMusclesExpanded.toggle()
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Text("Secondary muscles").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(secondaryMuscles.isEmpty
                         ? "None"
                         : "\(secondaryMuscles.count) selected")
                        .font(.bodyStrong)
                        .foregroundStyle(secondaryMuscles.isEmpty ? theme.textTertiary : theme.accent)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(secondaryMusclesExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Each secondary muscle counts as half a set toward weekly volume.")
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)

            if secondaryMusclesExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(ExerciseCatalog.muscleGroups.filter { $0 != primaryMuscle }, id: \.self) { muscle in
                        Button {
                            toggleSecondaryMuscle(muscle)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: secondaryMuscles.contains(muscle) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(muscle.capitalized)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(secondaryMuscles.contains(muscle) ? theme.accent : theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40)
                            .background(secondaryMuscles.contains(muscle) ? theme.accentSoft : theme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !secondaryMuscles.isEmpty {
                    Button(role: .destructive) {
                        secondaryMuscles.removeAll()
                    } label: {
                        Label("Clear secondary muscles", systemImage: "xmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.danger)
                }
            }
        }
    }

    private func toggleSecondaryMuscle(_ muscle: String) {
        if secondaryMuscles.contains(muscle) {
            secondaryMuscles.remove(muscle)
        } else {
            secondaryMuscles.insert(muscle)
        }
    }

    private func pickerRow(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button(opt.capitalized) { selection.wrappedValue = opt }
                }
            } label: {
                Text(selection.wrappedValue.capitalized).font(.bodyStrong).foregroundStyle(theme.accent)
            }
        }
    }

    private func save() {
        if let editing {
            apply(to: editing)
            editing.userModified = true
            editing.needsReview = false
            editing.classificationSource = ClassificationSource.manual
            editing.classificationConfidence = 1.0
            editing.updatedAt = Date()
            try? modelContext.save()
            onCreate(editing)
        } else {
            let exercise = ExerciseLibraryModel(ownerID: ForgeFitDemo.userID, name: name)
            apply(to: exercise)
            modelContext.insert(exercise)
            try? modelContext.save()
            onCreate(exercise)
        }
        dismiss()
    }

    /// Write the current form state onto an exercise model. Shared by the create
    /// and edit paths so both stay in lockstep.
    private func apply(to exercise: ExerciseLibraryModel) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let kind = CardioKind.infer(name: trimmed, equipment: equipment)
        exercise.name = trimmed
        exercise.movementPattern = isCardio ? "cardio" : nil
        exercise.primaryMuscles = isCardio ? kind.musclesWorked : [primaryMuscle]
        exercise.secondaryMuscles = isCardio ? [] : secondaryMuscles.subtracting([primaryMuscle]).sorted()
        exercise.equipment = equipment
        exercise.defaultWeightMode = isCardio ? .bodyweight : weightMode
        exercise.preferredWeightUnitRaw = isCardio ? nil : preferredUnit.rawValue
        exercise.isCardio = isCardio
        exercise.category = isCardio ? "cardio" : "strength"
    }
}

private enum WeightModeOption: CaseIterable, Identifiable {
    case external, bodyweight, added, assisted
    var id: Self { self }
    var mode: WeightMode {
        switch self {
        case .external: .external
        case .bodyweight: .bodyweight
        case .added: .bodyweightAdded
        case .assisted: .bodyweightAssisted
        }
    }
    var label: String {
        switch self {
        case .external: "Added weight"
        case .bodyweight: "Bodyweight"
        case .added: "Weighted bodyweight"
        case .assisted: "Assisted"
        }
    }
    static func from(_ mode: WeightMode) -> WeightModeOption {
        switch mode {
        case .external: .external
        case .bodyweight: .bodyweight
        case .bodyweightAdded: .added
        case .bodyweightAssisted: .assisted
        }
    }
}
