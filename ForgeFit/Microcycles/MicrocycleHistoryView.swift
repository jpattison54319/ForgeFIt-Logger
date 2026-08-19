import ForgeData
import SwiftData
import SwiftUI

struct MicrocycleHistoryView: View {
    @Environment(\.theme) private var theme

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var trackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var windows: [MicrocycleWindowModel]

    var body: some View {
        let runs = MicrocycleHistoryPresentation.runs(
            trackings: trackings,
            windows: windows,
            workouts: workouts
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                if runs.isEmpty {
                    ContentUnavailableView(
                        "No Microcycle History",
                        systemImage: "calendar.badge.clock",
                        description: Text("Tracked cycles will appear here.")
                    )
                } else {
                    ForEach(runs) { run in
                        MicrocycleHistoryRunCard(run: run)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle("Microcycle History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MicrocycleHistoryRoute.self) { route in
            switch route {
            case .window(let trackingID, let windowID):
                MicrocycleHistoryWindowDetailView(
                    trackingID: trackingID,
                    windowID: windowID,
                    workouts: workouts,
                    exercises: exercises
                )
            }
        }
    }
}
