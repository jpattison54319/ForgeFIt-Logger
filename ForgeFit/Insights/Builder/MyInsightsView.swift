import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Compact entry on the Insights tab. The template gallery and saved cards
/// live on the pushed My Insights page — the tab itself stays lean (founder
/// call: template cards inline were clutter).
struct MyInsightsEntryCard: View {
    @Environment(\.theme) private var theme

    @Query(sort: \SavedInsightModel.position) private var saved: [SavedInsightModel]

    private var liveCount: Int {
        saved.count { $0.deletedAt == nil }
    }

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Insights")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(liveCount == 0
                        ? "Build your own comparisons"
                        : "\(liveCount) saved comparison\(liveCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

/// The My Insights page: template gallery, the user's saved cards with
/// edit/duplicate/delete, and the builder entry. Cards evaluate lazily
/// through the coordinator's cache — revisiting the page never recomputes a
/// recipe whose inputs haven't changed.
struct MyInsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @Query(sort: \SavedInsightModel.position) private var saved: [SavedInsightModel]
    @Query(sort: \DailyCheckinModel.updatedAt, order: .reverse) private var checkins: [DailyCheckinModel]
    @Query private var routines: [RoutineModel]

    @State private var buildingSeed: InsightRecipe?
    @State private var templateNeedingScope: InsightTemplate?
    @State private var showBlankBuilder = false
    @State private var showTemplatesFromNonEmpty = false
    @State private var editingCard: SavedInsightModel?
    @State private var cardPendingDelete: SavedInsightModel?
    @State private var openedCard: SavedInsightModel?
    @State private var persistError: String?

    private var liveCards: [SavedInsightModel] {
        saved.filter { $0.deletedAt == nil }
    }

    private var historyModalities: [String] {
        Set(workouts.flatMap { workout in
            workout.cardioSessions.compactMap { session in
                session.deletedAt == nil && session.modality != CardioSessionModel.yogaModality
                    ? session.modality : nil
            }
        }).sorted()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                    Spacer()
                    Text("My Insights")
                        .font(.rowValue)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    // One template affordance at a time: the empty state IS
                    // the gallery, so the header button appears only once
                    // saved cards have replaced it.
                    if !liveCards.isEmpty {
                        CircleIconButton(systemImage: "sparkles", label: "Templates") { showTemplatesFromNonEmpty = true }
                            .accessibilityIdentifier("insight-templates-button")
                    }
                    CircleIconButton(systemImage: "plus", label: "Build an insight") { showBlankBuilder = true }
                        .accessibilityIdentifier("insight-build-button")
                }
                .padding(.top, Space.sm)

