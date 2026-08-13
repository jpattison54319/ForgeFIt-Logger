import ForgeData
import SwiftUI

struct MicrocycleDayStrip: View {
    @Environment(\.theme) private var theme

    let window: MicrocycleWindowModel
    let workouts: [WorkoutModel]
    let restDays: [RestDayModel]
    var now: Date = .now
    var isCompact = false
    let onSelectDay: (Date) -> Void

    var body: some View {
        if isCompact {
            HStack(spacing: days.count > 14 ? 2 : Space.xs) {
                ForEach(days, id: \.date) { day in
                    Button {
                        onSelectDay(day.date)
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fill(for: day))
                            .strokeBorder(
                                day.isToday ? theme.accent : stroke(for: day.status),
                                lineWidth: day.isToday ? 2 : 1
                            )
                            .frame(height: day.isToday ? 10 : 8)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: day))
                    .accessibilityHint(accessibilityHint(for: day.status))
                }
            }
            .frame(height: 44)
            .accessibilityElement(children: .contain)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 50, maximum: 64), spacing: Space.xs)],
                spacing: Space.sm
            ) {
                ForEach(days, id: \.date) { day in
                    Button {
                        onSelectDay(day.date)
                    } label: {
                        dayCell(day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: day))
                    .accessibilityHint(accessibilityHint(for: day.status))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var days: [MicrocycleDayPresentation] {
        MicrocycleDayTimeline.days(
            in: window,
            workouts: workouts,
            restDays: restDays,
            now: now
        )
    }

    private func dayCell(_ day: MicrocycleDayPresentation) -> some View {
        VStack(spacing: 5) {
            Text(day.date, format: .dateTime.weekday(.narrow))
                .font(.caption)
                .foregroundStyle(day.isToday ? theme.accent : theme.textTertiary)
            ZStack {
                Circle()
                    .fill(fill(for: day))
                    .strokeBorder(stroke(for: day.status), lineWidth: 1)
                    .frame(width: 36, height: 36)
                if day.isToday {
                    Circle()
                        .stroke(theme.accent, lineWidth: 2)
                        .frame(width: 42, height: 42)
                        .accessibilityHidden(true)
                }
                if !day.routineMarkers.isEmpty {
                    Text(day.routineMarkers.joined(separator: "·"))
                        .font(.caption.bold())
                        .foregroundStyle(foreground(for: day))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 3)
                        .accessibilityHidden(true)
                } else if let icon = icon(for: day.status) {
                    Image(systemName: icon)
                        .font(.caption.bold())
                        .foregroundStyle(foreground(for: day))
                        .accessibilityHidden(true)
                } else {
                    Text("\(day.index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(foreground(for: day))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    private func fill(for day: MicrocycleDayPresentation) -> Color {
        switch day.status {
        case .trained: theme.accent
        case .rest: theme.surfaceElevated
        case .empty: day.isToday ? theme.accent.opacity(0.12) : theme.background
        }
    }

    private func stroke(for status: MicrocycleDayStatus) -> Color {
        switch status {
        case .trained: theme.accent
        case .rest: theme.textSecondary
        case .empty: theme.separator
        }
    }

    private func foreground(for day: MicrocycleDayPresentation) -> Color {
        switch day.status {
        case .trained: theme.background
        case .rest: theme.textSecondary
        case .empty: day.isToday ? theme.accent : theme.textTertiary
        }
    }

    private func icon(for status: MicrocycleDayStatus) -> String? {
        switch status {
        case .trained: "checkmark"
        case .rest: "moon.zzz.fill"
        case .empty: nil
        }
    }

    private func accessibilityLabel(for day: MicrocycleDayPresentation) -> String {
        let state = switch day.status {
        case .trained where day.routineMarkers.count == 1:
            "routine \(day.routineMarkers[0]) completed"
        case .trained where !day.routineMarkers.isEmpty:
            "routines \(day.routineMarkers.joined(separator: ", ")) completed"
        case .trained:
            "training completed"
        case .rest: "rest day"
        case .empty: "not logged"
        }
        let today = day.isToday ? ", today" : ""
        return "Day \(day.index + 1), \(day.date.formatted(date: .abbreviated, time: .omitted))\(today), \(state)"
    }

    private func accessibilityHint(for status: MicrocycleDayStatus) -> String {
        switch status {
        case .trained:
            "Shows the workout for this day."
        case .rest:
            "Shows the rest day and available workout options."
        case .empty:
            "Shows the logging options for this day."
        }
    }
}
