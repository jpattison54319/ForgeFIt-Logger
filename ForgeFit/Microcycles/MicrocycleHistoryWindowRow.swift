import ForgeCore
import SwiftUI

struct MicrocycleHistoryWindowRow: View {
    @Environment(\.theme) private var theme

    let window: MicrocycleHistoryWindowPresentation

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: statusImage)
                .font(.body)
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Cycle \(window.cycleNumber)")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(dateRange)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: Space.sm)

            Text("\(window.progress.completedCount)/\(window.progress.requiredCount)")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: TouchTarget.minimum)
        .padding(.vertical, Space.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Cycle \(window.cycleNumber), \(statusText), \(window.progress.completedCount) of \(window.progress.requiredCount) workouts"
        )
    }

    private var dateRange: String {
        let inclusiveEnd: Date
        switch window.state {
        case .stopped:
            inclusiveEnd = window.visibleEndsAt
        case .inProgress, .finished:
            inclusiveEnd = window.scheduledEndsAt.addingTimeInterval(-1)
        }
        return "\(window.startsAt.formatted(date: .abbreviated, time: .omitted))–\(inclusiveEnd.formatted(date: .abbreviated, time: .omitted))"
    }

    private var statusText: String {
        switch window.state {
        case .inProgress(let day, let total):
            "Day \(day) of \(total)"
        case .stopped(let day, let total):
            "Stopped on day \(day) of \(total)"
        case .finished where window.progress.isComplete:
            "All workouts complete"
        case .finished:
            "Cycle ended"
        }
    }

    private var statusImage: String {
        switch window.state {
        case .inProgress: "calendar"
        case .stopped: "stop.circle.fill"
        case .finished where window.progress.isComplete: "checkmark.circle.fill"
        case .finished: "calendar.badge.clock"
        }
    }

    private var statusColor: Color {
        switch window.state {
        case .inProgress: theme.accent
        case .stopped: theme.textSecondary
        case .finished where window.progress.isComplete: theme.accent
        case .finished: theme.textSecondary
        }
    }
}
