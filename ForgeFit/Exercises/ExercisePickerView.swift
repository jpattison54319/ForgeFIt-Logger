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
            // Dedupe by id while filtering: CloudKit can't enforce unique
            // constraints, and duplicate IDs in a ForEach corrupt LazyVStack
            // layout (rows collapse to zero height / spacing goes erratic).
            var seen = Set<UUID>()
            let base = exercises.filter { ex in
                guard ex.deletedAt == nil, seen.insert(ex.id).inserted else { return false }
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
            var seen = Set<UUID>()
            let scored: [(ExerciseLibraryModel, Double)] = exercises.compactMap { ex in
                guard ex.deletedAt == nil, !alreadyIn.contains(ex.id), seen.insert(ex.id).inserted else { return nil }
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
                        .accessibilityIdentifier("create-exercise-button")
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateExerciseView(
                    initialName: search.trimmingCharacters(in: .whitespacesAndNewlines)
                ) { created in commit([created]) }
            }
            .sheet(item: $detailExercise) { exercise in
                NavigationStack {
                    ExerciseDetailView(exerciseID: exercise.id, workouts: history, exercises: exercises)
                }
            }
        }
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
                        Image(systemName: "sparkles").font(.tag)
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

                // Escape hatch under the results: if none of the matches is the
                // exercise being searched for, create it with the name prefilled.
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    createFromSearchButton
                        .padding(.horizontal, Space.lg)
                        .padding(.top, Space.sm)
                }
            }
            .padding(.vertical, Space.sm)
            .padding(.bottom, 90)
        }
    }

    /// "None of these? Create it" — rendered under search results and reused
    /// as the primary action of the no-results empty state. Opens the create
    /// form with the searched name prefilled.
    private var createFromSearchButton: some View {
        Button { showCreate = true } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create \"\(search.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                        .font(.system(size: 15, weight: .bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("New custom exercise")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(theme.accent)
            .padding(Space.md)
            .frame(maxWidth: .infinity)
            .background(theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("create-from-search")
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(theme.textTertiary)
            Text("No matches").font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Text("Try a different search or create a custom exercise.")
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            // Same prefilled create flow as the button under results.
            createFromSearchButton
                .padding(.horizontal, Space.lg)
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
                        // Full name, wrapped — users are *finding* an exercise
                        // here, so truncating to "…" hides the differentiator
                        // (routine-card previews still truncate by design).
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(exercise.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityIdentifier("exercise-row-\(exercise.name)")

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)   // HIG minimum touch target
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
            if let systemImage { Image(systemName: systemImage).font(.tag) }
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
    /// True when the form was reached from a search that found nothing — the
    /// name is prefilled and duplicate suggestions are skipped (the user just
    /// established the exercise doesn't exist).
    private let cameFromSearch: Bool

    @Query(sort: \ExerciseLibraryModel.name) private var allExercises: [ExerciseLibraryModel]

    @State private var name = ""
    @State private var primaryMuscle = "chest"
    @State private var secondaryMuscles: Set<String> = []
    @State private var equipment = "barbell"
    @State private var weightMode: WeightMode = .external
    @State private var preferredUnit: WeightUnit = Fmt.unit
    @State private var isCardio = false
    @State private var isUnilateral = false
    @State private var secondaryMusclesExpanded = false

    private var isEditing: Bool { editing != nil }

    /// Duplicate matches for the typed name. Populated by a debounced task —
    /// NOT a computed property — so keystrokes never pay for snapshot building
    /// or fuzzy scoring inside the render transaction (it caused visible input
    /// latency). Cleared and frozen once Create is tapped, so the just-created
    /// exercise can't flash in as its own "duplicate" while the sheet closes.
    @State private var duplicateCandidates: [ExerciseLibraryModel] = []
    @State private var snapshotMemo = Memo<String, ExerciseLibrarySnapshot>()
    @State private var isSaving = false

    /// Library exercises whose names closely match `query` — the same tolerant
    /// scorer as search (case, diacritics, small typos), strong matches only.
    /// The normalized snapshot is memoized per library state, so a keystroke
    /// costs one ranked search, not a full library re-normalization.
    private func duplicateMatches(for query: String) -> [ExerciseLibraryModel] {
        guard query.count >= 3 else { return [] }
        var seen = Set<UUID>()
        let live = allExercises.filter { $0.deletedAt == nil && seen.insert($0.id).inserted }
        var latest = Date.distantPast
        for exercise in live { latest = max(latest, exercise.updatedAt) }
        let snapshot = snapshotMemo("\(live.count)|\(latest.timeIntervalSince1970)") {
            ExerciseLibrarySnapshot(exercises: live.map(\.domainInfo))
        }
        let strong = snapshot.search(query, limit: 3).filter { $0.score >= 62 }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return strong.compactMap { byID[$0.exercise.id] }
    }

    init(editing: ExerciseLibraryModel? = nil, initialName: String = "", onCreate: @escaping (ExerciseLibraryModel) -> Void) {
        self.editing = editing
        self.onCreate = onCreate
        self.cameFromSearch = !initialName.isEmpty
        if editing == nil, !initialName.isEmpty {
            _name = State(initialValue: initialName)
        }
        if let editing {
            _name = State(initialValue: editing.name)
            _primaryMuscle = State(initialValue: editing.primaryMuscles.first ?? "chest")
            _secondaryMuscles = State(initialValue: Set(editing.secondaryMuscles))
            _equipment = State(initialValue: editing.equipment ?? "barbell")
            _weightMode = State(initialValue: editing.defaultWeightMode)
            _preferredUnit = State(initialValue: WeightUnit(rawValue: editing.preferredWeightUnitRaw ?? "") ?? Fmt.unit)
            _isCardio = State(initialValue: editing.isCardio)
            _isUnilateral = State(initialValue: editing.isUnilateral)
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
                                .accessibilityIdentifier("create-exercise-name")

                            // Duplicate guard: fuzzy-match the library as the user
                            // types (case / spelling tolerant) and offer the
                            // existing exercise instead of creating a twin.
                            if !isEditing, !isSaving, !cameFromSearch, !duplicateCandidates.isEmpty {
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.system(size: 12, weight: .bold))
                                        Text("Similar exercise\(duplicateCandidates.count == 1 ? "" : "s") already exist\(duplicateCandidates.count == 1 ? "s" : "")")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundStyle(theme.warmup)
                                    ForEach(duplicateCandidates) { candidate in
                                        Button {
                                            isSaving = true
                                            onCreate(candidate)
                                            dismiss()
                                        } label: {
                                            HStack(spacing: Space.sm) {
                                                ExerciseThumbnail(exercise: candidate, size: 34)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(candidate.name)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(theme.textPrimary)
                                                        .multilineTextAlignment(.leading)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                    Text("Use this instead")
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(theme.accent)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(theme.accent)
                                            }
                                            .padding(8)
                                            .background(theme.surfaceElevated)
                                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("use-existing-\(candidate.name)")
                                    }
                                }
                            }
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Movement").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                    Text("Unilateral = one arm/leg at a time; structured sets repeat per side.")
                                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Menu {
                                    Button("Bilateral") { isUnilateral = false }
                                    Button("Unilateral") { isUnilateral = true }
                                } label: {
                                    Text(isUnilateral ? "Unilateral" : "Bilateral")
                                        .font(.bodyStrong).foregroundStyle(theme.accent)
                                }
                            }
                            .opacity(isCardio ? 0.45 : 1)
                            .disabled(isCardio)
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
            // Debounced duplicate matching: restarts on every keystroke (task
            // id) and only does the fuzzy work after typing pauses, off the
            // keystroke's render pass.
            .task(id: name) {
                guard !isEditing, !isSaving, !cameFromSearch else { return }
                let query = name.trimmingCharacters(in: .whitespaces)
                guard query.count >= 3 else {
                    if !duplicateCandidates.isEmpty { duplicateCandidates = [] }
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !isSaving else { return }
                duplicateCandidates = duplicateMatches(for: query)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
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
        // Freeze and clear suggestions before the insert: the @Query update
        // would otherwise match the just-created exercise against its own name
        // and flash the "already exists" card while the sheet dismisses.
        isSaving = true
        duplicateCandidates = []
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
        exercise.isUnilateral = isCardio ? false : isUnilateral
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
