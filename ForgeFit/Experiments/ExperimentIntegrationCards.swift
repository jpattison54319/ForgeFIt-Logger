import ForgeData
import SwiftData
import SwiftUI

/// Query-backed Home integration so Home does not need to own experiment
/// persistence state. It draws nothing when no experiment is active.
struct ExperimentsHomeCard: View {
    let onOpen: (ExperimentModel) -> Void

    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \ExperimentTrackerModel.position) private var trackers: [ExperimentTrackerModel]
    @Query(sort: \ExperimentEntryModel.observedAt, order: .reverse) private var entries: [ExperimentEntryModel]

    @State private var showingLog = false

    private var active: ExperimentModel? {
        experiments.first {
            $0.deletedAt == nil && $0.isActive && $0.plannedEndAt > .now
        }
    }

    var body: some View {
        if let active {
            let experimentTrackers = trackers.filter {
                $0.experimentID == active.id && $0.deletedAt == nil && $0.archivedAt == nil
            }
            let experimentEntries = entries.filter {
                $0.experimentID == active.id && $0.deletedAt == nil
            }
            ActiveExperimentHomeCard(
                experiment: active,
                trackers: experimentTrackers,
                entries: experimentEntries,
                onLogUpdate: { showingLog = true },
                onOpen: { onOpen(active) }
            )
            .sheet(isPresented: $showingLog) {
                ExperimentLogUpdateSheet(
                    experiment: active,
                    trackers: experimentTrackers,
                    entries: experimentEntries
                )
            }
        }
    }
}

/// Post-workout action-area integration. A visible Log Update button appears
/// only when the active experiment has at least one per-workout tracker that
/// has not been answered for this workout.
struct ExperimentPostWorkoutTrackerPrompt: View {
    @Environment(\.theme) private var theme
    let workout: WorkoutModel

    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \ExperimentTrackerModel.position) private var trackers: [ExperimentTrackerModel]
    @Query(sort: \ExperimentEntryModel.observedAt, order: .reverse) private var entries: [ExperimentEntryModel]

    @State private var showingLog = false

    private var active: ExperimentModel? {
        experiments.first {
            $0.deletedAt == nil
                && $0.contains(workout.startedAt, asOf: .distantFuture)
        }
    }

    private var dueTrackers: [ExperimentTrackerModel] {
        guard let active else { return [] }
        return trackers.filter { tracker in
            tracker.experimentID == active.id
                && tracker.deletedAt == nil
                && tracker.cadence == .perWorkout
                && workout.startedAt >= tracker.createdAt
                && workout.startedAt < (
                    tracker.archivedAt
                        ?? active.endedAt
                        ?? active.plannedEndAt
                )
                && !entries.contains {
                    $0.deletedAt == nil
                        && $0.trackerID == tracker.id
                        && $0.workoutID == workout.id
                }
        }
    }

    var body: some View {
        if let active, !dueTrackers.isEmpty {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(theme.accentForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("\(dueTrackers.count) after-workout update\(dueTrackers.count == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button("Log Update") {
                        showingLog = true
                    }
                    .font(.bodyStrong)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("experiment-post-workout-log")
                }
            }
            .sheet(isPresented: $showingLog) {
                ExperimentLogUpdateSheet(
                    experiment: active,
                    trackers: dueTrackers,
                    entries: entries.filter {
                        $0.experimentID == active.id && $0.deletedAt == nil
                    },
                    workoutID: workout.id,
                    initialDate: workout.startedAt
                )
            }
        }
    }
}
