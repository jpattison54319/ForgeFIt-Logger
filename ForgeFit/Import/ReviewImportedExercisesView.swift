import ForgeData
import SwiftData
import SwiftUI

extension ExerciseLibraryModel {
    /// Every exercise added by a workout-history import that the user has not
    /// approved, edited, or discarded, plus any legacy low-confidence guess.
    /// Callers still filter out non-owned and soft-deleted rows.
    static var pendingImportReviewPredicate: Predicate<ExerciseLibraryModel> {
        #Predicate<ExerciseLibraryModel> { exercise in
            exercise.needsReview == true
                || (exercise.importBatchID != nil && exercise.userModified == false)
        }
    }

    /// Least-confident suggestions first, then name. Confidence is an internal
    /// prioritization signal, not a user-facing probability or workout score.
    static var pendingImportReviewSort: [SortDescriptor<ExerciseLibraryModel>] {
        [
            SortDescriptor(\.classificationConfidence),
            SortDescriptor(\.name),
        ]
    }
}

struct ReviewImportedExercisesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Query(filter: ExerciseLibraryModel.pendingImportReviewPredicate, sort: ExerciseLibraryModel.pendingImportReviewSort)
    private var queriedReviewItems: [ExerciseLibraryModel]

    let workouts: [WorkoutModel]

    @State private var editingExercise: ExerciseLibraryModel?

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
                        ImportedExerciseReviewSummaryCard(
                            count: reviewItems.count,
                            onApproveAll: approveAll,
                            onDiscardAll: discardAll
                        )
                        ForEach(reviewItems) { exercise in
                            ReviewImportedExerciseRow(
                                exercise: exercise,
                                onApprove: { approve(exercise) },
                                onEdit: { editingExercise = exercise },
                                onDiscard: { discard(exercise) }
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
        .bottomChromeHidden(true)
        .interactiveBackSwipeEnabled()
        .sheet(item: $editingExercise) { exercise in
            CreateExerciseView(editing: exercise) { _ in }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back", action: dismiss.callAsFunction)
            Spacer()
            VStack(spacing: 1) {
                Text("Review Imported Exercises")
                    .font(.rowValue)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("imported-exercise-review-header")
                if !reviewItems.isEmpty {
                    Text("\(reviewItems.count) new exercise\(reviewItems.count == 1 ? "" : "s")")
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
                title: "Exercise review complete",
                message: "Approved exercises are in your library. Discarded exercises stay out of it, while your imported workout history remains unchanged.",
                systemImage: "checkmark.seal"
            )
            .padding(.horizontal, Space.lg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("imported-exercise-review-complete")
            Spacer()
        }
    }

    private func approve(_ exercise: ExerciseLibraryModel) {
        apply(.approve, to: [exercise.id])
    }

    private func approveAll() {
        apply(.approve, to: reviewItems.map(\.id))
    }

    private func discard(_ exercise: ExerciseLibraryModel) {
        apply(.discard, to: [exercise.id])
    }

    private func discardAll() {
        apply(.discard, to: reviewItems.map(\.id))
    }

    private func apply(_ action: ImportedExerciseReviewService.Action, to exerciseIDs: [UUID]) {
        PersistentChangeSaveCenter.shared.perform({
            try ImportedExerciseReviewService.apply(
                action,
                to: exerciseIDs,
                in: modelContext.container
            )
        }, onSuccess: {
            BackupScheduler.shared.noteLogDataChanged()
        })
    }
}
