import ForgeData
import SwiftData
import SwiftUI

/// Interactive training calendar behind the Profile "Calendar" tile: a month
/// grid with per-workout day markers, tap-to-select days, and the day's
/// workouts as the same summary cards used everywhere else — drilling into
/// the standard workout detail screen.
struct WorkoutCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    private let calendar = Calendar.current
    @State private var displayedMonth = WorkoutCalendarSupport.monthStart(containing: Date(), calendar: .current)
    @State private var selectedDay = WorkoutCalendarSupport.dayKey(for: Date(), calendar: .current)
    @State private var groupMemo = Memo<String, [Date: [WorkoutModel]]>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }

    /// Completed workouts bucketed by the local day they happened on.
    private var workoutsByDay: [Date: [WorkoutModel]] {
        groupMemo(AnalyticsFingerprint.of(workouts)) {
            Dictionary(grouping: analytics.completed) {
                WorkoutCalendarSupport.dayKey(for: $0.startedAt, calendar: calendar)
            }
        }
    }

    var body: some View {
        DashboardScaffold(title: "Calendar", dismiss: dismiss) {
            Card {
                VStack(spacing: Space.md) {
                    monthHeader
                    weekdayHeader
                    monthGrid
                }
            }
            selectedDaySection
        }
        .navigationDestination(for: UUID.self) { id in
            if let w = workouts.first(where: { $0.id == id }) {
                WorkoutDetailView(workout: w, exercises: exercises, history: workouts)
            }
        }
    }

    // MARK: Month navigation

    private var monthHeader: some View {
        HStack(spacing: Space.sm) {
            monthStepButton(systemImage: "chevron.left", byMonths: -1)
            Spacer()
            VStack(spacing: 2) {
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
                if !calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month) {
                    Button("Today") { jumpToToday() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            Spacer()
            monthStepButton(systemImage: "chevron.right", byMonths: 1)
        }
    }

    private func monthStepButton(systemImage: String, byMonths: Int) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                if let next = calendar.date(byAdding: .month, value: byMonths, to: displayedMonth) {
                    displayedMonth = WorkoutCalendarSupport.monthStart(containing: next, calendar: calendar)
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(byMonths < 0 ? "Previous month" : "Next month")
    }

    private func jumpToToday() {
        withAnimation(.spring(duration: 0.25)) {
            displayedMonth = WorkoutCalendarSupport.monthStart(containing: Date(), calendar: calendar)
            selectedDay = WorkoutCalendarSupport.dayKey(for: Date(), calendar: calendar)
        }
    }

    // MARK: Grid

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(WorkoutCalendarSupport.orderedWeekdaySymbols(calendar), id: \.self) { symbol in
                Text(symbol)
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        let cells = WorkoutCalendarSupport.gridDays(forMonthContaining: displayedMonth, calendar: calendar)
        let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let key = WorkoutCalendarSupport.dayKey(for: day, calendar: calendar)
        let dayWorkouts = workoutsByDay[key] ?? []
        let isSelected = selectedDay == key
        let isToday = calendar.isDateInToday(day)
        return Button {
            withAnimation(.spring(duration: 0.25)) { selectedDay = key }
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 15, weight: isSelected || isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? theme.background : (isToday ? theme.accent : theme.textPrimary))
                // One marker per workout (capped at 3) so a double day reads
                // at a glance without getting noisy.
                HStack(spacing: 3) {
                    ForEach(Array(dayWorkouts.prefix(3).enumerated()), id: \.offset) { _, workout in
                        markerDot(for: workout, isSelected: isSelected)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(theme.accent)
                } else if isToday {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(theme.accent.opacity(0.6), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
        .accessibilityValue(dayWorkouts.isEmpty
            ? "No workouts"
            : "\(dayWorkouts.count) workout\(dayWorkouts.count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar-day")
    }

    /// Strength = accent, cardio = secondary accent, mixed = a two-tone dot.
    private func markerDot(for workout: WorkoutModel, isSelected: Bool) -> some View {
        let kind = WorkoutCalendarSupport.workoutKind(
            exerciseIDs: workout.exercises.map(\.id),
            cardioLinkedExerciseIDs: Set(workout.cardioSessions.compactMap(\.workoutExerciseID)),
            cardioSessionCount: workout.cardioSessions.count
        )
        return Circle()
            .fill(isSelected ? AnyShapeStyle(theme.background) : dotStyle(for: kind))
            .frame(width: 5, height: 5)
    }

    private func dotStyle(for kind: WorkoutCalendarSupport.WorkoutKind) -> AnyShapeStyle {
        switch kind {
        case .strength:
            AnyShapeStyle(theme.accent)
        case .cardio:
            AnyShapeStyle(theme.secondaryAccent)
        case .mixed:
            AnyShapeStyle(LinearGradient(
                colors: [theme.accent, theme.secondaryAccent],
                startPoint: .leading, endPoint: .trailing))
        }
    }

    // MARK: Selected day

    @ViewBuilder
    private var selectedDaySection: some View {
        let items = (workoutsByDay[selectedDay] ?? []).sorted { $0.startedAt < $1.startedAt }
        SectionHeader(selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        if items.isEmpty {
            EmptyStateCard(
                title: "No workouts this day",
                message: "Rest days count too.",
                systemImage: "moon.zzz"
            )
        } else {
            ForEach(items) { workout in
                NavigationLink(value: workout.id) {
                    WorkoutFeedRow(workout: workout, analytics: analytics)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
/// Days with one strength workout, a strength + cardio double, a mixed
/// session, and a workout across the previous month boundary — plus plenty
/// of empty days to tap.
@MainActor
private func calendarPreviewData(userID: UUID) -> ([WorkoutModel], [ExerciseLibraryModel]) {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let bench = ExerciseLibraryModel(name: "Bench Press", primaryMuscles: ["Chest"])
    let run = ExerciseLibraryModel(name: "Run", isCardio: true)

    func strength(daysAgo: Int, hour: Int, title: String) -> WorkoutModel {
        let start = cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: -daysAgo, to: today)!)!
        let we = WorkoutExerciseModel(userID: userID, exerciseID: bench.id, sets: [
            SetModel(userID: userID, reps: 8, weight: 80, completedAt: start.addingTimeInterval(300)),
            SetModel(userID: userID, position: 1, reps: 8, weight: 82.5, completedAt: start.addingTimeInterval(600)),
        ])
        return WorkoutModel(userID: userID, title: title, startedAt: start,
                            endedAt: start.addingTimeInterval(3600), totalVolume: 1300, exercises: [we])
    }

    func cardio(daysAgo: Int, hour: Int, title: String) -> WorkoutModel {
        let start = cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: -daysAgo, to: today)!)!
        let we = WorkoutExerciseModel(userID: userID, exerciseID: run.id)
        let session = CardioSessionModel(
            userID: userID, workoutExerciseID: we.id, modality: "run",
            startedAt: start, durationSeconds: 1800, distanceMeters: 5000, avgHR: 150)
        return WorkoutModel(userID: userID, title: title, startedAt: start,
                            endedAt: start.addingTimeInterval(1900), avgHR: 150,
                            exercises: [we], cardioSessions: [session])
    }

    // Mixed: strength exercise + linked cardio session in one workout.
    let mixedStart = cal.date(byAdding: .hour, value: 17, to: cal.date(byAdding: .day, value: -3, to: today)!)!
    let mixedBench = WorkoutExerciseModel(userID: userID, exerciseID: bench.id, sets: [
        SetModel(userID: userID, reps: 10, weight: 60, completedAt: mixedStart.addingTimeInterval(400)),
    ])
    let mixedRunWE = WorkoutExerciseModel(userID: userID, exerciseID: run.id, position: 1)
    let mixedSession = CardioSessionModel(
        userID: userID, workoutExerciseID: mixedRunWE.id, modality: "run",
        startedAt: mixedStart.addingTimeInterval(900), durationSeconds: 1200, distanceMeters: 3000, avgHR: 148)
    let mixed = WorkoutModel(userID: userID, title: "Push + Run", startedAt: mixedStart,
                             endedAt: mixedStart.addingTimeInterval(2400), totalVolume: 600,
                             exercises: [mixedBench, mixedRunWE], cardioSessions: [mixedSession])

    let workouts = [
        strength(daysAgo: 0, hour: 9, title: "Push Day"),
        cardio(daysAgo: 0, hour: 18, title: "Evening Run"),
        mixed,
        strength(daysAgo: 6, hour: 8, title: "Leg Day"),
        cardio(daysAgo: 34, hour: 7, title: "Long Run"),
    ]
    return (workouts, [bench, run])
}

#Preview("Workout calendar") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Schema(ForgeDataSchema.models), configurations: config)
    let (workouts, exercises) = calendarPreviewData(userID: UUID())
    workouts.forEach { container.mainContext.insert($0) }
    exercises.forEach { container.mainContext.insert($0) }
    return NavigationStack {
        WorkoutCalendarView(workouts: workouts, exercises: exercises)
    }
    .modelContainer(container)
}

#Preview("Empty calendar") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Schema(ForgeDataSchema.models), configurations: config)
    return NavigationStack {
        WorkoutCalendarView(workouts: [], exercises: [])
    }
    .modelContainer(container)
}
#endif
