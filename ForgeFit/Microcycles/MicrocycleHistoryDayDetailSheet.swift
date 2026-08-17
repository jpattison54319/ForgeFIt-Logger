import ForgeCore
import ForgeData
import SwiftUI

struct MicrocycleHistoryDayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let date: Date
    let tracking: MicrocycleTrackingModel
    let window: MicrocycleWindowModel
    let windows: [MicrocycleWindowModel]
    let workouts: [WorkoutModel]
    let restDays: [RestDayModel]
    let exercises: [ExerciseLibraryModel]

    private var analytics: TrainingAnalytics {
        TrainingAnalytics(workouts: workouts, exercises: exercises)
    }

    private var calendar: Calendar {
        (try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        )) ?? .current
    }

    private var selectedDay: Date {
        calendar.startOfDay(for: date)
    }

    private var dayWorkouts: [MicrocycleHistoryDayWorkout] {
        MicrocycleHistoryPresentation.dayWorkouts(
            on: selectedDay,
            tracking: tracking,
            window: window,
            windows: windows,
            workouts: workouts
        )
    }

    private var hasRestDay: Bool {
        let asOf = MicrocycleHistoryPresentation.cutoff(for: tracking)
        return restDays.contains {
            $0.deletedAt == nil
                && $0.createdAt <= asOf
                && calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if dayWorkouts.isEmpty {
                        if hasRestDay {
                            Card {
                                Label("Rest day", systemImage: "moon.zzz.fill")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                            }
                        } else {
                            ContentUnavailableView(
                                "Nothing Logged",
                                systemImage: "calendar",
                                description: Text("No workout or rest day was recorded.")
                            )
                        }
                    } else {
                        Text(dayWorkouts.count == 1 ? "Workout" : "Workouts")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        ForEach(dayWorkouts) { record in
                            MicrocycleHistoryWorkoutCard(
                                record: record,
                                analytics: analytics
                            )
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle(
                selectedDay.formatted(
                    .dateTime.weekday(.wide).month(.abbreviated).day()
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .navigationDestination(for: UUID.self) { workoutID in
                if let workout = workouts.first(where: { $0.id == workoutID }) {
                    WorkoutDetailView(
                        workout: workout,
                        exercises: exercises,
                        history: workouts
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
