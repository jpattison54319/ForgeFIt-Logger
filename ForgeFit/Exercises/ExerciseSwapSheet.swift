import ForgeCore
import ForgeData
import SwiftUI

/// The "gym swap" replacement sheet: the station you wanted is taken, so lead
/// with a handful of close substitutes — same muscles first, free-weight
/// alternatives flagged for machine-based exercises, and exercises that fit
/// the lifter's current training block boosted by recent, repeated use. Search
/// stays one tap away as the escape hatch, not the first move.
struct ExerciseSwapSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// The exercise being replaced.
    let current: ExerciseLibraryModel
    /// The full library (the caller already holds it — no extra query).
    let allExercises: [ExerciseLibraryModel]
    /// Exercises already in the workout/routine — never suggested.
    let inUseIDs: Set<UUID>
    /// Completed workouts, for recency and frequency ranking.
    let history: [WorkoutModel]
    let onPick: (ExerciseLibraryModel) -> Void

    @State private var suggestions: [ExerciseSwapSuggester.Suggestion] = []
    @State private var availablePreferences: [ExerciseSwapSuggester.SwapPreference] = []
    @State private var preference: ExerciseSwapSuggester.SwapPreference?
    @State private var computed = false
    @State private var showSearch = false
    @State private var selectedDetent: PresentationDetent = .large
    @State private var referenceDate = Date()

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if !availablePreferences.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.sm) {
                                preferenceButton(nil)
                                ForEach(availablePreferences, id: \.self) { option in
                                    preferenceButton(option)
                                }
                            }
                        }
                        .accessibilityLabel("Preferred replacement equipment")
                    }

                    if !suggestions.isEmpty {
                        VStack(spacing: Space.sm) {
                            ForEach(suggestions, id: \.candidate.id) { suggestion in
                                if let exercise = allExercises.first(where: { $0.id == suggestion.candidate.id }) {
                                    suggestionRow(exercise, facets: suggestion.facets)
                                }
                            }
                        }
                    } else if computed {
                        EmptyStateCard(
                            title: "No close matches",
                            message: "Nothing similar enough in the library — search for a replacement instead.",
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
            .background(theme.background)
            .navigationTitle("Replace \(current.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
                excludedIDs: inUseIDs.union([current.id])
            ) { picked in
                if let first = picked.first {
                    onPick(first)
                    dismiss()
                }
            }
        }
    }

    private func suggestionRow(_ exercise: ExerciseLibraryModel, facets: [ExerciseSwapSuggester.MatchFacet]) -> some View {
        Button {
            onPick(exercise)
            dismiss()
        } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name)
                        .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(ExerciseSwapPresentation.caption(for: facets, referenceDate: referenceDate))
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Spacer(minLength: Space.sm)
                if let equipment = exercise.equipment, !equipment.isEmpty {
                    Text(equipment.capitalized)
                        .font(.tag).foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(theme.surfaceElevated)
                        .clipShape(Capsule())
                }
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryAccent)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(
            "Replace with \(exercise.name). \(ExerciseSwapPresentation.caption(for: facets, referenceDate: referenceDate))"
        )
    }

    private func computeSuggestions() {
        let pool = allExercises
            .filter { $0.deletedAt == nil && !$0.isYoga && $0.modality == current.modality }
            .map(candidate(for:))
        let usageByID = ExerciseSwapUsageBuilder.profiles(from: history)
        let target = candidate(for: current)
        if !computed {
            availablePreferences = ExerciseSwapSuggester.availablePreferences(
                replacing: target,
                from: pool,
                excluding: inUseIDs
            )
        }
        suggestions = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: pool,
            excluding: inUseIDs,
            preference: preference,
            usageByID: usageByID,
            referenceDate: referenceDate
        )
        computed = true
    }

    private func preferenceButton(_ option: ExerciseSwapSuggester.SwapPreference?) -> some View {
        let selected = preference == option
        return Button {
            preference = option
            computeSuggestions()
        } label: {
            Label(preferenceTitle(option), systemImage: selected ? "checkmark.circle.fill" : preferenceIcon(option))
                .font(.callout)
                .foregroundStyle(selected ? theme.background : theme.textSecondary)
                .padding(.horizontal, Space.md)
                .frame(minHeight: 44)
                .background(selected ? theme.textPrimary : theme.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func preferenceTitle(_ option: ExerciseSwapSuggester.SwapPreference?) -> String {
        switch option {
        case nil: "Best match"
        case .freeWeights: "Free weights"
        case .machineOrCable: "Machine or cable"
        case .bodyweight: "Bodyweight"
        }
    }

    private func preferenceIcon(_ option: ExerciseSwapSuggester.SwapPreference?) -> String {
        switch option {
        case nil: "sparkles"
        case .freeWeights: "dumbbell"
        case .machineOrCable: "figure.strengthtraining.traditional"
        case .bodyweight: "figure.core.training"
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
            mechanic: exercise.mechanic,
            force: exercise.force
        )
    }
}
