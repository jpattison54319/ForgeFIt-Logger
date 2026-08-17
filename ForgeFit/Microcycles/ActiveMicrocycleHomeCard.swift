import ForgeCore
import ForgeData
import SwiftUI

struct ActiveMicrocycleHomeCard<Destination: Hashable>: View {
    @Environment(\.theme) private var theme

    let tracking: MicrocycleTrackingModel
    let window: MicrocycleWindowModel
    let progress: MicrocycleProgress
    let workouts: [WorkoutModel]
    let restDays: [RestDayModel]
    let windows: [MicrocycleWindowModel]
    let exercises: [ExerciseLibraryModel]
    let detailsDestination: Destination
    let onRemoveFromHome: () -> Void

    @State private var selectedDay: MicrocycleDaySelection?

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                header
                MicrocycleDayStrip(
                    window: window,
                    workouts: workouts,
                    restDays: restDays,
                    isCompact: true,
                    onSelectDay: selectDay
                )
                footer
            }
        }
        .accessibilityIdentifier("home-microcycle-card")
        .sheet(item: $selectedDay) { selection in
            MicrocycleDayDetailSheet(
                date: selection.date,
                window: window,
                windows: windows,
                workouts: workouts,
                restDays: restDays,
                exercises: exercises
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tracking.folderName)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("Day \(MicrocycleTrackingService.dayNumber(for: window)) of \(MicrocycleTrackingService.windowDurationDays(for: window))")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button("Remove microcycle from Home", systemImage: "xmark", action: onRemoveFromHome)
                .labelStyle(.iconOnly)
                .font(.caption.bold())
                .foregroundStyle(theme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityHint("Tracking continues and can be added back from the microcycle menu.")
                .accessibilityIdentifier("microcycle-remove-from-home")
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Label(
                progress.isComplete
                    ? "All workouts complete"
                    : "\(progress.completedCount) of \(progress.requiredCount) workouts",
                systemImage: progress.isComplete ? "checkmark.circle.fill" : "dumbbell"
            )
            .font(.subheadline)
            .foregroundStyle(progress.isComplete ? theme.accent : theme.textSecondary)

            Spacer(minLength: Space.sm)

            NavigationLink(value: detailsDestination) {
                HStack(spacing: Space.xs) {
                    Text("View Details")
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(.subheadline.bold())
                .foregroundStyle(theme.accentForeground)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("microcycle-view-details")
        }
    }

    private func selectDay(_ date: Date) {
        selectedDay = MicrocycleDaySelection(date: date)
    }
}
