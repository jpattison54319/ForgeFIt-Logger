import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct ReviewImportedExercisesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Query(filter: #Predicate<ExerciseLibraryModel> { $0.needsReview == true }, sort: \ExerciseLibraryModel.name)
    private var queriedReviewItems: [ExerciseLibraryModel]

    let workouts: [WorkoutModel]

    @State private var editingExercise: ExerciseLibraryModel?
    @State private var mergingExercise: ExerciseLibraryModel?
    @State private var errorMessage: String?

    private var reviewItems: [ExerciseLibraryModel] {
        queriedReviewItems.filter { $0.ownerID != nil && $0.deletedAt == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if reviewItems.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.md) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.danger)
                                .padding(.horizontal, Space.lg)
                        }
                        ForEach(reviewItems) { exercise in
                            ReviewImportedExerciseRow(
                                exercise: exercise,
                                onConfirm: { confirm(exercise) },
                                onEdit: { editingExercise = exercise },
                                onMerge: { mergingExercise = exercise }
                            )
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.tabBarClearance)
                }
            }
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(item: $editingExercise) { exercise in
            CreateExerciseView(editing: exercise) { _ in }
        }
        .sheet(item: $mergingExercise) { source in
            ExercisePickerView(singleSelection: true, history: workouts) { selected in
                if let target = selected.first {
                    merge(source, into: target)
                }
                mergingExercise = nil
            }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left") { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text("Imported Exercises")
                    .font(.rowValue)
                    .foregroundStyle(theme.textPrimary)
                if !reviewItems.isEmpty {
                    Text("\(reviewItems.count) to review")
                        .font(.tag)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateCard(
                title: "All imported exercises reviewed",
                message: "New low-confidence imports will appear here.",
                systemImage: "checkmark.seal"
            )
            .padding(.horizontal, Space.lg)
            Spacer()
        }
    }

    private func confirm(_ exercise: ExerciseLibraryModel) {
        exercise.needsReview = false
        exercise.userModified = true
        exercise.classificationSource = ClassificationSource.manual
        exercise.classificationConfidence = max(exercise.classificationConfidence, ExerciseClassifier.reviewConfidenceThreshold)
        exercise.updatedAt = Date()
        save()
    }

    private func merge(_ source: ExerciseLibraryModel, into target: ExerciseLibraryModel) {
        errorMessage = nil
        guard source.id != target.id else {
            errorMessage = "Choose a different exercise to merge into."
            return
        }

        do {
            try remapReferences(from: source.id, to: target.id)
            modelContext.delete(source)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remapReferences(from sourceID: UUID, to targetID: UUID) throws {
        let workoutExercises = try modelContext.fetch(FetchDescriptor<WorkoutExerciseModel>(
            predicate: #Predicate { $0.exerciseID == sourceID }
        ))
        for item in workoutExercises { item.exerciseID = targetID }

        let routineExercises = try modelContext.fetch(FetchDescriptor<RoutineExerciseModel>(
            predicate: #Predicate { $0.exerciseID == sourceID }
        ))
        for item in routineExercises { item.exerciseID = targetID }

        let aliases = try modelContext.fetch(FetchDescriptor<ExerciseAliasModel>(
            predicate: #Predicate { $0.exerciseID == sourceID }
        ))
        for item in aliases { item.exerciseID = targetID }

        let notes = try modelContext.fetch(FetchDescriptor<UserExerciseNoteModel>(
            predicate: #Predicate { $0.exerciseID == sourceID }
        ))
        for item in notes { item.exerciseID = targetID }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReviewImportedExerciseRow: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onMerge: () -> Void

    private var displayName: String {
        exercise.importedRawName?.isEmpty == false ? exercise.importedRawName! : exercise.name
    }

    private var typeText: String {
        exercise.isCardio ? "Cardio" : "Strength"
    }

    private var sourceText: String {
        switch exercise.classificationSource {
        case .matchedLibrary: "Matched library"
        case .keyword: "Keyword"
        case .seedFuzzy: "Seed fuzzy"
        case .embedding: "Embedding"
        case .ai: "AI"
        case .manual: "Manual"
        case .fallback: "Fallback"
        case nil: "Unknown"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: exercise.isCardio ? "heart.fill" : "dumbbell.fill")
                        .font(.rowValue)
                        .foregroundStyle(exercise.isCardio ? theme.danger : theme.accent)
                        .frame(width: 40, height: 40)
                        .background((exercise.isCardio ? theme.danger : theme.accent).opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                        if displayName != exercise.name {
                            Text(exercise.name)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.sm)
                    Tag(text: confidenceText, color: confidenceColor, background: confidenceColor.opacity(0.14))
                }

                HStack(spacing: Space.sm) {
                    Tag(text: typeText, color: theme.secondaryAccent, background: theme.secondaryAccent.opacity(0.14))
                    Tag(text: sourceText, color: theme.textSecondary, background: theme.surfaceElevated)
                    if let equipment = exercise.equipment, !equipment.isEmpty {
                        Tag(text: equipment.capitalized, color: theme.textSecondary, background: theme.surfaceElevated)
                    }
                }

                muscleSection("Primary", muscles: exercise.primaryMuscles)
                if !exercise.secondaryMuscles.isEmpty {
                    muscleSection("Secondary", muscles: exercise.secondaryMuscles)
                }

                HStack(spacing: Space.sm) {
                    Button(action: onConfirm) {
                        Label("Confirm", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onMerge) {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private var confidenceText: String {
        "\(Int((exercise.classificationConfidence * 100).rounded()))%"
    }

    private var confidenceColor: Color {
        exercise.classificationConfidence >= 0.7 ? theme.warmup : theme.danger
    }

    private func muscleSection(_ title: String, muscles: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.tag)
                .foregroundStyle(theme.textTertiary)
            if muscles.isEmpty {
                Tag(text: "No guess", color: theme.danger, background: theme.danger.opacity(0.14))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(muscles, id: \.self) { muscle in
                            Tag(text: muscle.capitalized, color: theme.textPrimary, background: theme.surfaceElevated)
                        }
                    }
                }
            }
        }
    }
}
