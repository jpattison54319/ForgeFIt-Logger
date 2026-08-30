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
    /// General workout addition and conditioning movement selection keep all
    /// yoga choices out of the exercise catalog. Yoga is added as a block and
    /// poses are selected inside its dedicated flow builder.
    var excludeYoga = false
    /// Adds first-class block actions above the strength/cardio catalog.
    var showsWorkoutBlocks = false
    /// Exercises already in the routine/workout being added to — drives the
    /// muscle profile behind "Suggested".
    var context: [ExerciseLibraryModel] = []
    /// Completed workouts, for ranking by the user's most-used exercises.
    var history: [WorkoutModel] = []
    /// Exact value-only usage projection for callers that deliberately avoid
    /// retaining a full workout graph (notably the live logger). Legacy callers
    /// may continue to supply `history`; this snapshot wins when present.
    var historySnapshot: ExercisePickerHistorySnapshot? = nil
    /// Lets replacement reuse the familiar picker without presenting itself
    /// as an add flow.
    var navigationTitle = "Add Exercise"
    /// Current/in-use exercises that replacement must never offer.
    var excludedIDs: Set<UUID> = []
    /// When present, this picker is the full-search continuation of a swap.
    /// Suggested rows use the target's replacement ranking rather than the
    /// generic add-exercise recommendation policy.
    var replacementTarget: ExerciseLibraryModel? = nil
    /// Strict equipment filter selected on the quick replacement sheet.
    var presetReplacementEquipmentFilter: ExerciseSwapSuggester.EquipmentFilter? = nil
    var onAddConditioningBlock: ((String) -> Void)?
    var onAddYogaBlock: ((String) -> Void)?
    let onAdd: ([ExerciseLibraryModel]) -> Void

    @State private var search = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var modalityFilter: Modality?
    @State private var replacementEquipmentFilter: ExerciseSwapSuggester.EquipmentFilter?
    @State private var selected: Set<UUID> = []
    /// Exercises created while a selection was in flight — a fallback for
    /// resolving them before the `@Query` republishes. See `selectedExercises`.
    @State private var createdDuringSelection: [ExerciseLibraryModel] = []
    /// Set to a just-created exercise so the list scrolls it into view.
    /// Cleared as soon as the scroll is issued.
    @State private var scrollTarget: UUID?
    @State private var showCreate = false
    @State private var showConditioningBuilder = false
    @State private var showYogaBuilder = false
    @State private var detailExercise: ExerciseLibraryModel?
    @State private var filteredMemo = Memo<String, [ExerciseLibraryModel]>()
    @State private var suggestedMemo = Memo<String, [ExerciseLibraryModel]>()
    /// Keyed by filter state only (NOT the query): the filtered base list and
    /// its search snapshot are invariant per keystroke, and the snapshot init
    /// re-normalizes every library name — rebuilding both on each keystroke
    /// made typing lag scale with library size.
    @State private var filteredBaseMemo = Memo<String, [ExerciseLibraryModel]>()
    @State private var searchSnapshotMemo = Memo<String, ExerciseLibrarySnapshot>()
    @State private var appliedInitialFilters = false
    /// Drives the keyboard accessory. The search field lives in the navigation
    /// bar drawer, so its dismiss control has to be app-owned — the same
    /// affordance the live logger gives every set field.
    @State private var keyboardVisible = false

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
        if let historySnapshot { return historySnapshot.fingerprint }
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

    private var exclusionFingerprint: String {
        excludedIDs.map(\.uuidString).sorted().joined(separator: "|")
    }

    private var replacementFingerprint: String {
        guard let replacementTarget else { return "" }
        return "\(replacementTarget.id.uuidString):\(replacementTarget.updatedAt.timeIntervalSince1970)"
    }

    private var filterKey: String {
        "\(exerciseFingerprint)|\(muscle ?? "")|\(equipment ?? "")|\(modalityFilter?.rawValue ?? "")|\(replacementFilterIdentifier)|\(excludeYogaSession)|\(excludeYogaPoses)|\(excludeYoga)|\(exclusionFingerprint)"
    }

    private var replacementFilterIdentifier: String {
        switch replacementEquipmentFilter {
        case nil: ""
        case .freeWeights: "free-weights"
        case .machineOrCable: "machine-or-cable"
        case .bodyweight: "bodyweight"
        }
    }

    private var filtered: [ExerciseLibraryModel] {
        let normalizedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
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
                guard ex.deletedAt == nil, !excludedIDs.contains(ex.id), seen.insert(ex.id).inserted else { return false }
                if excludeYoga, ex.isYoga { return false }
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
                if let replacementEquipmentFilter,
                   !ExerciseSwapSuggester.matches(
                    replacementEquipmentFilter,
                    candidate: swapCandidate(for: ex)
                   ) { return false }
                return true
            }
        }
    }

    /// Smart suggestions: score every exercise against (a) the muscle profile
    /// of what's already in the routine/workout — primaries loudest, secondary
    /// overlap (e.g. chest → push) quieter — and (b) how often the user has
    /// actually logged it. Renders nothing when there's no signal.
    private var suggested: [ExerciseLibraryModel] {
        guard search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let key = "\(filterKey)|\(historyFingerprint)|\(contextFingerprint)|\(replacementFingerprint)"
        return suggestedMemo(key) {
            let base = filteredBase(filterKey: filterKey)

            if let replacementTarget {
                let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return ExerciseSwapSuggester.suggest(
                    replacing: swapCandidate(for: replacementTarget),
                    from: base.map(swapCandidate(for:)),
                    excluding: excludedIDs,
                    equipmentFilter: replacementEquipmentFilter,
                    usageByID: historySnapshot?.swapUsageProfiles
                        ?? ExerciseSwapUsageBuilder.profiles(from: history)
                ).compactMap { byID[$0.candidate.id] }
            }

            let usage: [UUID: Int]
            if let historySnapshot {
                usage = historySnapshot.occurrenceCountByExerciseID
            } else {
                var derived: [UUID: Int] = [:]
                for workout in history where workout.endedAt != nil && workout.deletedAt == nil {
                    for we in workout.exercises { derived[we.exerciseID, default: 0] += 1 }
                }
                usage = derived
            }
            var muscleScore: [String: Double] = [:]
            for ex in context {
                for m in ex.primaryMuscles { muscleScore[m, default: 0] += 2 }
                for m in ex.secondaryMuscles { muscleScore[m, default: 0] += 1 }
            }
            guard !muscleScore.isEmpty || !usage.isEmpty else { return [] }

            let alreadyIn = Set(context.map(\.id))
            var seen = Set<UUID>()
            let scored: [(ExerciseLibraryModel, Double)] = base.compactMap { ex in
                guard !alreadyIn.contains(ex.id), seen.insert(ex.id).inserted else { return nil }
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
                    if showsWorkoutBlocks {
                        WorkoutBlockPickerSection(
                            onAddConditioning: { showConditioningBuilder = true },
                            onAddYoga: { showYogaBuilder = true }
                        )
                        Divider().overlay(theme.separator)
                    }
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
                        commit(selectedExercises)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                    .transition(Motion.riseIn(reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.entrance, value: selected.isEmpty)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .onKeyboardVisibilityChange($keyboardVisible)
            // The search field sits in the navigation bar drawer, where the
            // system supplies no return key that closes the keyboard. This is
            // the live logger's accessory, in the same place, for the same
            // reason.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardVisible {
                    KeyboardAccessoryBar {
                        CircleIconButton(
                            systemImage: "keyboard.chevron.compact.down",
                            label: "Dismiss keyboard",
                            action: hideKeyboard
                        )
                        .accessibilityIdentifier("exercise-search-dismiss-keyboard")
                        Spacer()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create exercise")
                        .accessibilityIdentifier("create-exercise-button")
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateExerciseView(
                    initialName: search.trimmingCharacters(in: .whitespacesAndNewlines),
                    initialModality: modalityFilter ?? .strength
                ) { created in absorbCreated(created) }
            }
            .sheet(isPresented: $showConditioningBuilder) {
                ConditioningBlockBuilderView(
                    planJSON: nil,
                    exercises: exercises,
                    workouts: history,
                    historySnapshot: historySnapshot,
                    onSave: { json in
                        onAddConditioningBlock?(json)
                        dismiss()
                    }
                )
            }
            .sheet(isPresented: $showYogaBuilder) {
                YogaFlowBuilderView(planJSON: nil, onSave: { json in
                    guard let json else { return }
                    onAddYogaBlock?(json)
                    dismiss()
                })
            }
            .fullScreenCover(item: $detailExercise) { exercise in
                NavigationStack {
                    ExercisePickerHistoryDetailDestination(
                        exercise: exercise,
                        exercises: exercises,
                        seedHistory: history,
                        loadsPersistedHistory: historySnapshot != nil
                    )
                }
            }
            .onAppear {
                guard !appliedInitialFilters else { return }
                if let presetModality {
                    modalityFilter = presetModality
                }
                replacementEquipmentFilter = presetReplacementEquipmentFilter
                appliedInitialFilters = true
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
                        if !excludeYoga { Button("Yoga") { modalityFilter = .yoga } }
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
                                    if entry.allowsGroupSelection {
                                        Button("All \(MuscleTaxonomy.displayName(entry.group))") { muscle = entry.group }
                                        Divider()
                                    }
                                    ForEach(entry.children, id: \.self) { child in
                                        Button(MuscleTaxonomy.displayName(child)) { muscle = child }
                                    }
                                }
                            }
                        }
                    } label: {
                        FilterChip(title: muscle.map(MuscleTaxonomy.displayName) ?? "Muscle", active: muscle != nil, systemImage: "figure.arms.open")
                    }
                    if replacementTarget != nil {
                        Menu {
                            Button("All equipment") { replacementEquipmentFilter = nil }
                            ForEach(ExerciseSwapSuggester.EquipmentFilter.allCases, id: \.self) { filter in
                                Button(replacementEquipmentFilterTitle(filter)) {
                                    replacementEquipmentFilter = filter
                                }
                            }
                        } label: {
                            FilterChip(
                                title: replacementEquipmentFilter.map(replacementEquipmentFilterTitle) ?? "Equipment",
                                active: replacementEquipmentFilter != nil,
                                systemImage: "dumbbell"
                            )
                        }
                        .accessibilityIdentifier("replacement-search-equipment-filter")
                    } else {
                        Menu {
                            Button("All equipment") { equipment = nil }
                            ForEach(ExerciseCatalog.equipmentTypes, id: \.self) { e in
                                Button(e.capitalized) { equipment = e }
                            }
                        } label: {
                            FilterChip(
                                title: equipment?.capitalized ?? "Equipment",
                                active: equipment != nil,
                                systemImage: "dumbbell"
                            )
                        }
                    }
                    if muscle != nil || equipment != nil || replacementEquipmentFilter != nil || modalityFilter != nil {
                        Button {
                            muscle = nil
                            equipment = nil
                            replacementEquipmentFilter = nil
                            modalityFilter = nil
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

    private func replacementEquipmentFilterTitle(
        _ filter: ExerciseSwapSuggester.EquipmentFilter
    ) -> String {
        switch filter {
        case .freeWeights: "Free weights"
        case .machineOrCable: "Machine or cable"
        case .bodyweight: "Bodyweight"
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: Space.sm) {
                    let picks = suggested
                    if !picks.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.tag)
                            Text("Suggested").font(.system(size: 13, weight: .bold))
                            Spacer()
                        }
                        .foregroundStyle(theme.accentForeground)
                        .padding(.horizontal, Space.lg)

                        ForEach(picks) { exercise in
                            Group {
                                if replacementTarget != nil {
                                    ReplacementExerciseRow(
                                        exercise: exercise,
                                        onShowDetails: { detailExercise = exercise },
                                        onSwap: { commit([exercise]) }
                                    )
                                } else {
                                    ExerciseRowLabel(
                                        exercise: exercise,
                                        selected: selected.contains(exercise.id),
                                        onSelect: { toggle(exercise) },
                                        onInfo: { detailExercise = exercise }
                                    )
                                }
                            }
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
                        Group {
                            if replacementTarget != nil {
                                ReplacementExerciseRow(
                                    exercise: exercise,
                                    onShowDetails: { detailExercise = exercise },
                                    onSwap: { commit([exercise]) }
                                )
                            } else {
                                ExerciseRowLabel(
                                    exercise: exercise,
                                    selected: selected.contains(exercise.id),
                                    onSelect: { toggle(exercise) },
                                    onInfo: { detailExercise = exercise }
                                )
                            }
                        }
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
            // A just-created exercise joins the selection immediately, so
            // bring it on screen — in a name-sorted catalog this size it
            // would otherwise be counted in "Add N" from somewhere the
            // user can't see.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
            // Reading the results is the point of typing; the keyboard covers
            // most of them. Any drag on the list puts it away.
            .scrollDismissesKeyboard(.immediately)
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
            .foregroundStyle(theme.accentForeground)
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

    private func swapCandidate(
        for exercise: ExerciseLibraryModel
    ) -> ExerciseSwapSuggester.Candidate {
        .init(
            id: exercise.id,
            name: exercise.name,
            movementPattern: exercise.movementPattern,
            primaryMuscles: exercise.primaryMuscles,
            secondaryMuscles: exercise.secondaryMuscles,
            equipment: exercise.equipment,
            weightMode: exercise.defaultWeightMode,
            mechanic: exercise.mechanic,
            force: exercise.force
        )
    }

    /// Exercises behind the "Add N" button, in the library's display order.
    ///
    /// Selection is tracked by id and resolved against the raw `@Query`, so an
    /// exercise created while a selection is in flight can be selected a beat
    /// before the query republishes. Without the second pass it would be
    /// counted in "Add N" and then silently dropped from what's added.
    private var selectedExercises: [ExerciseLibraryModel] {
        var list = exercises.filter { selected.contains($0.id) }
        let present = Set(list.map(\.id))
        list += createdDuringSelection.filter {
            selected.contains($0.id) && !present.contains($0.id)
        }
        return list
    }

    /// Creating an exercise must never discard a selection already in flight.
    /// With nothing selected, "create" is a one-shot add and still commits
    /// straight through to the caller. With a selection in flight the new
    /// exercise joins it and the picker stays open, so the whole set goes in
    /// as one bulk add.
    private func absorbCreated(_ created: ExerciseLibraryModel) {
        guard !selected.isEmpty else { commit([created]); return }
        reveal(created)
        createdDuringSelection.append(created)
        selected.insert(created.id)
        scrollTarget = created.id
    }

    /// Keeps the promise the selection count makes. The new exercise is
    /// counted in "Add N" immediately, so relax exactly the narrowing state
    /// that would hide it from the list — and nothing else. Constraints the
    /// caller imposed (preset modality, exclusions) are never touched.
    private func reveal(_ created: ExerciseLibraryModel) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // `contains` is the search scorer's strongest match, so a name that
        // contains the query is guaranteed to rank; anything else is cleared
        // rather than guessed at.
        if !query.isEmpty, !created.name.lowercased().contains(query.lowercased()) {
            search = ""
        }
        if let muscle,
           !created.primaryMuscles.contains(where: { MuscleTaxonomy.matches($0, group: muscle) }),
           !created.secondaryMuscles.contains(where: { MuscleTaxonomy.matches($0, group: muscle) }) {
            self.muscle = nil
        }
        if let equipment, created.equipment != equipment {
            self.equipment = nil
        }
        if presetModality == nil, let modalityFilter, created.modality != modalityFilter {
            self.modalityFilter = nil
        }
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

/// Exact per-exercise drill-in for picker/swap callers that carry only the
/// immutable usage projection. The expensive all-history relationship scan
/// runs in `LiveWorkoutHistoryWorker`; MainActor fetches only the workout IDs
/// that can contribute to this exercise's charts, records, and history rows.
struct ExercisePickerHistoryDetailDestination: View {
    @Environment(\.modelContext) private var modelContext

    let exercise: ExerciseLibraryModel
    let exercises: [ExerciseLibraryModel]
    var seedHistory: [WorkoutModel] = []
    var loadsPersistedHistory = false

    @State private var loadedHistory: [WorkoutModel] = []

    static func completedHistoryDescriptor(
        for workoutIDs: [UUID]
    ) -> FetchDescriptor<WorkoutModel> {
        FetchDescriptor<WorkoutModel>(
            predicate: #Predicate {
                workoutIDs.contains($0.id)
                    && $0.endedAt != nil
                    && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    private var resolvedHistory: [WorkoutModel] {
        var byID = Dictionary(
            seedHistory.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for workout in loadedHistory where byID[workout.id] == nil {
            byID[workout.id] = workout
        }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        ExerciseDetailView(
            exerciseID: exercise.id,
            workouts: resolvedHistory,
            exercises: exercises
        )
        .task(id: exercise.id) {
            guard loadsPersistedHistory else { return }
            let worker = LiveWorkoutHistoryWorker(modelContainer: modelContext.container)
            guard let ids = try? await worker.completedWorkoutIDs(containing: exercise.id),
                  !Task.isCancelled else { return }
            guard !ids.isEmpty else {
                loadedHistory = []
                return
            }
            var rows: [WorkoutModel] = []
            let batchSize = 160
            for start in stride(from: 0, to: ids.count, by: batchSize) {
                let end = min(start + batchSize, ids.count)
                let batchIDs = Array(ids[start..<end])
                rows.append(contentsOf: (try? modelContext.fetch(
                    Self.completedHistoryDescriptor(for: batchIDs)
                )) ?? [])
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            loadedHistory = rows.sorted { $0.startedAt > $1.startedAt }
        }
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
        Group {
            if exercise.isYoga {
                HStack(spacing: Space.md) {
                    ExerciseThumbnail(exercise: exercise)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Button(action: onInfo) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(exercise.name)
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.accentForeground)
                                }
                                .minimumTouchTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Exercise details for \(exercise.name)")
                            .accessibilityIdentifier("exercise-info-\(exercise.name)")

                            if exercise.ownerID != nil {
                                Tag(text: "Custom", color: theme.accent, background: theme.accentSoft)
                            }
                        }
                        Text([exercise.primaryMuscles.first?.capitalized, exercise.equipment?.capitalized]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer()

                    Button(action: onSelect) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: reduceMotion ? false : selected)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Deselect \(exercise.name)" : "Select \(exercise.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("exercise-row-\(exercise.name)")
                }
            } else {
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
                                        .font(.system(size: 12)).foregroundStyle(theme.secondaryAccentForeground).lineLimit(1)
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
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.accentForeground)
                            .frame(width: 44, height: 44)   // HIG minimum touch target
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exercise details for \(exercise.name)")
                    .accessibilityIdentifier("exercise-info-\(exercise.name)")
                }
            }
        }
        .padding(Space.md)
        .background(selected ? theme.accentSoft : theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .animation(Motion.tap, value: selected)
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
        .minimumTouchTarget()
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
    /// The identity photos are filed under. Fixed up front so a photo picked
    /// before the first save still belongs to the exercise this form creates.
    @State private var mediaID = UUID()
    @State private var photoDrafts = ExercisePhotoSet.empty
    @State private var notesDraft = ""
    @State private var mediaSaveFailed = false
    /// Set once the exercise row itself is durably saved. A retry after a
    /// media failure must re-apply the photos, never insert the exercise a
    /// second time — CloudKit cannot enforce unique ids, so a duplicate row
    /// would be permanent.
    @State private var exerciseIsCommitted = false

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
                _primaryMuscle = State(initialValue: "hip flexors")
            }
        }
        if let editing {
            _mediaID = State(initialValue: editing.id)
            _photoDrafts = State(initialValue: CustomExerciseMedia.shared.photoSet(for: editing.id))
            _notesDraft = State(initialValue: CustomExerciseMedia.shared.notes(for: editing.id) ?? "")
            _name = State(initialValue: editing.name)
            let initialPrimary = editing.primaryMuscles.first ?? "chest"
            _primaryMuscle = State(initialValue: initialPrimary)
            _secondaryMuscles = State(initialValue: Set(
                ExerciseMuscleSelectionPolicy.secondaryMuscles(
                    from: editing.secondaryMuscles,
                    excluding: initialPrimary
                )
            ))
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
                    .frame(minHeight: TouchTarget.minimum)
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
                                                        .foregroundStyle(theme.accentForeground)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(theme.accentForeground)
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

                    ExerciseMediaEditorCard(photos: $photoDrafts, notes: $notesDraft)

                    if mediaSaveFailed {
                        Text("The exercise is saved. Its photos and description could not be written to this device — Save again to retry just those.")
                            .font(.footnote.bold())
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("exercise-media-save-error")
                    }
                }
                .padding(Space.lg)
                // Apply keyboard clearance to the scroll content. Putting the
                // same padding on the outer ScrollView double-counts SwiftUI's
                // sheet avoidance and collapses the form into a black gap.
                .keyboardAdaptiveBottomInset()
                .animation(.spring(duration: 0.25), value: modality)
            }
            // Let the keyboard be dismissed by dragging this long form; the
            // content-level inset above keeps its final rows reachable.
            .scrollDismissesKeyboard(.interactively)
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
                if now == .yoga, primaryMuscle == "chest" { selectPrimaryMuscle("hip flexors") }
                if was == .yoga, now == .strength, primaryMuscle == "hip flexors" { selectPrimaryMuscle("chest") }
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    /// Strength-training fields: muscles, equipment, loading, laterality.
    private var liftFieldsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                musclePickerRow("Primary muscle")
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
                            .font(.bodyStrong).foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
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
                            .font(.bodyStrong).foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
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
                    .frame(minHeight: TouchTarget.minimum)
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
                        .foregroundStyle(theme.secondaryAccentForeground)
                        .minimumTouchTarget()
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
                musclePickerRow("Primary region")
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
                            .font(.bodyStrong).foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
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
                            .font(.bodyStrong).foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
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
                    ForEach(ExerciseCatalog.selectableMuscleHierarchy, id: \.group) { entry in
                        if entry.children.isEmpty {
                            secondaryMuscleToggle(entry.group)
                        } else {
                            Menu(MuscleTaxonomy.displayName(entry.group)) {
                                if entry.allowsGroupSelection {
                                    secondaryMuscleToggle(entry.group, label: "All \(MuscleTaxonomy.displayName(entry.group))")
                                    Divider()
                                }
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
                        .minimumTouchTarget()
                }
                .menuActionDismissBehavior(.disabled)
                .accessibilityIdentifier("secondary-muscle-picker")
                .accessibilityLabel("Secondary muscles")
                .accessibilityValue(secondaryMuscles.isEmpty
                    ? "None"
                    : secondaryMuscles
                        .map(MuscleTaxonomy.displayName)
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                        .joined(separator: ", "))
            }
            if !secondaryMuscles.isEmpty {
                Text(secondaryMuscles
                    .map(MuscleTaxonomy.displayName)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .joined(separator: " · "))
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
        if !ExerciseMuscleSelectionPolicy.overlaps(muscle, primaryMuscle) {
            Button {
                toggleSecondaryMuscle(muscle)
            } label: {
                if secondaryMuscles.contains(MuscleTaxonomy.canonical(muscle)) {
                    Label(label ?? MuscleTaxonomy.displayName(muscle), systemImage: "checkmark")
                } else {
                    Text(label ?? MuscleTaxonomy.displayName(muscle))
                }
            }
        }
    }

    private func toggleSecondaryMuscle(_ muscle: String) {
        let canonical = MuscleTaxonomy.canonical(muscle)
        guard !ExerciseMuscleSelectionPolicy.overlaps(canonical, primaryMuscle) else { return }
        if secondaryMuscles.contains(canonical) {
            secondaryMuscles.remove(canonical)
        } else {
            secondaryMuscles.insert(canonical)
        }
    }

    private func selectPrimaryMuscle(_ muscle: String) {
        let canonical = MuscleTaxonomy.canonical(muscle)
        primaryMuscle = canonical
        secondaryMuscles = Set(ExerciseMuscleSelectionPolicy.secondaryMuscles(
            from: Array(secondaryMuscles),
            excluding: canonical
        ))
    }

    /// Primary-muscle picker with drill-down: parent groups open a submenu of
    /// "All <Group>" plus their sub-muscles; standalone groups pick directly.
    private func musclePickerRow(_ title: String) -> some View {
        HStack {
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Spacer()
            Menu {
                ForEach(ExerciseCatalog.selectableMuscleHierarchy, id: \.group) { entry in
                    if entry.children.isEmpty {
                        Button(MuscleTaxonomy.displayName(entry.group)) { selectPrimaryMuscle(entry.group) }
                    } else {
                        Menu(MuscleTaxonomy.displayName(entry.group)) {
                            if entry.allowsGroupSelection {
                                Button("All \(MuscleTaxonomy.displayName(entry.group))") { selectPrimaryMuscle(entry.group) }
                                Divider()
                            }
                            ForEach(entry.children, id: \.self) { child in
                                Button(MuscleTaxonomy.displayName(child)) { selectPrimaryMuscle(child) }
                            }
                        }
                    }
                }
            } label: {
                Text(MuscleTaxonomy.displayName(primaryMuscle))
                    .font(.bodyStrong).foregroundStyle(theme.accentForeground)
                    .minimumTouchTarget()
            }
            .accessibilityIdentifier("primary-muscle-picker")
            .accessibilityLabel(title)
            .accessibilityValue(MuscleTaxonomy.displayName(primaryMuscle))
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
                Text(selection.wrappedValue.capitalized)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.accentForeground)
                    .minimumTouchTarget()
            }
        }
    }

    private func save() {
        // A retry after a media failure has a durable exercise already. Redo
        // only the part that failed.
        if exerciseIsCommitted {
            isSaving = true
            if applyMedia() {
                dismiss()
            } else {
                isSaving = false
            }
            return
        }
        // Freeze and clear suggestions before the insert: the @Query update
        // would otherwise match the just-created exercise against its own name
        // and flash the "already exists" card while the sheet dismisses.
        isSaving = true
        duplicateCandidates = []
        let draftName = name.trimmingCharacters(in: .whitespaces)
        let draftModality = modality
        let draftIsCardio = modality == .cardio
        let draftIsYoga = modality == .yoga
        let draftKind = resolvedKind
        let draftPrimaryMuscle = primaryMuscle
        let draftSecondaryMuscles = ExerciseMuscleSelectionPolicy.secondaryMuscles(
            from: Array(secondaryMuscles),
            excluding: draftPrimaryMuscle
        ).sorted()
        let draftEquipment = equipment
        let draftWeightMode = weightMode
        let draftPreferredUnitRaw = preferredUnit?.rawValue
        let draftCardioKindRaw = cardioKindChoice?.rawValue
        let draftIsUnilateral = isUnilateral
        let draftDefaultHoldSeconds = defaultHoldSeconds
        let draftSanskritName = sanskritName.trimmingCharacters(in: .whitespaces)
        let wasYoga = editing?.isYoga == true
        let isEditing = editing != nil
        let updatedAt = Date()

        let applyDraft: @MainActor (ExerciseLibraryModel) -> Void = { exercise in
            exercise.name = draftName
            exercise.modality = draftModality
            exercise.movementPattern = draftIsCardio ? "cardio" : (draftIsYoga ? "yoga" : nil)
            exercise.primaryMuscles = draftIsCardio ? draftKind.musclesWorked : [draftPrimaryMuscle]
            exercise.secondaryMuscles = draftIsCardio ? [] : draftSecondaryMuscles
            exercise.equipment = draftEquipment
            exercise.defaultWeightMode = draftIsCardio || draftIsYoga ? .bodyweight : draftWeightMode
            exercise.preferredWeightUnitRaw = draftIsCardio || draftIsYoga ? nil : draftPreferredUnitRaw
            exercise.cardioKindRaw = draftIsCardio ? draftCardioKindRaw : nil
            exercise.isUnilateral = draftIsCardio ? false : draftIsUnilateral
            exercise.defaultHoldSeconds = draftIsYoga ? draftDefaultHoldSeconds : nil
            switch draftModality {
            case .strength: exercise.category = "strength"
            case .cardio: exercise.category = "cardio"
            case .yoga: exercise.category = "yoga"
            }
            if isEditing {
                exercise.userModified = true
                exercise.needsReview = false
                exercise.classificationSource = ClassificationSource.manual
                exercise.classificationConfidence = 1.0
            }
            exercise.updatedAt = updatedAt
        }

        let attempt = editing.map {
            ExercisePersistenceAttempt(editing: $0, in: modelContext)
        } ?? ExercisePersistenceAttempt(id: mediaID, creatingName: draftName, in: modelContext)
        let succeeded = attempt.commit(
            into: modelContext,
            mutate: { exercise, persistenceContext in
                applyDraft(exercise)
                guard draftIsYoga || wasYoga else { return }
                let exerciseID = exercise.id
                let existing = try persistenceContext.fetch(
                    FetchDescriptor<ExerciseAliasModel>(
                        predicate: #Predicate { $0.exerciseID == exerciseID }
                    )
                )

                if draftIsYoga, !draftSanskritName.isEmpty {
                    if let owned = existing.first(where: { $0.ownerID != nil }) {
                        if owned.alias != draftSanskritName { owned.alias = draftSanskritName }
                    } else if !existing.contains(where: { $0.alias == draftSanskritName }) {
                        persistenceContext.insert(ExerciseAliasModel(
                            exerciseID: exerciseID,
                            ownerID: ForgeFitDemo.userID,
                            alias: draftSanskritName
                        ))
                    }
                } else {
                    for alias in existing where alias.ownerID != nil {
                        persistenceContext.delete(alias)
                    }
                }
            },
            onCommit: { committedExercise in
                // SwiftData can retain an already-loaded source-context
                // instance after the isolated save. Mirror only now, once the
                // durable write has succeeded.
                if let editing {
                    applyDraft(editing)
                    onCreate(editing)
                } else {
                    onCreate(committedExercise)
                }
                // Photos and description are device-local files, committed
                // only once the exercise itself is durable — so a failed save
                // never leaves photos filed under an exercise that does not
                // exist. A media failure is reported without undoing the
                // exercise: the training data is the part that must not be
                // lost.
                exerciseIsCommitted = true
                if !applyMedia() {
                    mediaSaveFailed = true
                    isSaving = false
                    return
                }
                dismiss()
            }
        )

        if !succeeded { isSaving = false }
    }

    /// Writes the staged photos and description for this exercise. Returns
    /// false when either could not be written, so the form can say so instead
    /// of dismissing over a silent loss.
    private func applyMedia() -> Bool {
        let target = editing?.id ?? mediaID
        do {
            try CustomExerciseMedia.shared.apply(
                photos: photoDrafts,
                notes: notesDraft,
                for: target
            )
            mediaSaveFailed = false
            return true
        } catch {
            return false
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
