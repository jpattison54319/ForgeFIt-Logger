import ForgeCore
import ForgeData
import SwiftUI

struct MicrocycleHistorySummaryCard: View {
    @Environment(\.theme) private var theme

    let tracking: MicrocycleTrackingModel
    let window: MicrocycleWindowModel
    let presentation: MicrocycleHistoryWindowPresentation
    let days: [MicrocycleDayPresentation]
    let workouts: [WorkoutModel]
    let restDays: [RestDayModel]
    let onSelectDay: (Date) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tracking.folderName)
                            .font(.headline)
                            .foregroundStyle(theme.textPrimary)
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Text("\(presentation.progress.completedCount)/\(presentation.progress.requiredCount)")
                        .font(.headline)
                        .foregroundStyle(
                            presentation.progress.isComplete ? theme.accent : theme.textPrimary
                        )
                }

                MicrocycleDayStrip(
                    window: window,
                    workouts: workouts,
                    restDays: restDays,
                    presentedDays: days,
                    isReadOnly: true,
                    onSelectDay: onSelectDay
                )
            }
        }
    }

    private var statusText: String {
        switch presentation.state {
        case .inProgress(let day, let total):
            "In progress · Day \(day) of \(total)"
        case .stopped(let day, let total):
            "Stopped on day \(day) of \(total)"
        case .finished where presentation.progress.isComplete:
            "Finished · All workouts complete"
        case .finished:
            "Finished · \(presentation.progress.completedCount) of \(presentation.progress.requiredCount) workouts"
        }
    }
}
