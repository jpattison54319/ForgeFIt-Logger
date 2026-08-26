import ForgeData
import SwiftUI

struct ReviewImportedExerciseRow: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    let onApprove: () -> Void
    let onEdit: () -> Void
    let onDiscard: () -> Void

    @State private var isConfirmingDiscard = false

    private var displayName: String {
        if let importedName = exercise.importedRawName, !importedName.isEmpty {
            importedName
        } else {
            exercise.name
        }
    }

    private var typeText: String {
        exercise.isCardio ? "Cardio" : "Strength"
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
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                            .accessibilityIdentifier("imported-exercise-row-\(exercise.id.uuidString.lowercased())")
                        if displayName != exercise.name {
                            Text("Saved as \(exercise.name)")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.sm)
                }

                HStack(spacing: Space.sm) {
                    Tag(text: typeText, color: theme.secondaryAccent, background: theme.secondaryAccent.opacity(0.14))
                    if let equipment = exercise.equipment, !equipment.isEmpty {
                        Tag(text: equipment.capitalized, color: theme.textSecondary, background: theme.surfaceElevated)
                    }
                }

                ImportedExerciseMuscleSection(title: "Suggested primary muscles", muscles: exercise.primaryMuscles)
                ImportedExerciseMuscleSection(title: "Suggested secondary muscles", muscles: exercise.secondaryMuscles)

                HStack(spacing: Space.sm) {
                    Button(action: onApprove) {
                        Text("Approve")
                            .frame(maxWidth: .infinity)
                    }
                    .minimumTouchTarget()
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .accessibilityLabel("Approve \(displayName)")
                    .accessibilityIdentifier("approve-imported-exercise-\(exercise.id.uuidString.lowercased())")

                    Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                        .frame(maxWidth: .infinity)
                        .minimumTouchTarget()
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Edit \(displayName)")
                        .accessibilityIdentifier("edit-imported-exercise-\(exercise.id.uuidString.lowercased())")

                    Button("Discard", systemImage: "trash", role: .destructive) {
                        isConfirmingDiscard = true
                    }
                    .frame(maxWidth: .infinity)
                    .minimumTouchTarget()
                    .buttonStyle(.bordered)
                    .tint(theme.danger)
                    .accessibilityLabel("Discard \(displayName)")
                    .accessibilityIdentifier("discard-imported-exercise-\(exercise.id.uuidString.lowercased())")
                    .alert(
                        "Discard \(displayName)?",
                        isPresented: $isConfirmingDiscard
                    ) {
                        Button("Discard exercise", role: .destructive, action: onDiscard)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("It will be removed from your exercise library. Imported workouts will remain in your history.")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}
