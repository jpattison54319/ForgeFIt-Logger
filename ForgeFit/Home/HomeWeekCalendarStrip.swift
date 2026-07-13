import SwiftUI

/// Compact Sunday-to-Saturday completion calendar for Home's weekly summary.
struct HomeWeekCalendarStrip: View {
    @Environment(\.theme) private var theme

    let days: [TrainingWeekSupport.Day]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Text(day.symbol)
                    .font(.bodyStrong)
                    .foregroundStyle(day.hasWorkout ? Color.black.opacity(0.78) : theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(day.hasWorkout ? theme.success : theme.surfaceElevated)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        day.hasWorkout ? theme.success : theme.separator,
                                        lineWidth: 1
                                    )
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .accessibilityValue(day.hasWorkout ? "Workout completed" : "No workout")
                    .accessibilityIdentifier("home-week-day-\(day.date.formatted(.dateTime.weekday(.wide)).lowercased())")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-week-calendar")
    }
}
