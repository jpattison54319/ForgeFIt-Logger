import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct MicrocycleHistoryWindowDetailView: View {
    @Environment(\.theme) private var theme

    let trackingID: UUID
    let windowID: UUID
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var trackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var windows: [MicrocycleWindowModel]
    @Query(sort: \RestDayModel.date, order: .reverse)
    private var restDays: [RestDayModel]

    @State private var selectedDay: MicrocycleDaySelection?

    private var tracking: MicrocycleTrackingModel? {
        trackings.first { $0.id == trackingID && $0.deletedAt == nil }
    }

    private var window: MicrocycleWindowModel? {
        windows.first {
            $0.id == windowID && $0.trackingID == trackingID && $0.deletedAt == nil
        }
    }

    private var trackingWindows: [MicrocycleWindowModel] {
        windows.filter { $0.trackingID == trackingID && $0.deletedAt == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let tracking, let window,
                   let presentation = MicrocycleHistoryPresentation.windowPresentation(
                       tracking: tracking,
                       window: window,
                       windows: trackingWindows,
                       workouts: workouts
                   ) {
                    MicrocycleHistorySummaryCard(
                        tracking: tracking,
                        window: window,
                        presentation: presentation,
                        days: MicrocycleHistoryPresentation.days(
                            tracking: tracking,
                            window: window,
                            windows: trackingWindows,
                            workouts: workouts,
                            restDays: restDays
                        ),
                        workouts: workouts,
                        restDays: restDays,
                        onSelectDay: selectDay
                    )
                    MicrocycleHistoryRoutineCard(progress: presentation.progress)
                } else {
                    ContentUnavailableView(
                        "Cycle Unavailable",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("This tracked cycle is no longer available.")
                    )
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle(window.map { "Cycle \($0.index + 1)" } ?? "Cycle")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedDay) { selection in
            if let tracking, let window {
                MicrocycleHistoryDayDetailSheet(
                    date: selection.date,
                    tracking: tracking,
                    window: window,
                    windows: trackingWindows,
                    workouts: workouts,
                    restDays: restDays,
                    exercises: exercises
                )
            }
        }
    }

    private func selectDay(_ date: Date) {
        selectedDay = MicrocycleDaySelection(date: date)
    }
}
