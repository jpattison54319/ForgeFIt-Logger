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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]

    /// When true the picker returns exactly one exercise (used by "Replace").
    var singleSelection = false
    /// Pre-applies a modality filter (e.g. the yoga flow builder only offers
    /// poses). The user can still clear or change it.
    var presetModality: Modality?
    /// Used by the flow builder: Yoga Session is the container card, not a
    /// pose that can be added inside another flow.
    var excludeYogaSession = false
    /// Used when adding to a routine or live workout: individual yoga poses
    /// only make sense inside a flow, so only the Yoga Session container is
    /// offered. The flow is configured afterwards from the session card.
    var excludeYogaPoses = false
    /// Exercises already in the routine/workout being added to — drives the
    /// muscle profile behind "Suggested".
    var context: [ExerciseLibraryModel] = []
    /// Completed workouts, for ranking by the user's most-used exercises.
    var history: [WorkoutModel] = []
    let onAdd: ([ExerciseLibraryModel]) -> Void

    @State private var search = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var modalityFilter: Modality?
    @State private var selected: Set<UUID> = []
    @State private var showCreate = false
    @State private var detailExercise: ExerciseLibraryModel?
    @State private var filteredMemo = Memo<String, [ExerciseLibraryModel]>()
    @State private var suggestedMemo = Memo<String, [ExerciseLibraryModel]>()
    /// Keyed by filter state only (NOT the query): the filtered base list and
    /// its search snapshot are invariant per keystroke, and the snapshot init
    /// re-normalizes every library name — rebuilding both on each keystroke
    /// made typing lag scale with library size.
    @State private var filteredBaseMemo = Memo<String, [ExerciseLibraryModel]>()
    @State private var searchSnapshotMemo = Memo<String, ExerciseLibrarySnapshot>()

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
        let filterKey = "\(exerciseFingerprint)|\(muscle ?? "")|\(equipment ?? "")|\(modalityFilter?.rawValue ?? "")|\(excludeYogaSession)|\(excludeYogaPoses)"
        let key = "\(filterKey)|\(normalizedSearch.lowercased())"
        return filteredMemo(key) {
            let base = filteredBase(filterKey: filterKey)
            guard !normalizedSearch.isEmpty else { return base }
            // Snapshot construction normalizes every name (diacritic fold +
            // char map) but is invariant to the query — build once per filter
            // state; each keystroke then only pays for `.search`.
            let snapshot = searchSnapshotMemo(filterKey) {
                ExerciseLibrarySnapshot(
                    exercises: base.map(\.domainInfo),
                    aliases: GlobalExerciseLibrary.snapshot.aliases
                )
            }
            let rankedIDs = snapshot.search(normalizedSearch, limit: base.count).map(\.exercise.id)
            let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return rankedIDs.compactMap { byID[$0] }
        }
    }

    private func filteredBase(filterKey: String) -> [ExerciseLibraryModel] {
        filteredBaseMemo(filterKey) {
            // Dedupe by id while filtering: CloudKit can't enforce unique
            // constraints, and duplicate IDs in a ForEach corrupt LazyVStack
            // layout (rows collapse to zero height / spacing goes erratic).
            var seen = Set<UUID>()
            return exercises.filter { ex in
                guard ex.deletedAt == nil, seen.insert(ex.id).inserted else { return false }
                if excludeYogaSession, YogaPoseCatalog.isSessionExercise(ex) { return false }
                if excludeYogaPoses, ex.isYoga, !YogaPoseCatalog.isSessionExercise(ex) { return false }
                if let modalityFilter, ex.modality != modalityFilter { return false }
                // Parent-aware: a "Shoulders" filter also finds exercises
                // tagged with a sub-muscle like "rear delts" (and legacy
                // variants like "rear_delts").
                if let muscle,
                   !ex.primaryMuscles.contains(where: { MuscleTaxonomy.matches($0, group: muscle) }),
                   !ex.secondaryMuscles.contains(where: { MuscleTaxonomy.matches($0, group: muscle) }) { return false }
                if let equipment, ex.equipment != equipment { return false }
                return true
            }
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
                if excludeYogaPoses, ex.isYoga, !YogaPoseCatalog.isSessionExercise(ex) { return nil }
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
                    .transition(Motion.riseIn(reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.entrance, value: selected.isEmpty)
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
                    initialName: search.trimmingCharacters(in: .whitespacesAndNewlines),
                    initialModality: modalityFilter ?? .strength
                ) { created in commit([created]) }
            }
            .sheet(item: $detailExercise) { exercise in
                NavigationStack {
                    ExerciseDetailView(exerciseID: exercise.id, workouts: history, exercises: exercises)
                }
            }
            .onAppear {
                if let presetModality, modalityFilter == nil {
                    modalityFilter = presetModality
                }
            }
        }
    }

    private var modalityFilterTitle: String {
        switch modalityFilter {
        case .strength: "Lifts"
        case .cardio: "Cardio"
        case .yoga: "Yoga"
        case nil: "Type"
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Menu {
                        Button("All types") { modalityFilter = nil }
                        Button("Lifts") { modalityFilter = .strength }
                        Button("Cardio") { modalityFilter = .cardio }
                        Button("Yoga") { modalityFilter = .yoga }
                    } label: {
                        FilterChip(
                            title: modalityFilterTitle,
                            active: modalityFilter != nil,
                            systemImage: "square.grid.2x2"
                        )
                    }
                    Menu {
                        Button("All muscles") { muscle = nil }
                        ForEach(ExerciseCatalog.muscleHierarchy, id: \.group) { entry in
                            if entry.children.isEmpty {
                                Button(MuscleTaxonomy.displayName(entry.group)) { muscle = entry.group }
                            } else {
                                Menu(MuscleTaxonomy.displayName(entry.group)) {
                                    Button("All \(MuscleTaxonomy.displayName(entry.group))") { muscle = entry.group }
                                    Divider()
                                    ForEach(entry.children, id: \.self) { child in
                                        Button(MuscleTaxonomy.displayName(child)) { muscle = child }
                                    }
                                }
                            }
                        }
                    } label: {
                        FilterChip(title: muscle.map(MuscleTaxonomy.displayName) ?? "Muscle", active: muscle != nil, systemImage: "figure.arms.open")
                    }
                    Menu {
                        Button("All equipment") { equipment = nil }
                        ForEach(ExerciseCatalog.equipmentTypes, id: \.self) { e in
                            Button(e.capitalized) { equipment = e }
                        }
                    } label: {
                        FilterChip(title: equipment?.capitalized ?? "Equipment", active: equipment != nil, systemImage: "dumbbell")
                    }
                    if muscle != nil || equipment != nil || modalityFilter != nil {
                        Button {
                            muscle = nil; equipment = nil; modalityFilter = nil
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
        // The library can hold duplicate rows for one exercise id (CloudKit
        // sync / re-seed races — same condition the display list dedupes
        // for). The "Add N" path filters the raw @Query array by selected
        // ids, so without this guard one tap adds the exercise twice.
        var seen = Set<UUID>()
        onAdd(list.filter { seen.insert($0.id).inserted })
        dismiss()
    }
}

private struct ExerciseRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            Text(exercise.resolvedCardioKind.metricLabels.prefix(4).joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(theme.secondaryAccent).lineLimit(1)
                        } else if exercise.isYoga {
                            Text(yogaSubtitle)
                                .font(.system(size: 12)).foregroundStyle(theme.secondaryAccent).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: reduceMotion ? false : selected)
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
            .accessibilityLabel("Exercise details for \(exercise.name)")
            .accessibilityIdentifier("exercise-info-\(exercise.name)")
        }
        .padding(Space.md)
        .background(selected ? theme.accentSoft : theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .animation(Motion.tap, value: selected)
    }

    /// "Sanskrit name · hold 30s" — Sanskrit from the bundled catalog, so
    /// custom poses just show the hold.
    private var yogaSubtitle: String {
        var parts: [String] = []
        if let sanskrit = YogaPoseCatalog.pose(forSlug: YogaPoseCatalog.slug(for: exercise))?.sanskrit {
            parts.append(sanskrit)
        }
        if let hold = exercise.defaultHoldSeconds {
            parts.append("Hold \(hold)s")
        }
        return parts.isEmpty ? "Yoga" : parts.joined(separator: " · ")
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
        .animation(Motion.tap, value: active)
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
    /// nil = no override — the exercise follows the app-wide unit.
    @State private var preferredUnit: WeightUnit?
    @State private var modality: Modality = .strength
    @State private var isUnilateral = false
    /// Explicit cardio modality; nil = auto-detect from name/equipment. Only
    /// meaningful while the Cardio mode is selected.
    @State private var cardioKindChoice: CardioKind?
    /// Yoga-only fields: optional Sanskrit name (saved as a searchable alias)
    /// and the default hold the flow builder starts from.
    @State private var sanskritName = ""
    @State private var defaultHoldSeconds = 30

    private var isCardio: Bool { modality == .cardio }

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

    init(
        editing: ExerciseLibraryModel? = nil,
        initialName: String = "",
        initialModality: Modality = .strength,
        onCreate: @escaping (ExerciseLibraryModel) -> Void
    ) {
        self.editing = editing
        self.onCreate = onCreate
        self.cameFromSearch = !initialName.isEmpty
        if editing == nil, !initialName.isEmpty {
            _name = State(initialValue: initialName)
        }
        if editing == nil, initialModality != .strength {
            _modality = State(initialValue: initialModality)
            _equipment = State(initialValue: ExerciseCatalog.primaryEquipment(modality: initialModality).first ?? "body only")
            if initialModality == .yoga {
                _primaryMuscle = State(initialValue: "hips")
            }
        }
        if let editing {
            _name = State(initialValue: editing.name)
            _primaryMuscle = State(initialValue: editing.primaryMuscles.first ?? "chest")
            _secondaryMuscles = State(initialValue: Set(editing.secondaryMuscles))
            _equipment = State(initialValue: editing.equipment ?? "barbell")
            _weightMode = State(initialValue: editing.defaultWeightMode)
            _preferredUnit = State(initialValue: WeightUnit(rawValue: editing.preferredWeightUnitRaw ?? ""))
            _modality = State(initialValue: editing.modality)
            _isUnilateral = State(initialValue: editing.isUnilateral)
            _cardioKindChoice = State(initialValue: editing.cardioKindRaw.flatMap(CardioKind.init(rawValue:)))
            _defaultHoldSeconds = State(initialValue: editing.defaultHoldSeconds ?? 30)
        }
    }

    /// The modality the cardio form previews and saves: explicit choice or
    /// live inference from what's typed so far.
    private var resolvedKind: CardioKind {
        cardioKindChoice ?? CardioKind.infer(
            name: name.trimmingCharacters(in: .whitespaces),
            equipment: equipment)
    }

    /// "30s" / "1min 30s" / "2min" — precise (never drops a remainder, so the
    /// 60s and 90s menu options stay distinguishable).
    private static func holdLabel(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m > 0 && s > 0 { return "\(m)min \(s)s" }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    // Modality first: creating a lift, a cardio exercise, and
                    // a yoga pose are different forms, not a metadata toggle.
                    Picker("Exercise type", selection: $modality) {
                        Text("Lift").tag(Modality.strength)
                        Text("Cardio").tag(Modality.cardio)
                        Text("Yoga").tag(Modality.yoga)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("exercise-modality")

                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            FieldLabel("Name")
                            DarkTextField(text: $name, placeholder: "e.g. Atlantis Leg Press")
                                // Auto-capitalize each word so "atlantis leg press"
                                // becomes "Atlantis Leg Press" as the user types —
                                // exercise names are title-cased. Propagates through
                                // the environment into DarkTextField's inner TextField.
                                .textInputAutocapitalization(.words)
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

                    switch modality {
                    case .cardio:
                        cardioFieldsCard
                    case .yoga:
                        yogaFieldsCard
                    case .strength:
                        liftFieldsCard
                    }
                }
                .padding(Space.lg)
                .animation(.spring(duration: 0.25), value: modality)
            }
            // Long form, several text fields (name, Sanskrit name) — without
            // these two, the last field/row of the modality-specific card
            // (e.g. "Weight unit" or "Sanskrit name") could be left stranded
            // behind the keyboard with no way to scroll to it. Same shared
            // fix as ScreenScaffold/RoutineEditorView.
            .scrollDismissesKeyboard(.interactively)
            .keyboardAdaptiveBottomInset()
            // Keep the equipment pick coherent with the type: snap to the new
            // discipline's default only when the current value belongs to the
            // OTHER discipline's primary set, so a deliberate edge-case pick
            // (kettlebell cardio, treadmill "lift") is left untouched.
            .onChange(of: modality) { was, now in
                let primary = ExerciseCatalog.primaryEquipment(modality: now)
                if !primary.contains(equipment) {
                    equipment = primary.first ?? equipment
                }
                // Landing on the yoga form with the lift default still in
                // place: start from a stretch-shaped region instead of chest.
                if now == .yoga, primaryMuscle == "chest" { primaryMuscle = "hips" }
                if was == .yoga, now == .strength, primaryMuscle == "hips" { primaryMuscle = "chest" }
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Exercise" : "New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            // Editing a pose: prefill the Sanskrit field from its alias once.
            .task {
                guard let editing, editing.isYoga, sanskritName.isEmpty else { return }
                let exerciseID = editing.id
                let aliases = (try? modelContext.fetch(
                    FetchDescriptor<ExerciseAliasModel>(predicate: #Predicate { $0.exerciseID == exerciseID })
                )) ?? []
                // Prefer the user's own alias over the seeded catalog one.
                if let alias = aliases.first(where: { $0.ownerID != nil }) ?? aliases.first,
                   sanskritName.isEmpty {
                    sanskritName = alias.alias
                }
            }
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

    /// Strength-training fields: muscles, equipment, loading, laterality.
    private var liftFieldsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                musclePickerRow("Primary muscle", selection: $primaryMuscle)
                Divider().overlay(theme.separator)
                secondaryMuscleRow
                Divider().overlay(theme.separator)
                pickerRow("Equipment", selection: $equipment, options: ExerciseCatalog.equipmentOptions(isCardio: false))
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
                Divider().overlay(theme.separator)
                HStack {
                    Text("Weight unit").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("Weight unit", selection: $preferredUnit) {
                        Text("Auto").tag(WeightUnit?.none)
                        Text("lb").tag(WeightUnit?.some(.lb))
                        Text("kg").tag(WeightUnit?.some(.kg))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
            }
        }
    }

    /// Cardio fields: modality (explicit or auto-detected), equipment, and a
    /// read-out of the muscle classification — Cardiovascular is the default
    /// primary, with the modality's movers alongside.
    private var cardioFieldsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    Text("Cardio type").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Menu {
                        Button("Auto-detect") { cardioKindChoice = nil }
                        Divider()
                        ForEach(CardioKind.allCases, id: \.self) { kind in
                            Button {
                                cardioKindChoice = kind
                            } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: resolvedKind.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                            Text(cardioKindChoice == nil ? "Auto · \(resolvedKind.title)" : resolvedKind.title)
                                .font(.bodyStrong)
                        }
                        .foregroundStyle(theme.secondaryAccent)
                    }
                    .accessibilityIdentifier("cardio-type-picker")
                }
                Text("Auto-detect reads the name and equipment — \"Treadmill Run\" tracks pace, \"Row Erg\" tracks 500m splits.")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(theme.separator)
                pickerRow("Equipment", selection: $equipment, options: ExerciseCatalog.equipmentOptions(isCardio: true))
                Divider().overlay(theme.separator)
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Works").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    MuscleChips(muscles: resolvedKind.musclesWorked)
                    Text("Cardio counts toward Cardiovascular volume, plus the movement's main muscles.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Yoga pose fields: stretch-target regions, hold default, laterality,
    /// props, and an optional Sanskrit name saved as a searchable alias.
    private var yogaFieldsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                musclePickerRow("Primary region", selection: $primaryMuscle)
                Divider().overlay(theme.separator)
                secondaryMuscleRow
                Divider().overlay(theme.separator)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default hold").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("The hold length this pose starts with in a flow.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Menu {
                        ForEach([15, 20, 30, 45, 60, 90, 120, 180], id: \.self) { seconds in
                            Button(Self.holdLabel(seconds)) { defaultHoldSeconds = seconds }
                        }
                    } label: {
                        Text(Self.holdLabel(defaultHoldSeconds))
                            .font(.bodyStrong).foregroundStyle(theme.accent)
                    }
                    .accessibilityIdentifier("yoga-default-hold")
                }
                Divider().overlay(theme.separator)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sides").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("One-sided poses (Pigeon, Warrior) run left then right in a guided flow.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Menu {
                        Button("Both sides at once") { isUnilateral = false }
                        Button("One side at a time") { isUnilateral = true }
                    } label: {
                        Text(isUnilateral ? "One at a time" : "Both at once")
                            .font(.bodyStrong).foregroundStyle(theme.accent)
                    }
                }
                Divider().overlay(theme.separator)
                pickerRow("Props", selection: $equipment, options: ExerciseCatalog.equipmentOptions(modality: .yoga))
                Divider().overlay(theme.separator)
                VStack(alignment: .leading, spacing: Space.sm) {
                    FieldLabel("Sanskrit name (optional)")
                    DarkTextField(text: $sanskritName, placeholder: "e.g. Balasana")
                        // Sanskrit transliterations are title-cased too
                        // ("Adho Mukha Svanasana"), so match the name field.
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("yoga-sanskrit-name")
                    Text("Searchable alongside the English name.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    /// Multi-select secondary muscles — each counts as half a set toward that
    /// muscle's weekly volume.
    /// Same drill-down menu as the primary picker, but multi-select: taps
    /// toggle checkmarks without dismissing (menuActionDismissBehavior), and
    /// the user closes the menu by tapping anywhere else when done.
    private var secondaryMuscleRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("Secondary muscles").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Menu {
                    ForEach(ExerciseCatalog.muscleHierarchy, id: \.group) { entry in
                        if entry.children.isEmpty {
                            secondaryMuscleToggle(entry.group)
                        } else {
                            Menu(MuscleTaxonomy.displayName(entry.group)) {
                                secondaryMuscleToggle(entry.group, label: "All \(MuscleTaxonomy.displayName(entry.group))")
                                Divider()
                                ForEach(entry.children, id: \.self) { child in
                                    secondaryMuscleToggle(child)
                                }
                            }
                        }
                    }
                    if !secondaryMuscles.isEmpty {
                        Divider()
                        Button(role: .destructive) {
                            secondaryMuscles.removeAll()
                        } label: {
                            Label("Clear all", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Text(secondaryMuscles.isEmpty
                         ? "None"
                         : "\(secondaryMuscles.count) selected")
                        .font(.bodyStrong)
                        .foregroundStyle(secondaryMuscles.isEmpty ? theme.textTertiary : theme.accent)
                }
                .menuActionDismissBehavior(.disabled)
                .accessibilityIdentifier("secondary-muscle-picker")
            }
            if !secondaryMuscles.isEmpty {
                Text(secondaryMuscles.sorted().map(MuscleTaxonomy.displayName).joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Each secondary muscle counts as half a set toward weekly volume.")
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
    }

    /// One toggleable menu row; the primary muscle is excluded so an exercise
    /// can't count itself twice.
    @ViewBuilder
    private func secondaryMuscleToggle(_ muscle: String, label: String? = nil) -> some View {
        if MuscleTaxonomy.canonical(muscle) != MuscleTaxonomy.canonical(primaryMuscle) {
            Button {
                toggleSecondaryMuscle(muscle)
            } label: {
                if secondaryMuscles.contains(muscle) {
                    Label(label ?? MuscleTaxonomy.displayName(muscle), systemImage: "checkmark")
                } else {
                    Text(label ?? MuscleTaxonomy.displayName(muscle))
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

    /// Primary-muscle picker with drill-down: parent groups open a submenu of
    /// "All <Group>" plus their sub-muscles; standalone groups pick directly.
    private func musclePickerRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Spacer()
            Menu {
                ForEach(ExerciseCatalog.muscleHierarchy, id: \.group) { entry in
                    if entry.children.isEmpty {
                        Button(MuscleTaxonomy.displayName(entry.group)) { selection.wrappedValue = entry.group }
                    } else {
                        Menu(MuscleTaxonomy.displayName(entry.group)) {
                            Button("All \(MuscleTaxonomy.displayName(entry.group))") { selection.wrappedValue = entry.group }
                            Divider()
                            ForEach(entry.children, id: \.self) { child in
                                Button(MuscleTaxonomy.displayName(child)) { selection.wrappedValue = child }
                            }
                        }
                    }
                }
            } label: {
                Text(MuscleTaxonomy.displayName(selection.wrappedValue))
                    .font(.bodyStrong).foregroundStyle(theme.accent)
            }
            .accessibilityIdentifier("primary-muscle-picker")
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
            upsertSanskritAlias(for: editing)
            try? modelContext.save()
            onCreate(editing)
        } else {
            let exercise = ExerciseLibraryModel(ownerID: ForgeFitDemo.userID, name: name)
            apply(to: exercise)
            modelContext.insert(exercise)
            upsertSanskritAlias(for: exercise)
            try? modelContext.save()
            onCreate(exercise)
        }
        dismiss()
    }

    /// Write the current form state onto an exercise model. Shared by the create
    /// and edit paths so both stay in lockstep.
    private func apply(to exercise: ExerciseLibraryModel) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Every field branches on the selected modality, so values left over
        // from the other modes' hidden forms can never leak into the save.
        let kind = resolvedKind
        let isYoga = modality == .yoga
        exercise.name = trimmed
        exercise.modality = modality  // writes modalityRaw and keeps isCardio in sync
        exercise.movementPattern = isCardio ? "cardio" : (isYoga ? "yoga" : nil)
        exercise.primaryMuscles = isCardio ? kind.musclesWorked : [primaryMuscle]
        exercise.secondaryMuscles = isCardio ? [] : secondaryMuscles.subtracting([primaryMuscle]).sorted()
        exercise.equipment = equipment
        exercise.defaultWeightMode = isCardio || isYoga ? .bodyweight : weightMode
        exercise.preferredWeightUnitRaw = isCardio || isYoga ? nil : preferredUnit?.rawValue
        exercise.cardioKindRaw = isCardio ? cardioKindChoice?.rawValue : nil
        // Yoga keeps laterality (one-sided poses run L/R in guided flows).
        exercise.isUnilateral = isCardio ? false : isUnilateral
        exercise.defaultHoldSeconds = isYoga ? defaultHoldSeconds : nil
        switch modality {
        case .strength: exercise.category = "strength"
        case .cardio: exercise.category = "cardio"
        case .yoga: exercise.category = "yoga"
        }
    }

    /// Keep the pose's Sanskrit alias in step with the form: update the one we
    /// manage, create it when first filled in, remove it when cleared.
    private func upsertSanskritAlias(for exercise: ExerciseLibraryModel) {
        guard modality == .yoga || editing?.isYoga == true else { return }
        let trimmed = sanskritName.trimmingCharacters(in: .whitespaces)
        let exerciseID = exercise.id
        let existing = (try? modelContext.fetch(
            FetchDescriptor<ExerciseAliasModel>(predicate: #Predicate { $0.exerciseID == exerciseID })
        )) ?? []

        if modality == .yoga, !trimmed.isEmpty {
            // Seeded catalog aliases (ownerID nil) belong to the re-seed and
            // would be reverted next launch — user edits live on their own
            // user-owned alias row instead.
            if let owned = existing.first(where: { $0.ownerID != nil }) {
                if owned.alias != trimmed { owned.alias = trimmed }
            } else if !existing.contains(where: { $0.alias == trimmed }) {
                modelContext.insert(ExerciseAliasModel(
                    exerciseID: exerciseID,
                    ownerID: ForgeFitDemo.userID,
                    alias: trimmed
                ))
            }
        } else {
            // Cleared, or the pose was retyped to another modality: only drop
            // user-owned aliases; seeded (catalog) aliases are not ours to remove.
            for alias in existing where alias.ownerID != nil {
                modelContext.delete(alias)
            }
        }
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

#if DEBUG
#Preview("Create exercise — Lift") {
    CreateExerciseView { _ in }
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}

#Preview("Create exercise — Cardio") {
    CreateExerciseView(initialName: "Treadmill Run") { _ in }
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}
#endif
