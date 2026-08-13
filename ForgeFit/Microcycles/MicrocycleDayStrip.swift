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
            GeometryReader { proxy in
                let markerWidth = compactMarkerWidth(availableWidth: proxy.size.width)
                let targetWidth = max(TouchTarget.minimum, markerWidth)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: compactTargetSpacing(availableWidth: proxy.size.width, targetWidth: targetWidth)) {
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
                                    .frame(width: markerWidth, height: day.isToday ? 10 : 8)
                                    .frame(width: targetWidth, height: TouchTarget.minimum)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: day))
                            .accessibilityHint(accessibilityHint(for: day.status))
                        }
                    }
                }
            }
            .frame(height: TouchTarget.minimum)
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

    /// Keep the existing compact markers visually the same size. When a long
    /// cycle would squeeze their separate hit regions below 44 points, only
    /// the clear spacing grows and the strip scrolls horizontally.
    private func compactMarkerWidth(availableWidth: CGFloat) -> CGFloat {
        let count = max(days.count, 1)
        let spacing: CGFloat = days.count > 14 ? 2 : Space.xs
        return max(2, (availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func compactTargetSpacing(availableWidth: CGFloat, targetWidth: CGFloat) -> CGFloat {
        guard days.count > 1 else { return 0 }
        return max(0, (availableWidth - targetWidth * CGFloat(days.count)) / CGFloat(days.count - 1))
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
