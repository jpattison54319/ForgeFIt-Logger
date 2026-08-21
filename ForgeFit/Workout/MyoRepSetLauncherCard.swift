import ForgeCore
import ForgeData
import SwiftUI

struct MyoRepSetLauncherCard: View {
    @Environment(\.theme) private var theme
    @Bindable var set: SetModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let showWeight: Bool
    let displayUnit: WeightUnit
    let isUnilateral: Bool
    let actionMode: MyoRepSetPresentation.Mode
    let onLaunch: () -> Void
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onDelete: () -> Void

    private var style: SetTypeStyle { SetTypeStyle.of(.myoRep, theme: theme) }
    // `self.` is required: a computed-property body whose first token is `set`
    // parses as a setter accessor.
    private var isCompleted: Bool { self.set.completedAt != nil }
    private var hasStarted: Bool {
        MyoRepSetFlow.hasStarted(
            side1ActivationReps: set.reps,
            side1MiniReps: set.miniReps,
            side2ActivationReps: set.side2Reps,
            side2MiniReps: set.side2MiniReps
        )
    }
    private var microRest: Int {
        workoutExercise.microRestSeconds ?? SetType.myoRep.defaultMicroRestSeconds ?? 15
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.sectionTitle)
                    .foregroundStyle(isCompleted ? theme.success : theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)

                ScrollSafeMenu(sections: setMenuSections) {
                    HStack(spacing: Space.xs) {
                        Text(style.badge)
                            .font(.system(size: 13, weight: .heavy))
                        Text(style.label)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(style.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(style.color.opacity(0.15))
                    .clipShape(.capsule)
                }
                .accessibilityLabel("Myo-rep set options")
                .accessibilityIdentifier("myo-set-options")

                Spacer()

                Text(isUnilateral ? "Both sides" : "Bilateral")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)

                RestDurationMenu(
                    options: [10, 15, 20, 30, 45, 60],
                    allowsOff: false,
                    selected: microRest,
                    onPick: updateMicroRest
                ) {
                    Label("\(microRest)s", systemImage: "timer")
                        .font(.tag)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .background(theme.surfaceElevated)
                        .clipShape(.capsule)
                }
            }

            if isCompleted {
                summaryRows
            } else if hasStarted {
                progressSummary
            }

            LiveLoadPrescriptionStrip(set: set, unit: displayUnit)

            HStack {
                Spacer()
                if actionMode == .editing {
                    Button("Edit Myo-rep Set", systemImage: "pencil", action: onLaunch)
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .buttonBorderShape(.capsule)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("edit-myo-rep-set")
                } else {
                    Button(
                        hasStarted ? "Resume Myo-rep Set" : "Start Myo-rep Set",
                        systemImage: "play.fill",
                        action: onLaunch
                    )
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(style.color)
                    .controlSize(.regular)
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(hasStarted ? "resume-myo-rep-set" : "start-myo-rep-set")
                }
            }
        }
        .padding(Space.md)
        .background(isCompleted ? theme.success.opacity(0.10) : style.color.opacity(0.06))
        .clipShape(.rect(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder((isCompleted ? theme.success : style.color).opacity(isCompleted ? 0.55 : 0.30))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isCompleted ? "Completed Myo-rep set" : "Myo-rep set")
        .accessibilityIdentifier("myo-rep-set-card")
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label("Myo-rep set in progress", systemImage: "clock.arrow.circlepath")
                .font(.bodyStrong)
                .foregroundStyle(style.color)
            summaryRows
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.opacity(0.55))
        .clipShape(.rect(cornerRadius: Radius.control))
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if showWeight, let weight = set.modeWeight {
                summaryRow(label: "Weight", value: Fmt.loadUnit(weight, unit: displayUnit))
            }
            summaryRow(label: isUnilateral ? "Side 1" : "Reps", value: sideSummary(reps: set.reps, minis: set.miniReps))
            if isUnilateral {
                summaryRow(label: "Side 2", value: sideSummary(reps: set.side2Reps, minis: set.side2MiniReps))
            }
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(label)
                .font(.label)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func sideSummary(reps: Int?, minis: [Int]) -> String {
        guard let reps else { return "Not logged" }
        guard !minis.isEmpty else { return "\(reps) activation" }
        return "\(reps) + \(minis.map(String.init).joined(separator: "+"))"
    }

    private var setMenuSections: [[ScrollSafeMenuItem]] {
        [
            SetType.selectable.map { type in
                ScrollSafeMenuItem(title: SetTypeStyle.of(type).label, isChecked: set.setType == type) {
                    onSetType(type)
                }
            },
            [ScrollSafeMenuItem(title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete)]
        ]
    }

    private func updateMicroRest(_ picked: Int?) {
        workoutExercise.microRestSeconds = picked
        onChange()
    }
}
