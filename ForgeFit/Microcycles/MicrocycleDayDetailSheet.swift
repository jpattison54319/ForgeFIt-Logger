import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct MicrocycleDayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let date: Date
    let window: MicrocycleWindowModel
    let windows: [MicrocycleWindowModel]
    let workouts: [WorkoutModel]
    let restDays: [RestDayModel]
    let exercises: [ExerciseLibraryModel]

    @State private var errorMessage = ""
    @State private var showingError = false

    private var analytics: TrainingAnalytics {
        TrainingAnalytics(workouts: workouts, exercises: exercises)
    }

    private var calendar: Calendar {
        (try? MicrocycleEngine.calendar(timeZoneIdentifier: window.timeZoneIdentifier)) ?? .current
    }

    private var selectedDay: Date { calendar.startOfDay(for: date) }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var dayWorkouts: [MicrocycleDayAssignmentService.DayWorkout] {
        MicrocycleDayAssignmentService.dayWorkouts(
            on: selectedDay,
            in: window,
            workouts: workouts
        )
    }

    private var restDay: RestDayModel? {
        restDays.first {
            $0.deletedAt == nil && calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    private var eligibleWorkouts: [WorkoutModel] {
        MicrocycleDayAssignmentService.eligibleWorkouts(
            for: selectedDay,
            in: window,
            windows: windows,
            workouts: workouts
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if dayWorkouts.isEmpty {
                        if let restDay {
                            Card {
                                HStack(spacing: Space.md) {
                                    Image(systemName: "moon.zzz.fill")
                                        .font(.title3)
                                        .foregroundStyle(theme.accent)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Rest day")
                                            .font(.bodyStrong)
                                            .foregroundStyle(theme.textPrimary)
                                        Text("Choosing a workout below replaces this rest day.")
                                            .font(.subheadline)
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                    Spacer(minLength: Space.sm)
                                    Button("Remove", role: .destructive) {
                                        removeRestDay(restDay)
                                    }
                                    .font(.subheadline.bold())
                                    .frame(minHeight: 44)
                                }
                            }
                        } else if selectedDay > today {
                            EmptyStateCard(
                                title: "This day hasn't happened yet",
                                message: "Workout history can be added on the day or afterward.",
                                systemImage: "calendar.badge.clock"
                            )
                        } else {
                            EmptyStateCard(
                                title: "No workout on this day",
                                message: "Choose a completed workout below if it belongs in this microcycle.",
                                systemImage: "calendar.badge.plus"
                            )
                        }

                        if selectedDay <= today {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(restDay == nil ? "Add a Logged Workout" : "Replace with a Workout")
                                    .font(.sectionTitle)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Only uncounted workouts from routines still due in this cycle are shown.")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.textSecondary)

                                if eligibleWorkouts.isEmpty {
                                    EmptyStateCard(
                                        title: "No eligible workouts",
                                        message: "Complete another due routine or choose a workout that has not already counted in this tracking run.",
                                        systemImage: "checklist"
                                    )
                                } else {
                                    LazyVStack(spacing: Space.sm) {
                                        ForEach(eligibleWorkouts) { workout in
                                            MicrocycleBackfillCandidateRow(
                                                workout: workout,
                                                onSelect: { assign(workout) }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Text(dayWorkouts.count == 1 ? "Workout" : "Workouts")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)

                        ForEach(dayWorkouts) { record in
                            MicrocycleDayWorkoutCard(
                                record: record,
                                analytics: analytics,
                                onRemoveBackfill: { removeBackfill(from: record) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle(selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .navigationDestination(for: UUID.self) { workoutID in
                if let workout = workouts.first(where: { $0.id == workoutID }) {
                    WorkoutDetailView(workout: workout, exercises: exercises, history: workouts)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Couldn't Update Day", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func assign(_ workout: WorkoutModel) {
        do {
            try MicrocycleDayAssignmentService.assign(
                workout,
                to: selectedDay,
                in: window,
                windows: windows,
                workouts: workouts,
                restDays: restDays,
                context: modelContext
            )
        } catch {
            show(error)
        }
    }

    private func removeBackfill(from record: MicrocycleDayAssignmentService.DayWorkout) {
        guard let assignment = record.assignment else { return }
        do {
            try MicrocycleDayAssignmentService.remove(
                assignment,
                from: window,
                context: modelContext
            )
        } catch {
            show(error)
        }
    }

    private func removeRestDay(_ restDay: RestDayModel) {
        do {
            try RestDayService.remove(restDay, in: modelContext)
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}
