import ForgeCore
import ForgeData
import SwiftUI

/// Fast replacement flow: honest substitutes first, ordered by the lifter's
/// completed-workout favorites, with full search kept as the escape hatch.
struct ExerciseSwapSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let current: ExerciseLibraryModel
    let allExercises: [ExerciseLibraryModel]
    let inUseIDs: Set<UUID>
    let history: [WorkoutModel]
    let onPick: (ExerciseLibraryModel) -> Void

    @State private var suggestions: [ExerciseSwapSuggester.Suggestion] = []
    @State private var availableFilters: [ExerciseSwapSuggester.EquipmentFilter] = []
    @State private var equipmentFilter: ExerciseSwapSuggester.EquipmentFilter?
    @State private var computed = false
    @State private var showSearch = false
    @State private var detailExercise: ExerciseLibraryModel?
    @State private var selectedDetent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if !availableFilters.isEmpty {
                        equipmentFilters
                    }

                    if !suggestions.isEmpty {
                        LazyVStack(spacing: Space.sm) {
                            ForEach(suggestions, id: \.candidate.id) { suggestion in
                                if let exercise = exerciseByID[suggestion.candidate.id] {
                                    ReplacementExerciseRow(
                                        exercise: exercise,
                                        onShowDetails: { detailExercise = exercise },
                                        onSwap: { pick(exercise) }
                                    )
                                }
                            }
                        }
                    } else if computed {
                        EmptyStateCard(
                            title: "No close matches",
                            message: nil,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }

                    SecondaryButton(title: "Search all exercises", systemImage: "magnifyingglass") {
                        showSearch = true
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle("Replace \(current.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .navigationDestination(item: $detailExercise) { exercise in
                ExerciseDetailView(
                    exerciseID: exercise.id,
                    workouts: history,
                    exercises: allExercises
                )
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .task { computeSuggestions() }
        .sheet(isPresented: $showSearch) {
            ExercisePickerView(
                singleSelection: true,
                presetModality: current.modality,
                excludeYogaPoses: true,
                context: [current],
                history: history,
                navigationTitle: "Replace Exercise",
                excludedIDs: inUseIDs.union([current.id]),
                replacementTarget: current,
                presetReplacementEquipmentFilter: equipmentFilter
            ) { picked in
                guard let first = picked.first else { return }
                onPick(first)
                dismiss()
            }
        }
    }

    private var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(allExercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var equipmentFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                equipmentFilterButton(nil)
                ForEach(availableFilters, id: \.self) { filter in
                    equipmentFilterButton(filter)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Replacement equipment filter")
    }

    private func equipmentFilterButton(
        _ option: ExerciseSwapSuggester.EquipmentFilter?
    ) -> some View {
        let selected = equipmentFilter == option
        return Button {
            equipmentFilter = option
            computeSuggestions()
        } label: {
            Label(filterTitle(option), systemImage: selected ? "checkmark.circle.fill" : filterIcon(option))
                .font(.callout)
                .foregroundStyle(selected ? theme.background : theme.textSecondary)
                .padding(.horizontal, Space.md)
                .frame(minHeight: 44)
                .background(selected ? theme.textPrimary : theme.surface)
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("replacement-filter-\(filterIdentifier(option))")
    }

    private func computeSuggestions() {
        let pool = allExercises
            .filter { $0.deletedAt == nil && !$0.isYoga && $0.modality == current.modality }
            .map(candidate(for:))
        let target = candidate(for: current)
        if !computed {
            availableFilters = ExerciseSwapSuggester.availableFilters(
                replacing: target,
                from: pool,
                excluding: inUseIDs
            )
        }
        suggestions = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: pool,
            excluding: inUseIDs,
            equipmentFilter: equipmentFilter,
            usageByID: ExerciseSwapUsageBuilder.profiles(from: history)
        )
        computed = true
    }

    private func pick(_ exercise: ExerciseLibraryModel) {
        onPick(exercise)
        dismiss()
    }

    private func filterTitle(_ option: ExerciseSwapSuggester.EquipmentFilter?) -> String {
        switch option {
        case nil: "Best match"
        case .freeWeights: "Free weights"
        case .machineOrCable: "Machine or cable"
        case .bodyweight: "Bodyweight"
        }
    }

    private func filterIcon(_ option: ExerciseSwapSuggester.EquipmentFilter?) -> String {
        switch option {
        case nil: "sparkles"
        case .freeWeights: "dumbbell"
        case .machineOrCable: "figure.strengthtraining.traditional"
        case .bodyweight: "figure.core.training"
        }
    }

    private func filterIdentifier(_ option: ExerciseSwapSuggester.EquipmentFilter?) -> String {
        switch option {
        case nil: "best-match"
        case .freeWeights: "free-weights"
        case .machineOrCable: "machine-or-cable"
        case .bodyweight: "bodyweight"
        }
    }

    private func candidate(for exercise: ExerciseLibraryModel) -> ExerciseSwapSuggester.Candidate {
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
}
