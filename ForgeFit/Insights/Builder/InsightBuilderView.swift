import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// The constrained analytical canvas: pick a shape, choose metrics from the
/// catalog, and the compatibility engine narrates everything that isn't
/// statistically defensible — invalid combinations explain themselves inline
/// instead of failing after the fact. Editing an existing card passes its
/// model; otherwise a template or a blank recipe seeds the canvas.
struct InsightBuilderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let checkins: [DailyCheckinModel]
    var editing: SavedInsightModel?
    var seed: InsightRecipe?

    @Query private var routines: [RoutineModel]

    @State private var recipe: InsightRecipe = InsightRecipe(shape: .trend, primaryMetricID: "strength.volume")
    @State private var name = ""
    @State private var preview: InsightResult?
    @State private var previewTask: Task<Void, Never>?
    @State private var showMetricPicker: MetricSlot?
    /// The canvas as it was seeded — Cancel warns only when work would be lost.
    @State private var seededRecipe: InsightRecipe?
    @State private var seededName = ""
    @State private var showDiscardConfirm = false
    @State private var saveError: String?
    // History-derived lookups computed ONCE per canvas: these are O(history)
    // and the canvas re-renders on every keystroke — recomputing them per
    // render is the tap-latency stall on large logs.
    @State private var historyExerciseIDs: Set<UUID> = []
    @State private var historyModalities: [String] = []
    @State private var exerciseNamesByID: [UUID: String] = [:]
    @State private var routineNamesByID: [UUID: String] = [:]
    @State private var scopeExercises: [ExerciseLibraryModel] = []

    enum MetricSlot: Identifiable, Equatable {
        case primary
        /// Index into the COMPARISON list (operand index − 1). Each row
        /// carries its own identity, so editing the second companion edits
        /// the second companion.
        case comparison(Int)
        var id: String {
            switch self {
            case .primary: "primary"
            case .comparison(let index): "comparison-\(index)"
            }
        }
    }

    private var validation: InsightValidation {
        InsightCompatibilityEngine.validate(recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe))
    }

    private var descriptors: [InsightMetricDescriptor] {
        InsightMetricCatalog.descriptors(covering: recipe)
    }

    private var availableBuckets: [InsightBucket] {
        InsightCompatibilityEngine.allowedBuckets(for: recipe, descriptors: descriptors)
    }

    private var availableDimensions: [InsightDimension] {
        InsightCompatibilityEngine.allowedDimensions(for: recipe, descriptors: descriptors)
    }

    private var chartChoices: [InsightChartKind] {
        var candidate = recipe
        candidate.chart = nil
        return InsightCompatibilityEngine.validate(
            candidate, descriptors: InsightMetricCatalog.descriptors(covering: candidate)
        ).allowedCharts
    }

    private var availableLags: [InsightLag] {
        InsightCompatibilityEngine.allowedLags(for: recipe, descriptors: descriptors)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        header("Name")
                        TextField(defaultName, text: $name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .padding(Space.md)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .accessibilityIdentifier("insight-name-field")
                    }
                    shapeSection
                    metricsSection
                    if recipe.shape == .groupComparison { dimensionSection }
                    alignmentSection
                    if recipe.shape == .relationship {
                        lagSection
                        populationSection
                    }
                    chartSection
                    validationSection
                    previewSection
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
            }
            .background(theme.background)
            .navigationTitle(editing == nil ? "Build an insight" : "Edit insight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.bodyStrong)
                        .disabled(!validation.isValid)
                        .accessibilityIdentifier("insight-builder-save")
                }
            }
            .confirmationDialog(
                "Discard this insight?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("The changes on this canvas haven't been saved.")
            }
            .alert("Save failed", isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(item: $showMetricPicker) { slot in
                InsightMetricPickerSheet(
                    exercises: exercises,
                    shape: recipe.shape,
                    historyExerciseIDs: historyExerciseIDs,
                    historyModalities: historyModalities,
                    excludedOperandKeys: Set(recipe.operands.enumerated().compactMap { index, operand in
                        let selectedIndex: Int
                        switch slot {
                        case .primary: selectedIndex = 0
                        case .comparison(let comparison): selectedIndex = comparison + 1
                        }
                        return index == selectedIndex ? nil : operand.key
                    }),
                    currentID: {
                        switch slot {
                        case .primary:
                            return recipe.operands.first?.metricID
                        case .comparison(let index):
                            return recipe.operands.indices.contains(index + 1)
                                ? recipe.operands[index + 1].metricID : nil
                        }
                    }()
                ) { operand in
                    apply(operand: operand, to: slot)
                }
            }
            .onAppear(perform: seedCanvas)
            .onChange(of: recipe) { _, _ in schedulePreview() }
        }
    }

    // MARK: - Sections

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(theme.textSecondary)
            .textCase(.uppercase)
    }

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header("Question")
            InsightChipRow(
                options: InsightShape.allCases,
                title: { $0.displayName },
                icon: { $0.systemImage },
                selection: Binding(
                    get: { recipe.shape },
                    set: { newShape in
                        recipe.shape = newShape
                        conformRecipeToShape()
                    }
                )
            )
            Text(recipe.shape.blurb)
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header("Show me")
            metricRow(operandIndex: 0, slot: .primary)
            if recipe.shape == .relationship || recipe.shape == .trend || recipe.shape == .periodComparison {
                header(recipe.shape == .relationship ? "Compared with" : "Alongside")
                ForEach(Array(recipe.operands.dropFirst().enumerated()), id: \.offset) { index, _ in
                    metricRow(operandIndex: index + 1, slot: .comparison(index), removable: true)
                }
                if canAddComparison {
                    Button {
                        showMetricPicker = .comparison(recipe.operands.count - 1)
                    } label: {
                        Label(
                            recipe.shape == .relationship ? "Choose comparison" : "Add metric",
                            systemImage: "plus.circle.fill"
                        )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("insight-add-comparison")
                }
            }
        }
    }

    private var canAddComparison: Bool {
        switch recipe.shape {
        case .relationship: recipe.comparisonMetricIDs.isEmpty
        case .trend, .periodComparison: recipe.comparisonMetricIDs.count < 3
        default: false
        }
    }

    @ViewBuilder
    private func metricRow(operandIndex: Int, slot: MetricSlot, removable: Bool = false) -> some View {
        if recipe.operands.indices.contains(operandIndex) {
            let operand = recipe.operands[operandIndex]
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.md) {
                    Button {
                        showMetricPicker = slot
                    } label: {
                        HStack(spacing: Space.sm) {
                            Text(displayTitle(for: operand.key))
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(Space.md)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("insight-metric-row-\(slot.id)")

                    if removable {
                        Button {
                            recipe.operands.remove(at: operandIndex)
                            conformRecipeToShape()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(theme.danger)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(displayTitle(for: operand.key))")
                    }
                }
                if !supportedScopes(for: operand).isEmpty {
                    scopeMenu(operandIndex: operandIndex)
                }
            }
        }
    }

    /// Scope kinds this operand's metric can honestly use — the menu offers
    /// nothing else, so "Pace · Bench Press" is unbuildable.
    private func supportedScopes(for operand: InsightOperand) -> Set<InsightScopeKind> {
        guard let descriptor = InsightMetricCatalog.definition(for: operand.metricID) else { return [] }
        // Required scope metrics have one coherent domain. Offering a routine
        // instead of the required cardio type would create a visible choice
        // that validation must immediately reject.
        if let required = descriptor.requiredScope { return [required] }
        return descriptor.supportedScopes
    }

    /// Per-operand scope: THIS metric over one exercise, cardio type, or
    /// routine — the piece that makes "bench e1RM vs squat e1RM" or
    /// "running pace vs cycling pace" expressible.
    private func scopeMenu(operandIndex: Int) -> some View {
        let operand = recipe.operands[operandIndex]
        let supported = supportedScopes(for: operand)
        let descriptor = InsightMetricCatalog.definition(for: operand.metricID)
        return Menu {
            if descriptor?.requiredScope == nil {
                Button("Everything") {
                    setScope(at: operandIndex, exercise: nil, modality: nil, routine: nil)
                }
                .disabled(!scopeIsUnique(
                    at: operandIndex, exercise: nil, modality: nil, routine: nil
                ))
            }
            if supported.contains(.exercise) {
                Menu("Exercise…") {
                    ForEach(scopeExercises) { exercise in
                        Button(exercise.name) {
                            setScope(at: operandIndex, exercise: exercise.id, modality: nil, routine: nil)
                        }
                        .disabled(!scopeIsUnique(
                            at: operandIndex, exercise: exercise.id, modality: nil, routine: nil
                        ))
                    }
                }
            }
            if supported.contains(.modality), !historyModalities.isEmpty {
                Menu("Cardio type…") {
                    ForEach(historyModalities, id: \.self) { modality in
                        Button(modality.capitalized) {
                            setScope(at: operandIndex, exercise: nil, modality: modality, routine: nil)
                        }
                        .disabled(!scopeIsUnique(
                            at: operandIndex, exercise: nil, modality: modality, routine: nil
                        ))
                    }
                }
            }
            if supported.contains(.routine), !routines.isEmpty {
                Menu("Routine…") {
                    ForEach(routines.filter { $0.deletedAt == nil }) { routine in
                        Button(routine.name) {
                            setScope(at: operandIndex, exercise: nil, modality: nil, routine: routine.id)
                        }
                        .disabled(!scopeIsUnique(
                            at: operandIndex, exercise: nil, modality: nil, routine: routine.id
                        ))
                    }
                }
            }
        } label: {
            // A real control: 44pt hit target, picker chevron, and the same
            // surface treatment as the metric row above it.
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(operand.isScoped ? theme.accent : theme.textSecondary)
                Text(scopeLabel(operand))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(operand.isScoped ? theme.accent : theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.surfaceElevated)
            .clipShape(Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("insight-scope-\(slotIdentifier(operandIndex))")
    }

    private func slotIdentifier(_ operandIndex: Int) -> String {
        operandIndex == 0 ? "primary" : "comparison-\(operandIndex - 1)"
    }

    private func setScope(at index: Int, exercise: UUID?, modality: String?, routine: UUID?) {
        guard recipe.operands.indices.contains(index) else { return }
        guard scopeIsUnique(
            at: index, exercise: exercise, modality: modality, routine: routine
        ) else { return }
        recipe.operands[index].exerciseID = exercise
        recipe.operands[index].modality = modality
        recipe.operands[index].routineID = routine
        conformRecipeToOptions()
    }

    private func scopeIsUnique(
        at index: Int,
        exercise: UUID?,
        modality: String?,
        routine: UUID?
    ) -> Bool {
        guard recipe.operands.indices.contains(index) else { return false }
        let candidate = InsightOperand(
            metricID: recipe.operands[index].metricID,
            exerciseID: exercise,
            modality: modality,
            routineID: routine
        )
        return !recipe.operands.enumerated().contains {
            $0.offset != index && $0.element.key == candidate.key
        }
    }

    private func scopeLabel(_ operand: InsightOperand) -> String {
        if let id = operand.exerciseID {
            return exerciseNamesByID[id] ?? "Exercise"
        }
        if let modality = operand.modality { return modality.capitalized }
        if let id = operand.routineID { return routineNamesByID[id] ?? "Routine" }
        if let required = InsightMetricCatalog.definition(for: operand.metricID)?.requiredScope {
            switch required {
            case .exercise: return "Choose exercise"
            case .modality: return "Choose cardio type"
            case .routine: return "Choose routine"
            }
        }
        return "All data"
    }

    private var dimensionSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header("Grouped by")
            if let fallback = availableDimensions.first {
                InsightChipRow(
                    options: availableDimensions,
                    title: { $0.displayName },
                    icon: { _ in nil },
                    selection: Binding(
                        get: { recipe.dimension ?? fallback },
                        set: {
                            recipe.dimension = $0
                            conformRecipeToOptions()
                        }
                    )
                )
            } else {
                Text("The selected metric has no honest grouping for this question.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header("Over")
            SegmentedPills(
                options: availableRanges,
                title: { $0.displayName },
                selection: Binding(
                    get: { recipe.range },
                    set: {
                        recipe.range = $0
                        conformRecipeToOptions()
                    }
                )
            )
            if recipe.shape == .periodComparison {
                Text("Compares two equal \(recipe.range.displayName) windows. Day/week grouping does not change a whole-period result.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !availableBuckets.isEmpty {
                header("By")
                SegmentedPills(
                    options: availableBuckets,
                    title: { $0.displayName },
                    selection: Binding(
                        get: { recipe.bucket },
                        set: { newBucket in
                            recipe.bucket = newBucket
                            conformLagToBucket()
                            conformRecipeToOptions()
                        }
                    )
                )
                if recipe.bucket == .weekly {
                    Text("Uses completed calendar weeks; the current partial week is excluded.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if recipe.bucket == .daily, recipe.shape != .periodComparison {
                    Text("Uses completed calendar days; today is excluded.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var availableRanges: [InsightRange] {
        InsightCompatibilityEngine.allowedRanges(for: recipe, descriptors: descriptors)
    }

    private var lagSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header("Timing")
            HStack {
                Text(lagDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Stepper(
                    "Timing offset",
                    value: Binding(
                        get: { recipe.lag?.count ?? 0 },
                        set: {
                            recipe.lag = InsightLag(
                                unit: recipe.bucket == .weekly ? .weeks : .days,
                                count: recipe.bucket == .session ? 0 : $0
                            )
                        }
                    ),
                    in: (availableLags.map(\.count).min() ?? 0)...(availableLags.map(\.count).max() ?? 0)
                )
                .labelsHidden()
                .accessibilityLabel("Timing offset")
                .accessibilityValue(lagDescription)
            }
            .padding(Space.md)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    private var lagDescription: String {
        let count = recipe.lag?.count ?? 0
        let unit = recipe.bucket == .weekly ? "week" : "day"
        if count == 0 { return "Same \(unit)" }
        return "\(count) \(unit)\(count == 1 ? "" : "s") later"
    }

    private var populationOptions: [InsightRelationshipPopulation] {
        InsightCompatibilityEngine.allowedRelationshipPopulations(
            for: recipe,
            descriptors: descriptors
        )
    }

    @ViewBuilder
    private var populationSection: some View {
        if !populationOptions.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                header("Population")
                SegmentedPills(
                    options: populationOptions,
                    title: populationTitle,
                    selection: Binding(
                        get: {
                            InsightCompatibilityEngine.resolvedRelationshipPopulation(
                                for: recipe,
                                descriptors: descriptors
                            )
                        },
                        set: { recipe.relationshipPopulation = $0 }
                    ),
                    accessibilityID: { "insight-population-\($0.rawValue)" }
                )
                Text(populationExplanation)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func populationTitle(_ population: InsightRelationshipPopulation) -> String {
        let noun = recipe.bucket == .weekly ? "weeks" : "days"
        switch population {
        case .activeBucketsOnly, .automatic:
            return "Training \(noun)"
        case .includeInactiveBuckets:
            return "All measured \(noun)"
        }
    }

    private var populationExplanation: String {
        let resolved = InsightCompatibilityEngine.resolvedRelationshipPopulation(
            for: recipe,
            descriptors: descriptors
        )
        let bucketNoun = recipe.bucket == .weekly ? "Weeks" : "Days"
        let zeroTitles = recipe.operands.compactMap { operand -> String? in
            guard let descriptor = InsightMetricCatalog.definition(for: operand.metricID),
                  descriptor.zeroFillPolicy == .zeroWhenAbsent else { return nil }
            return displayTitle(for: operand.key).lowercased()
        }
        let zeroSubject = zeroTitles.count == 1
            ? (zeroTitles.first ?? "training")
            : "either training total"
        let zeroRule = resolved == .includeInactiveBuckets
            ? "\(bucketNoun) without \(zeroSubject) count as 0."
            : "\(bucketNoun) without \(zeroSubject) are excluded."
        let hasHealthMeasurement = descriptors.contains {
            $0.requiresHealth && $0.zeroFillPolicy == .never
        }
        return hasHealthMeasurement
            ? zeroRule + " Missing Health readings stay excluded."
            : zeroRule + " Missing readings stay excluded."
    }

    @ViewBuilder
    private var chartSection: some View {
        if chartChoices.count > 1 {
            VStack(alignment: .leading, spacing: Space.sm) {
                header("Chart")
                InsightChipRow(
                    options: chartChoices,
                    title: { $0.displayName },
                    icon: { _ in nil },
                    selection: Binding(
                        get: { recipe.chart ?? chartChoices.first ?? .lineTrend },
                        set: { recipe.chart = $0 }
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        if !validation.isValid {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.warmup)
                            .padding(.top, 2)
                        Text(issueText(issue))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Space.md)
            .background(theme.warmup.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if validation.isValid {
            VStack(alignment: .leading, spacing: Space.sm) {
                header("Preview")
                Card {
                    if let preview {
                        InsightResultView(
                            recipe: recipe, result: preview,
                            titleFor: displayTitle(for:),
                            weightUnitFor: weightUnit(for:),
                            showsAdvanced: false
                        )
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .frame(height: 120)
                    }
                }
            }
        }
    }

    // MARK: - Behavior

    private func seedCanvas() {
        if let editing, let saved = InsightRecipe.decode(from: editing.recipeJSON) {
            recipe = saved
            name = editing.name
        } else if let seed {
            recipe = seed
            name = seed.name
        }
        migrateLegacyFilters()
        buildHistoryLookups()
        conformRecipeToOptions()
        seededRecipe = recipe
        seededName = name
        schedulePreview()
    }

    private var hasUnsavedChanges: Bool {
        guard let seededRecipe else { return false }
        // analysisSignature deliberately excludes the chosen chart and
        // display name. Cancel must still protect a chart-only edit.
        return recipe != seededRecipe || name != seededName
    }

    /// Version-1 stored one global exercise filter. The v2 canvas has one
    /// visible scope per operand, so migrate a single valid legacy exercise
    /// into every metric that can use it and remove the hidden filter.
    private func migrateLegacyFilters() {
        let exerciseFilters = recipe.filters.filter { $0.dimension == .exercise }
        if recipe.filters.count == 1,
           exerciseFilters.count == 1,
           exerciseFilters[0].values.count == 1,
           let exerciseID = UUID(uuidString: exerciseFilters[0].values[0]) {
            for index in recipe.operands.indices {
                guard InsightMetricCatalog.definition(for: recipe.operands[index].metricID)?
                    .supportedScopes.contains(.exercise) == true,
                      !recipe.operands[index].isScoped else { continue }
                recipe.operands[index].exerciseID = exerciseID
            }
        }
        // The current canvas has no recipe-level filter control. Whether a
        // legacy filter was valid and migrated or invalid and needs repair,
        // never leave an invisible constraint attached after Edit.
        recipe.filters.removeAll()
    }

    private func buildHistoryLookups() {
        historyExerciseIDs = Set(workouts.flatMap { $0.exercises.map(\.exerciseID) })
        historyModalities = Set(workouts.flatMap { workout in
            workout.cardioSessions.compactMap { session in
                session.deletedAt == nil && session.modality != CardioSessionModel.yogaModality
                    ? session.modality : nil
            }
        }).sorted()
        exerciseNamesByID = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        routineNamesByID = Dictionary(routines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let live = exercises.filter { $0.deletedAt == nil }
        let withHistory = live.filter { historyExerciseIDs.contains($0.id) }
        scopeExercises = (withHistory.isEmpty ? live : withHistory).sorted { $0.name < $1.name }
    }

    /// Selection changes update validation instantly; previews compute after
    /// a short debounce and stale ones cancel.
    private func schedulePreview() {
        previewTask?.cancel()
        preview = nil
        guard validation.isValid else { return }
        let snapshot = recipe
        previewTask = Task { [workouts, exercises, checkins, routines] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await InsightDataCoordinator.shared.result(
                for: snapshot, workouts: workouts, exercises: exercises, checkins: checkins,
                routines: routines
            )
            // A slow evaluation must never replace the preview of a newer
            // recipe — cancellation plus a signature check closes the race.
            guard !Task.isCancelled, snapshot.analysisSignature == recipe.analysisSignature else { return }
            preview = result
        }
    }

    private func apply(operand: InsightOperand, to slot: MetricSlot) {
        // Scope rides on the operand itself — required exercise or cardio
        // choices are resolved before the picker dismisses.
        switch slot {
        case .primary:
            if recipe.operands.isEmpty {
                recipe.operands = [operand]
            } else {
                recipe.operands[0] = operand
            }
        case .comparison(let index):
            if recipe.shape == .relationship {
                recipe.operands = Array(recipe.operands.prefix(1)) + [operand]
            } else if recipe.operands.indices.contains(index + 1) {
                recipe.operands[index + 1] = operand
            } else {
                recipe.operands.append(operand)
            }
        }
        conformRecipeToShape()
        conformRecipeToOptions()
    }

    /// Keeps the recipe structurally sane as the shape changes — the engine
    /// would report these, but silently repairing what has an obvious repair
    /// beats a wall of issues.
    private func conformRecipeToShape() {
        switch recipe.shape {
        case .relationship:
            recipe.operands = Array(recipe.operands.prefix(2))
            recipe.dimension = nil
            if recipe.lag == nil {
                recipe.lag = InsightLag(unit: recipe.bucket == .weekly ? .weeks : .days, count: 0)
            }
            recipe.normalization = .none
        case .groupComparison:
            recipe.operands = Array(recipe.operands.prefix(1))
            recipe.lag = nil
            recipe.relationshipPopulation = .automatic
            if recipe.dimension == nil { recipe.dimension = .checkinTag }
            recipe.normalization = .none
        case .distribution:
            recipe.operands = Array(recipe.operands.prefix(1))
            recipe.dimension = nil
            recipe.lag = nil
            recipe.relationshipPopulation = .automatic
            recipe.normalization = .none
        case .trend, .periodComparison:
            recipe.dimension = nil
            recipe.lag = nil
            recipe.relationshipPopulation = .automatic
            if recipe.shape == .periodComparison { recipe.normalization = .none }
        }
        conformTrendNormalization()
        recipe.chart = nil   // re-recommend for the new structure
        conformLagToBucket()
        conformRecipeToOptions()
    }

    /// Repairs only choices with one obvious legal replacement. Missing
    /// operands/scopes remain visible validation issues for the user.
    private func conformRecipeToOptions() {
        var currentDescriptors = InsightMetricCatalog.descriptors(covering: recipe)
        var buckets = InsightCompatibilityEngine.allowedBuckets(
            for: recipe, descriptors: currentDescriptors
        )
        if recipe.shape == .periodComparison {
            // Whole-period aggregation has no day/week/session parameter.
            recipe.bucket = .daily
        } else if !buckets.contains(recipe.bucket), let replacement = (
            buckets.contains(.daily) ? InsightBucket.daily : buckets.first
        ) {
            recipe.bucket = replacement
        }

        currentDescriptors = InsightMetricCatalog.descriptors(covering: recipe)
        let ranges = InsightCompatibilityEngine.allowedRanges(
            for: recipe, descriptors: currentDescriptors
        )
        if !ranges.contains(recipe.range), let replacement = (
            ranges.contains(.twelveWeeks) ? InsightRange.twelveWeeks : ranges.last
        ) {
            recipe.range = replacement
        }

        currentDescriptors = InsightMetricCatalog.descriptors(covering: recipe)
        buckets = InsightCompatibilityEngine.allowedBuckets(
            for: recipe, descriptors: currentDescriptors
        )
        if recipe.shape != .periodComparison,
           !buckets.contains(recipe.bucket),
           let replacement = buckets.contains(.daily) ? InsightBucket.daily : buckets.first {
            recipe.bucket = replacement
        }

        if recipe.shape == .groupComparison {
            let dimensions = InsightCompatibilityEngine.allowedDimensions(
                for: recipe, descriptors: currentDescriptors
            )
            if let current = recipe.dimension, dimensions.contains(current) {
                // Keep the valid choice.
            } else {
                recipe.dimension = dimensions.first
            }
            if recipe.dimension == .checkinTag { recipe.bucket = .daily }
        }

        conformLagToBucket()
        let lags = InsightCompatibilityEngine.allowedLags(
            for: recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        )
        if let current = recipe.lag, !lags.contains(current) {
            recipe.lag = lags.first
        }
        let populations = InsightCompatibilityEngine.allowedRelationshipPopulations(
            for: recipe,
            descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        )
        if populations.isEmpty {
            recipe.relationshipPopulation = .automatic
        }
        conformTrendNormalization()
        var chartless = recipe
        chartless.chart = nil
        let charts = InsightCompatibilityEngine.validate(
            chartless, descriptors: InsightMetricCatalog.descriptors(covering: chartless)
        ).allowedCharts
        if let chart = recipe.chart, !charts.contains(chart) {
            recipe.chart = nil
        }
    }

    /// Founder rule: a multi-metric trend renders as ONE chart wherever that
    /// is honest. Same-axis metrics overlay raw; mixed-unit metrics that can
    /// all be baseline-indexed switch to indexed lines (each series as % of
    /// its own baseline, one shared axis). Synced small multiples remain only
    /// for mixes that can't index honestly (pace, heart rate, scores).
    private func conformTrendNormalization() {
        guard recipe.shape == .trend else { return }
        let descriptors = recipe.allMetricIDs.compactMap {
            InsightMetricCatalog.definition(for: $0)
        }
        guard descriptors.count > 1, descriptors.count == recipe.allMetricIDs.count else {
            recipe.normalization = .none
            return
        }
        let families = Set(descriptors.map(\.valueKind.axisFamily))
        if families.count == 1 {
            recipe.normalization = .none
        } else if descriptors.allSatisfy(\.valueKind.supportsBaselineIndex) {
            recipe.normalization = .baselineIndex
        } else {
            recipe.normalization = .none
        }
    }

    private func conformLagToBucket() {
        guard var lag = recipe.lag else { return }
        let expectedUnit: InsightLag.Unit = recipe.bucket == .weekly ? .weeks : .days
        if lag.unit != expectedUnit {
            lag = InsightLag(unit: expectedUnit, count: 0)
            recipe.lag = lag
        }
        if recipe.bucket == .session, lag.count != 0 {
            recipe.lag = InsightLag(unit: .days, count: 0)
        }
    }

    /// Accepts an operand key OR a bare metric id (validation issues carry
    /// ids; series carry keys) — both resolve to a scoped display title.
    private func displayTitle(for key: String) -> String {
        InsightMetricCatalog.operandTitle(
            forKey: key, recipe: recipe,
            exerciseNames: exerciseNamesByID, routineNames: routineNamesByID
        )
    }

    private func weightUnit(for key: String) -> WeightUnit? {
        guard let operand = recipe.operands.first(where: { $0.key == key }),
              let exerciseID = operand.exerciseID else { return nil }
        return exercises.first(where: { $0.id == exerciseID })?.effectiveWeightUnit
    }

    private func issueText(_ issue: InsightValidationIssue) -> String {
        switch issue {
        case .unknownMetric(let id):
            return "\"\(id)\" is no longer available — pick a replacement."
        case .shapeUnsupported(let metricID):
            return "\(displayTitle(for: metricID)) can't answer this kind of question."
        case .metricCountInvalid(let expected):
            return "This question needs \(expected)."
        case .bucketUnsupported(let metricID, let bucket):
            return "\(displayTitle(for: metricID)) doesn't exist \(bucket == .session ? "per session" : "at this grouping") — it can only roll up, never split down."
        case .dimensionUnsupported(let metricID, _):
            return "\(displayTitle(for: metricID)) can't be grouped this way."
        case .lagOutsideWhitelist:
            return "Timing offsets support 0–7 days (or 0–4 weeks on weekly grouping)."
        case .lagDirectionInvalid:
            return "The timing runs backwards — the compared metric has to plausibly come first."
        case .lagUnsupportedForShape:
            return "Timing offsets only apply to relationships."
        case .normalizationUnsupported(let metricID):
            return "\(displayTitle(for: metricID)) can't be baseline-indexed."
        case .chartIncompatible:
            return "That chart can't honestly draw this data shape."
        case .rangeUnsupported(let reason):
            return reason + "."
        case .missingRequiredScope(let metricID, let scope):
            switch scope {
            case .exercise:
                return "\(displayTitle(for: metricID)) needs a specific exercise."
            case .modality:
                return "\(displayTitle(for: metricID)) needs one cardio type so unlike pace or power units aren't combined."
            case .routine:
                return "\(displayTitle(for: metricID)) needs a specific routine."
            }
        case .healthAuthorizationRequired(let metricID):
            return "\(displayTitle(for: metricID)) needs Health access — connect it in Settings → Health."
        case .duplicateMetric(let id):
            return "\(displayTitle(for: id)) appears twice with the same scope — scope one of them to an exercise, cardio type, or routine."
        case .scopeUnsupported(let metricID, let scope):
            let noun: String
            switch scope {
            case .exercise: noun = "an exercise"
            case .modality: noun = "a cardio type"
            case .routine: noun = "a routine"
            }
            return "\(displayTitle(for: metricID)) doesn't change when narrowed to \(noun) — set its scope back to Everything."
        case .multipleScopes(let metricID):
            return "\(displayTitle(for: metricID)) has more than one scope. Choose one exercise, cardio type, or routine."
        case .dimensionUnsupportedForShape:
            return "Grouping is only available for a Groups question."
        case .scopeDimensionConflict(let metricID, let dimension):
            return "\(displayTitle(for: metricID)) is already scoped by \(dimension.displayName.lowercased()); grouping by the same field would create one circular group."
        case .invalidFilter(let dimension):
            return "The saved \(dimension.displayName.lowercased()) filter is no longer supported. Saving this edit removes the hidden filter."
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var toSave = recipe
        toSave.name = trimmed.isEmpty ? defaultName : trimmed
        toSave.updatedAt = Date()
        guard let encoded = toSave.encodedJSON() else {
            saveError = "Couldn't encode this insight's configuration."
            return
        }

        if let editing {
            let previous = (editing.name, editing.recipeJSON, editing.updatedAt)
            editing.name = toSave.name
            editing.recipeJSON = encoded
            editing.updatedAt = toSave.updatedAt
            do {
                try modelContext.save()
            } catch {
                editing.name = previous.0
                editing.recipeJSON = previous.1
                editing.updatedAt = previous.2
                saveError = "Couldn't save this insight: \(error.localizedDescription)"
                return
            }
        } else {
            let existingCount = (try? modelContext.fetchCount(FetchDescriptor<SavedInsightModel>())) ?? 0
            let row = SavedInsightModel(
                userID: ForgeFitDemo.userID,
                name: toSave.name,
                recipeJSON: encoded,
                position: existingCount
            )
            modelContext.insert(row)
            do {
                try modelContext.save()
            } catch {
                modelContext.delete(row)
                saveError = "Couldn't save this insight: \(error.localizedDescription)"
                return
            }
        }
        InsightDataCoordinator.shared.invalidate()
        dismiss()
    }

    private var defaultName: String {
        let keys = recipe.operandKeys
        if keys.count == 2 {
            return "\(displayTitle(for: keys[0])) vs \(displayTitle(for: keys[1]))"
        }
        return displayTitle(for: keys.first ?? "")
    }
}

// MARK: - Metric picker sheet

/// Grouped catalog picker; scoped metrics immediately ask for their exercise.
/// Metrics that can't serve the current question sit in their own section
/// with the reason — never a valid-looking choice that fails afterward.
private struct InsightMetricPickerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let exercises: [ExerciseLibraryModel]
    var shape: InsightShape = .trend
    var historyExerciseIDs: Set<UUID> = []
    var historyModalities: [String] = []
    var excludedOperandKeys: Set<String> = []
    let currentID: String?
    let onPick: (InsightOperand) -> Void

    @State private var pendingScoped: InsightMetricDescriptor?
    @State private var pendingMuscle = false
    @State private var searchText = ""

    private func matchesSearch(_ descriptor: InsightMetricDescriptor) -> Bool {
        searchText.isEmpty
            || descriptor.title.localizedCaseInsensitiveContains(searchText)
            || descriptor.category.localizedCaseInsensitiveContains(searchText)
    }

    private func canChooseUnscoped(_ descriptor: InsightMetricDescriptor) -> Bool {
        descriptor.requiredScope != nil
            || !excludedOperandKeys.contains(InsightOperand(metricID: descriptor.id).key)
    }

    private var grouped: [(category: String, metrics: [InsightMetricDescriptor])] {
        Dictionary(
            grouping: InsightMetricCatalog.all.filter {
                $0.supportedShapes.contains(shape)
                    && matchesSearch($0)
                    && canChooseUnscoped($0)
            },
            by: \.category
        )
        .map { (category: $0.key, metrics: $0.value.sorted { $0.title < $1.title }) }
        .sorted { $0.category < $1.category }
    }

    private var ineligible: [InsightMetricDescriptor] {
        InsightMetricCatalog.all
            .filter { !$0.supportedShapes.contains(shape) && matchesSearch($0) }
            .sorted { $0.title < $1.title }
    }

    private var scopedExercises: [ExerciseLibraryModel] {
        let live = exercises.filter { $0.deletedAt == nil }
        // Exercises with logged history lead; an empty log falls back to all.
        let withHistory = live.filter { historyExerciseIDs.contains($0.id) }
        return (withHistory.isEmpty ? live : withHistory).sorted { $0.name < $1.name }
    }

    private var pendingHasChoices: Bool {
        guard let descriptor = pendingScoped, let required = descriptor.requiredScope else { return true }
        switch required {
        case .exercise:
            return scopedExercises.contains { exercise in
                !excludedOperandKeys.contains(
                    InsightOperand(
                        metricID: descriptor.id,
                        exerciseID: exercise.id
                    ).key
                )
            }
        case .modality:
            return historyModalities.contains { modality in
                !excludedOperandKeys.contains(
                    InsightOperand(
                        metricID: descriptor.id,
                        modality: modality
                    ).key
                )
            }
        case .routine:
            // No catalog metric requires routine today. Keep the generic
            // contract explicit instead of pretending an empty picker works.
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let pendingScoped, let requiredScope = pendingScoped.requiredScope {
                    switch requiredScope {
                    case .exercise:
                        Section {
                            ForEach(scopedExercises.filter {
                                !excludedOperandKeys.contains(
                                    InsightOperand(metricID: pendingScoped.id, exerciseID: $0.id).key
                                )
                            }) { exercise in
                                Button(exercise.name) {
                                    onPick(InsightOperand(
                                        metricID: pendingScoped.id,
                                        exerciseID: exercise.id
                                    ))
                                    dismiss()
                                }
                                .foregroundStyle(theme.textPrimary)
                                .themedListRow()
                                .accessibilityIdentifier("insight-required-exercise-\(exercise.id.uuidString)")
                            }
                        } header: {
                            SettingsSectionHeader(title: "Choose the exercise")
                        }
                    case .modality:
                        Section {
                            ForEach(historyModalities.filter {
                                !excludedOperandKeys.contains(
                                    InsightOperand(metricID: pendingScoped.id, modality: $0).key
                                )
                            }, id: \.self) { modality in
                                Button(modality.capitalized) {
                                    onPick(InsightOperand(
                                        metricID: pendingScoped.id,
                                        modality: modality
                                    ))
                                    dismiss()
                                }
                                .foregroundStyle(theme.textPrimary)
                                .themedListRow()
                                .accessibilityIdentifier("insight-required-modality-\(modality)")
                            }
                        } header: {
                            SettingsSectionHeader(title: "Choose one cardio type")
                        }
                    case .routine:
                        EmptyView()
                    }
                } else if pendingMuscle {
                    Section {
                        ForEach(InsightMetricCatalog.muscleOptions(exercises: exercises).filter {
                            !excludedOperandKeys.contains(
                                InsightOperand(metricID: InsightMetricCatalog.muscleSetsID(for: $0)).key
                            )
                        }, id: \.self) { muscle in
                            Button {
                                onPick(InsightOperand(
                                    metricID: InsightMetricCatalog.muscleSetsID(for: muscle)
                                ))
                                dismiss()
                            } label: {
                                HStack {
                                    Text(InsightMetricCatalog.muscleDisplayName(muscle))
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    if currentID == InsightMetricCatalog.muscleSetsID(for: muscle) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                            }
                            .themedListRow()
                            .accessibilityIdentifier("insight-muscle-\(muscle.replacingOccurrences(of: " ", with: "-"))")
                        }
                    } header: {
                        SettingsSectionHeader(title: "Muscle sets — choose the muscle")
                    }
                } else {
                    ForEach(grouped, id: \.category) { group in
                        Section {
                            ForEach(group.metrics, id: \.id) { metric in
                                Button {
                                    if metric.requiredScope != nil {
                                        pendingScoped = metric
                                    } else {
                                        onPick(InsightOperand(metricID: metric.id))
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        Text(metric.title)
                                            .font(.bodyStrong)
                                            .foregroundStyle(theme.textPrimary)
                                        Spacer()
                                        if metric.id == currentID {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                }
                                .themedListRow()
                                .accessibilityIdentifier("insight-metric-\(metric.id)")
                            }
                        } header: {
                            SettingsSectionHeader(title: group.category)
                        }
                    }
                    Section {
                        Button {
                            pendingMuscle = true
                        } label: {
                            HStack {
                                Text("Muscle sets")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                if currentID.flatMap({ InsightMetricCatalog.muscle(fromMetricID: $0) }) != nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.accent)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                        .themedListRow()
                        .accessibilityIdentifier("insight-metric-muscle-sets")
                    } header: {
                        SettingsSectionHeader(title: "Muscles")
                    } footer: {
                        Text("Working sets credited to one muscle group — put two specific muscles side by side.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                    }
                    if !ineligible.isEmpty {
                        Section {
                            ForEach(ineligible, id: \.id) { metric in
                                HStack {
                                    Text(metric.title)
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textTertiary)
                                    Spacer()
                                }
                                .themedListRow()
                            }
                        } header: {
                            SettingsSectionHeader(title: "Not for this question")
                        } footer: {
                            Text("These metrics can't answer a \(shape.displayName.lowercased()) question — switch the question type to use them.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search metrics")
            .navigationTitle(pendingScoped?.title ?? (pendingMuscle ? "Muscle sets" : "Choose metric"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if pendingScoped != nil || pendingMuscle {
                        Button("Metrics", systemImage: "chevron.left") {
                            pendingScoped = nil
                            pendingMuscle = false
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .overlay {
                if pendingScoped != nil, !pendingHasChoices {
                    ContentUnavailableView(
                        "No matching history",
                        systemImage: "chart.xyaxis.line",
                        description: Text("No unused exercise or cardio type in your history can complete this metric.")
                    )
                }
            }
        }
    }
}

// MARK: - Display names

extension InsightShape {
    var displayName: String {
        switch self {
        case .trend: "Trend"
        case .relationship: "Relationship"
        case .groupComparison: "Groups"
        case .periodComparison: "Periods"
        case .distribution: "Spread"
        }
    }
}

extension InsightDimension {
    var displayName: String {
        switch self {
        case .exercise: "Exercise"
        case .routine: "Routine"
        case .muscle: "Muscle"
        case .modality: "Activity"
        case .weekday: "Weekday"
        case .source: "Source"
        case .checkinTag: "Check-in"
        }
    }
}

extension InsightBucket {
    var displayName: String {
        switch self {
        case .daily: "Day"
        case .weekly: "Week"
        case .session: "Session"
        }
    }
}

extension InsightRange {
    var displayName: String {
        switch self {
        case .fourWeeks: "4W"
        case .twelveWeeks: "12W"
        case .sixMonths: "6M"
        case .oneYear: "1Y"
        case .allHistory: "All"
        }
    }
}

extension InsightChartKind {
    var displayName: String {
        switch self {
        case .lineTrend: "Line"
        case .barTrend: "Bars"
        case .sharedUnitOverlay: "Overlay"
        case .smallMultiples: "Stacked"
        case .baselineIndexLines: "Indexed"
        case .scatterWithTrend: "Scatter"
        case .groupedBars: "Bars"
        case .boxSummary: "Ranges"
        case .donutShare: "Share"
        case .periodComparisonCards: "Cards"
        case .histogram: "Histogram"
        }
    }
}


// MARK: - Chip row

/// Horizontally scrolling selection chips — the builder's rows carry labels
/// too long for fixed segments, and a chip may never wrap or truncate
/// (mid-word breaks read as broken UI, because they are).
private struct InsightChipRow<T: Hashable>: View {
    @Environment(\.theme) private var theme

    let options: [T]
    let title: (T) -> String
    let icon: (T) -> String?
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: Space.sm) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selection = option }
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol = icon(option) {
                                Image(systemName: symbol)
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(title(option))
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(selected ? Color.white : theme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(selected ? theme.accent : theme.surfaceElevated)
                        .clipShape(Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

extension InsightShape {
    var systemImage: String {
        switch self {
        case .trend: "chart.line.uptrend.xyaxis"
        case .relationship: "point.3.connected.trianglepath.dotted"
        case .groupComparison: "square.grid.2x2"
        case .periodComparison: "calendar"
        case .distribution: "chart.bar.fill"
        }
    }

    var blurb: String {
        switch self {
        case .trend: "How one or more metrics moved over time."
        case .relationship: "Whether two metrics tended to move together."
        case .groupComparison: "One metric compared across groups of days."
        case .periodComparison: "This period against the one before it."
        case .distribution: "Where one metric's values typically land."
        }
    }
}
