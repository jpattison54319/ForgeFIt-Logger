import ForgeData
import SwiftData
import SwiftUI

struct PlanImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let pending: PendingPlanImport
    let onSaved: (PlanImportService.ImportResult) -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    headerCard

                    if pending.isDuplicate {
                        Label("Already imported", systemImage: "checkmark.circle.fill")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.secondaryAccentForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.md)
                            .background(theme.secondaryAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.card))
                            .accessibilityIdentifier("plan-import-duplicate-warning")
                    }

                    Card {
                        VStack(spacing: Space.md) {
                            if pending.microcycleCount > 0 {
                                LabeledContent("Microcycles", value: "\(pending.microcycleCount)")
                            }
                            LabeledContent("Routines", value: "\(pending.routineCount)")
                            if pending.alternationCount > 0 {
                                LabeledContent("Alternating cycles", value: "\(pending.alternationCount)")
                            }
                            LabeledContent("Exercises", value: "\(pending.exerciseCount)")
                            if pending.customExerciseCount > 0 {
                                LabeledContent("Custom exercises", value: "\(pending.customExerciseCount)")
                            }
                        }
                        .font(.body)
                        .foregroundStyle(theme.textPrimary)
                    }

                    Text("Routine notes, targets, and alternating cycles are copied. Workout history, cycle progress, and health data are not included.")
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    PrimaryButton(
                        title: pending.isDuplicate ? "Save Another Copy" : saveTitle,
                        systemImage: "square.and.arrow.down",
                        action: save
                    )
                    .disabled(isSaving)
                    .accessibilityIdentifier("save-shared-plan")
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle("Shared \(pending.document.kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert(
                "Couldn't save plan",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) { } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var headerCard: some View {
        Card {
            HStack(spacing: Space.md) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(theme.accentForeground)
                    .frame(width: 48, height: 48)
                    .background(theme.surfaceElevated, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(pending.document.name)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(pending.alternationCount > 0 && pending.document.kind == .routine
                        ? "Alternating cycle"
                        : pending.document.kind.title)
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: Space.sm)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shared-plan-preview")
    }

    private var systemImage: String {
        switch pending.document.kind {
        case .routine: "list.bullet.rectangle"
        case .microcycle: "calendar"
        case .mesocycle: "calendar.badge.clock"
        }
    }

    private var saveTitle: String {
        switch pending.document.kind {
        case .routine: pending.alternationCount > 0 ? "Save Alternating Cycle" : "Save Routine"
        case .microcycle: "Save Microcycle"
        case .mesocycle: "Save Mesocycle"
        }
    }

    private func save() {
        isSaving = true
        do {
            let result = try PlanImportService.commit(pending.document, in: modelContext)
            onSaved(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