                if liveCards.isEmpty {
                    templateGallery
                } else {
                    ForEach(Array(liveCards.enumerated()), id: \.element.id) { index, card in
                        SavedInsightCard(
                            card: card,
                            workouts: workouts,
                            exercises: exercises,
                            checkins: checkins,
                            routines: routines,
                            onOpen: { openedCard = card },
                            onEdit: { editingCard = card },
                            onDuplicate: { duplicate(card) },
                            onDelete: { cardPendingDelete = card },
                            onMoveUp: index > 0 ? { move(card, by: -1) } : nil,
                            onMoveDown: index < liveCards.count - 1 ? { move(card, by: 1) } : nil
                        )
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Save failed", isPresented: .init(
            get: { persistError != nil },
            set: { if !$0 { persistError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(persistError ?? "")
        }
        .sheet(isPresented: $showBlankBuilder) {
            InsightBuilderView(workouts: workouts, exercises: exercises, checkins: checkins)
        }
        .sheet(item: $buildingSeed) { seed in
            InsightBuilderView(workouts: workouts, exercises: exercises, checkins: checkins, seed: seed)
        }
        .sheet(item: $templateNeedingScope) { template in
            if let scope = template.requiredScopeToPick {
                TemplateRequiredScopePicker(
                    template: template,
                    scope: scope,
                    exercises: exercises,
                    historyExerciseIDs: Set(workouts.flatMap { $0.exercises.map(\.exerciseID) }),
                    modalities: historyModalities,
                    routines: routines
                ) { value in
                    let resolved = template.resolvedRecipe(scope: scope, value: value)
                    templateNeedingScope = nil
                    Task { @MainActor in
                        await Task.yield()
                        buildingSeed = resolved
                    }
                }
            }
        }
        .sheet(item: $editingCard) { card in
            InsightBuilderView(workouts: workouts, exercises: exercises, checkins: checkins, editing: card)
        }
        .sheet(item: $openedCard) { card in
            SavedInsightDetailSheet(
                card: card,
                workouts: workouts, exercises: exercises, checkins: checkins, routines: routines,
                onEdit: { openedCard = nil; editingCard = card },
                onDuplicate: { duplicate(card) }
            )
        }
        .sheet(isPresented: $showTemplatesFromNonEmpty) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: Space.md) { templateRows }
                        .padding(Space.lg)
                }
                .background(theme.background)
                .navigationTitle("Templates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showTemplatesFromNonEmpty = false }
                            .font(.bodyStrong)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(cardPendingDelete?.name ?? "insight")\"?",
            isPresented: Binding(get: { cardPendingDelete != nil }, set: { if !$0 { cardPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Insight", role: .destructive) {
                if let card = cardPendingDelete { delete(card) }
                cardPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { cardPendingDelete = nil }
        } message: {
            Text("Only this saved comparison is removed — none of your training or Health data is touched.")
        }
    }

    private var templateGallery: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Ask your own questions of your training and Health history — start from a template or build from scratch.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            templateRows
        }
    }

    @ViewBuilder
    private var templateRows: some View {
        ForEach(InsightTemplateCatalog.all) { template in
            Button {
                choose(template)
            } label: {
                Card(padding: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: template.systemImage)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 36, height: 36)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.title)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text(template.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insight-template-\(template.id)")
        }
    }

    private func choose(_ template: InsightTemplate) {
        let present = {
            if template.requiredScopeToPick != nil {
                templateNeedingScope = template
            } else {
                buildingSeed = template.recipe
            }
        }
        if showTemplatesFromNonEmpty {
            showTemplatesFromNonEmpty = false
            Task { @MainActor in
                await Task.yield()
                present()
            }
        } else {
            present()
        }
    }

    private func duplicate(_ card: SavedInsightModel) {
        guard var recipe = InsightRecipe.decode(from: card.recipeJSON) else { return }
        recipe.id = UUID()
        recipe.name = card.name + " copy"
        guard let encoded = recipe.encodedJSON() else {
            persistError = "Couldn't encode the duplicated insight."
            return
        }
        let copy = SavedInsightModel(
            userID: card.userID,
            name: recipe.name,
            recipeJSON: encoded,
            position: liveCards.count
        )
        modelContext.insert(copy)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(copy)
            persistError = "Couldn't duplicate the insight: \(error.localizedDescription)"
        }
    }

    private func delete(_ card: SavedInsightModel) {
        let previous = (card.deletedAt, card.updatedAt)
        let now = Date()
        card.deletedAt = now
        card.updatedAt = now
        do {
            try modelContext.save()
        } catch {
            card.deletedAt = previous.0
            card.updatedAt = previous.1
            persistError = "Couldn't delete the insight: \(error.localizedDescription)"
        }
    }

    /// Menu-driven reorder (the model already carries `position`). Rewrites
    /// every position from the new order so stale duplicates self-heal.
    private func move(_ card: SavedInsightModel, by offset: Int) {
        var cards = liveCards
        guard let index = cards.firstIndex(where: { $0.id == card.id }),
              cards.indices.contains(index + offset) else { return }
        let previous = Dictionary(
            uniqueKeysWithValues: cards.map { ($0.id, ($0.position, $0.updatedAt)) }
        )
        cards.swapAt(index, index + offset)
        let now = Date()
        for (position, row) in cards.enumerated() where row.position != position {
            row.position = position
            row.updatedAt = now
        }
        do {
            try modelContext.save()
        } catch {
            for row in cards {
                if let old = previous[row.id] {
                    row.position = old.0
                    row.updatedAt = old.1
                }
            }
            persistError = "Couldn't reorder insights: \(error.localizedDescription)"
        }
    }
}

// MARK: - Saved card

private struct SavedInsightCard: View {
    @Environment(\.theme) private var theme

    let card: SavedInsightModel
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let checkins: [DailyCheckinModel]
    var routines: [RoutineModel] = []
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @State private var result: InsightResult?

    private var recipe: InsightRecipe? {
        InsightRecipe.decode(from: card.recipeJSON)
    }

    private var recipeIsValid: Bool {
        guard let recipe else { return false }
        return InsightCompatibilityEngine.validate(
            recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        ).isValid
    }

    // The options menu is a SIBLING of the open button, never nested inside
    // it — nesting breaks VoiceOver and hit-testing, and the menu deserves
    // its own 44-point target.
    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Text(card.name)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let recipe {
                        Text(recipe.range.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(theme.surfaceElevated)
                            .clipShape(Capsule())
                    }
                    Menu {
                        Button("Edit", systemImage: "pencil", action: onEdit)
                        Button("Duplicate", systemImage: "doc.on.doc", action: onDuplicate)
                        if let onMoveUp {
                            Button("Move up", systemImage: "arrow.up", action: onMoveUp)
                        }
                        if let onMoveDown {
                            Button("Move down", systemImage: "arrow.down", action: onMoveDown)
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Options for \(card.name)")
                }

                if let recipe, recipeIsValid {
                    Button(action: onOpen) {
                        Group {
                            if let result {
                            InsightResultView(
                                recipe: recipe, result: result,
                                titleFor: { titleFor($0, recipe: recipe) },
                                weightUnitFor: { weightUnitFor($0, recipe: recipe) },
                                showsAdvanced: false
                            )
                            } else {
                                HStack { Spacer(); ProgressView(); Spacer() }
                                    .frame(height: 80)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the full insight")
                    .accessibilityIdentifier("insight-card-\(card.name)")
                } else {
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.warmup)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Needs attention")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text(recipe == nil
                                ? "The saved configuration couldn't be read."
                                : "A metric, scope, grouping, or chart is no longer supported.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Button("Edit", action: onEdit)
                            .font(.system(size: 13, weight: .bold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("insight-card-needs-attention")
                }
            }
        }
        .task(id: taskKey) {
            guard let recipe, recipeIsValid else {
                result = nil
                return
            }
            result = await InsightDataCoordinator.shared.result(
                for: recipe, workouts: workouts, exercises: exercises, checkins: checkins,
                routines: routines
            )
        }
    }

    /// Re-evaluates only when the recipe or the underlying data changes.
    private var taskKey: String {
        (recipe?.analysisSignature ?? "corrupt") + "|" +
            InsightDataCoordinator.shared.fingerprint(
                workouts: workouts, checkins: checkins, exercises: exercises, routines: routines
            )
    }

    private func titleFor(_ key: String, recipe: InsightRecipe) -> String {
        InsightMetricCatalog.operandTitle(
            forKey: key, recipe: recipe,
            exerciseNames: Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            routineNames: Dictionary(routines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func weightUnitFor(_ key: String, recipe: InsightRecipe) -> WeightUnit? {
        guard let operand = recipe.operands.first(where: { $0.key == key }),
              let exerciseID = operand.exerciseID else { return nil }
        return exercises.first(where: { $0.id == exerciseID })?.effectiveWeightUnit
    }
}

// MARK: - Detail sheet

private struct SavedInsightDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let card: SavedInsightModel
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let checkins: [DailyCheckinModel]
    var routines: [RoutineModel] = []
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?

    @State private var result: InsightResult?

    private var decodedRecipe: InsightRecipe? {
        InsightRecipe.decode(from: card.recipeJSON)
    }

    private var recipeIsValid: Bool {
        guard let recipe = decodedRecipe else { return false }
        return InsightCompatibilityEngine.validate(
            recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        ).isValid
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let recipe = decodedRecipe, recipeIsValid {
                        if let result {
                            InsightResultView(
                                recipe: recipe, result: result,
                                titleFor: { key in
                                    InsightMetricCatalog.operandTitle(
                                        forKey: key, recipe: recipe,
                                        exerciseNames: Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                                        routineNames: Dictionary(routines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                                    )
                                },
                                weightUnitFor: { key in
                                    guard let operand = recipe.operands.first(where: { $0.key == key }),
                                          let exerciseID = operand.exerciseID else { return nil }
                                    return exercises.first(where: { $0.id == exerciseID })?.effectiveWeightUnit
                                },
                                showsAdvanced: true
                            )
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 200)
                        }
                    } else {
                        EmptyStateCard(
                            title: "Insight needs attention",
                            message: decodedRecipe == nil
                                ? "The saved configuration couldn't be read."
                                : "Its saved metric, scope, grouping, or chart is no longer a valid combination.",
                            systemImage: "exclamationmark.triangle"
                        )
                        if let onEdit {
                            Button("Edit insight") { onEdit() }
                                .font(.bodyStrong)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .buttonStyle(.borderedProminent)
                                .tint(theme.accent)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let onEdit {
                            Button("Edit", systemImage: "pencil", action: onEdit)
                        }
                        if let onDuplicate {
                            Button("Duplicate", systemImage: "doc.on.doc") {
                                onDuplicate()
                                dismiss()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Insight actions")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.bodyStrong)
                }
            }
            .task {
                guard let recipe = decodedRecipe, recipeIsValid else { return }
                result = await InsightDataCoordinator.shared.result(
                    for: recipe, workouts: workouts, exercises: exercises, checkins: checkins,
                    routines: routines
                )
            }
        }
    }
}

private struct TemplateRequiredScopePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let template: InsightTemplate
    let scope: InsightScopeKind
    let exercises: [ExerciseLibraryModel]
    let historyExerciseIDs: Set<UUID>
    let modalities: [String]
    let routines: [RoutineModel]
    let onPick: (String) -> Void

    private var exerciseChoices: [ExerciseLibraryModel] {
        let live = exercises.filter { $0.deletedAt == nil }
        let withHistory = live.filter { historyExerciseIDs.contains($0.id) }
        return (withHistory.isEmpty ? live : withHistory).sorted { $0.name < $1.name }
    }

    private var routineChoices: [RoutineModel] {
        routines.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name }
    }

    private var hasChoices: Bool {
        switch scope {
        case .exercise: !exerciseChoices.isEmpty
        case .modality: !modalities.isEmpty
        case .routine: !routineChoices.isEmpty
        }
    }

    private var title: String {
        switch scope {
        case .exercise: "Choose exercise"
        case .modality: "Choose cardio type"
        case .routine: "Choose routine"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                switch scope {
                case .exercise:
                    ForEach(exerciseChoices) { exercise in
                        Button(exercise.name) { onPick(exercise.id.uuidString) }
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .themedListRow()
                            .accessibilityIdentifier("insight-template-exercise-\(exercise.id.uuidString)")
                    }
                case .modality:
                    ForEach(modalities, id: \.self) { modality in
                        Button(modality.capitalized) { onPick(modality) }
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .themedListRow()
                            .accessibilityIdentifier("insight-template-modality-\(modality)")
                    }
                case .routine:
                    ForEach(routineChoices) { routine in
                        Button(routine.name) { onPick(routine.id.uuidString) }
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .themedListRow()
                            .accessibilityIdentifier("insight-template-routine-\(routine.id.uuidString)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if !hasChoices {
                    ContentUnavailableView(
                        "No matching history",
                        systemImage: scope == .exercise ? "dumbbell" : "chart.xyaxis.line",
                        description: Text("Log this \(scope == .exercise ? "exercise" : "activity") before using \(template.title).")
                    )
                }
            }
        }
    }
}

extension InsightRecipe: @retroactive Identifiable {}
