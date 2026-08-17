import ForgeData
import SwiftData
import SwiftUI

/// Compact Insights entry. Navigation stays at the call site so the card can
/// participate in the parent tab's typed route system.
struct ExperimentsEntryCard: View {
    @Environment(\.theme) private var theme
    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query private var trackers: [ExperimentTrackerModel]
    @Query private var entries: [ExperimentEntryModel]

    private var liveExperiments: [ExperimentModel] {
        experiments.filter { $0.deletedAt == nil }
    }

    private var active: ExperimentModel? {
        liveExperiments.first { $0.isActive && $0.plannedEndAt > .now }
    }

    private var completedCount: Int {
        liveExperiments.count { !$0.isActive || $0.plannedEndAt <= .now }
    }

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: "flask.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Experiments")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    if let active {
                        Text(activeSubtitle(active))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else if completedCount > 0 {
                        Text("\(completedCount) completed experiment\(completedCount == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Text("Run a personal experiment")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experiment-insights-entry")
    }

    private func activeSubtitle(_ experiment: ExperimentModel) -> String {
        let activeTrackers = trackers.filter {
            $0.experimentID == experiment.id && $0.deletedAt == nil && $0.archivedAt == nil
        }
        let activeEntries = entries.filter {
            $0.experimentID == experiment.id && $0.deletedAt == nil
        }
        let due = activeTrackers.filter {
            ExperimentTrackerSchedule.isDue(
                $0,
                on: .now,
                calendar: experiment.experimentCalendar
            )
                && !ExperimentTrackerSchedule.hasEntry(
                    for: $0,
                    on: .now,
                    entries: activeEntries,
                    calendar: experiment.experimentCalendar
                )
        }.count
        let day = Date.now.experimentDayNumber(
            since: experiment.startedAt,
            calendar: experiment.experimentCalendar
        )
        return due > 0
            ? "\(experiment.name) · \(due) update\(due == 1 ? "" : "s") due"
            : "\(experiment.name) · Day \(day)"
    }
}

/// Home's compact active state. Log and detail are separate visible controls;
/// neither depends on tapping an unlabeled card or discovering a gesture.
struct ActiveExperimentHomeCard: View {
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let onLogUpdate: () -> Void
    let onOpen: () -> Void

    private var progress: Double {
        let total = experiment.plannedEndAt.timeIntervalSince(experiment.startedAt)
        guard total > 0 else { return 1 }
        return min(max(Date.now.timeIntervalSince(experiment.startedAt) / total, 0), 1)
    }

    private var dueCount: Int {
        trackers.count {
            $0.experimentID == experiment.id
                && $0.deletedAt == nil
                && $0.archivedAt == nil
                && ExperimentTrackerSchedule.isDue(
                    $0,
                    on: .now,
                    calendar: experiment.experimentCalendar
                )
                && !ExperimentTrackerSchedule.hasEntry(
                    for: $0,
                    on: .now,
                    entries: entries,
                    calendar: experiment.experimentCalendar
                )
        }
    }

    private var hasDirectlyLoggableTracker: Bool {
        trackers.contains {
            guard $0.experimentID == experiment.id,
                  $0.deletedAt == nil,
                  $0.archivedAt == nil else {
                return false
            }
            switch $0.cadence {
            case .daily, .anytime:
                return true
            case .selectedWeekdays:
                return ExperimentTrackerSchedule.isDue(
                    $0,
                    on: .now,
                    calendar: experiment.experimentCalendar
                )
            case .perWorkout:
                return false
            }
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(experiment.name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Day \(Date.now.experimentDayNumber(since: experiment.startedAt, calendar: experiment.experimentCalendar))")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button("Details", action: onOpen)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("experiment-home-details")
                }

                ProgressView(value: progress)
                    .tint(theme.accent)
                    .accessibilityLabel("Experiment progress")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))

                HStack {
                    Text(dueCount == 0 ? "Today complete" : "\(dueCount) update\(dueCount == 1 ? "" : "s") due")
                        .font(.system(size: 13))
                        .foregroundStyle(dueCount == 0 ? theme.success : theme.textSecondary)
                    Spacer()
                    if hasDirectlyLoggableTracker {
                        Button("Log Update", systemImage: "plus.circle.fill", action: onLogUpdate)
                            .font(.bodyStrong)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("experiment-home-log-update")
                    }
                }
            }
        }
        .accessibilityIdentifier("experiment-home-card")
    }
}

/// Full experiment library: one active experiment, completed history, and
/// visible create/compare actions.
struct ExperimentsHubView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    var initialResultsExperimentID: UUID? = nil
    var onExport: (ExperimentModel) -> Void = { _ in }

    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \ExperimentTrackerModel.position) private var trackers: [ExperimentTrackerModel]
    @Query(sort: \ExperimentEntryModel.observedAt, order: .reverse) private var entries: [ExperimentEntryModel]

    @State private var showingSetup = false
    @State private var showingInitialResults = false
    @State private var persistError: String?
    @State private var performanceGate = LiveWorkoutPerformanceGate.shared

    private var liveExperiments: [ExperimentModel] {
        experiments.filter { $0.deletedAt == nil }
    }

    private var active: ExperimentModel? {
        liveExperiments.first { $0.isActive && $0.plannedEndAt > .now }
    }

    private var completed: [ExperimentModel] {
        liveExperiments.filter { !$0.isActive || $0.plannedEndAt <= .now }
    }

    private var hasActiveWorkout: Bool {
        workouts.contains { $0.deletedAt == nil && $0.endedAt == nil }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let active {
                    NavigationLink {
                        detailView(for: active)
                    } label: {
                        ExperimentActiveLibraryCard(
                            experiment: active,
                            trackers: trackersFor(active),
                            entries: entriesFor(active)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("experiment-open-active")
                } else {
                    PrimaryButton(title: "New Experiment", systemImage: "plus") {
                        showingSetup = true
                    }
                    .accessibilityIdentifier("experiment-new")
                }

                if active != nil {
                    Card(padding: Space.md) {
                        HStack {
                            Label("New Experiment", systemImage: "plus")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text("Available when this one ends")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .frame(minHeight: 52)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "New experiment unavailable. Finish or discard the active experiment first."
                    )
                    .accessibilityIdentifier("experiment-new-disabled")
                }

                completedSection
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
                .background(theme.background)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSetup) {
            ExperimentSetupView(hasActiveWorkout: hasActiveWorkout) { draft in
                _ = try ExperimentUIStore.start(draft: draft, in: modelContext)
            }
        }
        .alert("Experiment couldn’t be saved", isPresented: Binding(
            get: { persistError != nil },
            set: { if !$0 { persistError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(persistError ?? "")
        }
        .task(id: performanceGate.isLiveWorkoutActive) {
            guard performanceGate.allowsNonWorkoutWork else { return }
            do {
                _ = try ExperimentLifecycleService.reconcileIsolated(from: modelContext)
                if initialResultsExperiment != nil {
                    showingInitialResults = true
                }
            } catch {
                persistError = error.localizedDescription
            }
        }
        .navigationDestination(isPresented: $showingInitialResults) {
            if let experiment = initialResultsExperiment {
                ExperimentResultsView(
                    experiment: experiment,
                    trackers: trackersFor(experiment),
                    entries: entriesFor(experiment),
                    workouts: workouts,
                    exercises: exercises,
                    comparisonExperiments: completed.filter {
                        $0.id != experiment.id
                    },
                    comparisonTrackers: trackers.filter {
                        $0.experimentID != experiment.id && $0.deletedAt == nil
                    },
                    comparisonEntries: entries.filter {
                        $0.experimentID != experiment.id && $0.deletedAt == nil
                    },
                    onExport: { onExport(experiment) }
                )
            }
        }
        .interactiveBackSwipeEnabled()
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                .accessibilityIdentifier("experiment-hub-back")
            Spacer()
            Text("Experiments")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if active == nil {
                CircleIconButton(systemImage: "plus", label: "New experiment") {
                    showingSetup = true
                }
                .accessibilityIdentifier("experiment-hub-new")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.sm)
    }

    @ViewBuilder
    private var completedSection: some View {
        if completed.isEmpty {
            EmptyStateCard(
                title: "No completed experiments",
                message: active == nil
                    ? "Your finished experiments and comparisons will appear here."
                    : "Results will appear here when the active experiment ends.",
                systemImage: "chart.bar.doc.horizontal"
            )
        } else {
            SectionHeader("Completed") {
                if completed.count >= 2 {
                    NavigationLink {
                        ExperimentLibraryComparisonView(
                            experiments: completed,
                            workouts: workouts,
                            exercises: exercises,
                            trackers: trackers,
                            entries: entries,
                            onExport: onExport
                        )
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                            .font(.bodyStrong)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("experiment-compare-library")
                }
            }

            ForEach(completed, id: \.id) { experiment in
                NavigationLink {
                    detailView(for: experiment)
                } label: {
                    ExperimentCompletedLibraryCard(
                        experiment: experiment,
                        workouts: workouts,
                        trackers: trackersFor(experiment),
                        entries: entriesFor(experiment)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("experiment-open-completed-\(experiment.id.uuidString)")
            }
        }
    }

    private func trackersFor(_ experiment: ExperimentModel) -> [ExperimentTrackerModel] {
        trackers.filter {
            $0.experimentID == experiment.id && $0.deletedAt == nil
        }
    }

    private func entriesFor(_ experiment: ExperimentModel) -> [ExperimentEntryModel] {
        entries.filter {
            $0.experimentID == experiment.id && $0.deletedAt == nil
        }
    }

    private var initialResultsExperiment: ExperimentModel? {
        guard let initialResultsExperimentID else { return nil }
        return liveExperiments.first { $0.id == initialResultsExperimentID }
    }

    private func detailView(for experiment: ExperimentModel) -> some View {
        ExperimentDetailView(
            experiment: experiment,
            trackers: trackersFor(experiment),
            entries: entriesFor(experiment),
            workouts: workouts,
            exercises: exercises,
            comparisonExperiments: completed.filter { $0.id != experiment.id },
            comparisonTrackers: trackers.filter {
                $0.experimentID != experiment.id && $0.deletedAt == nil
            },
            comparisonEntries: entries.filter {
                $0.experimentID != experiment.id && $0.deletedAt == nil
            },
            onExport: { onExport(experiment) }
        )
    }
}

private struct ExperimentActiveLibraryCard: View {
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]

    private var progress: Double {
        let duration = experiment.plannedEndAt.timeIntervalSince(experiment.startedAt)
        guard duration > 0 else { return 1 }
        return min(max(Date.now.timeIntervalSince(experiment.startedAt) / duration, 0), 1)
    }

    private var dueCount: Int {
        trackers.count {
            $0.archivedAt == nil
                && ExperimentTrackerSchedule.isDue(
                    $0,
                    on: .now,
                    calendar: experiment.experimentCalendar
                )
                && !ExperimentTrackerSchedule.hasEntry(
                    for: $0,
                    on: .now,
                    entries: entries,
                    calendar: experiment.experimentCalendar
                )
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Tag(text: "ACTIVE", color: theme.accent, background: theme.accentSoft)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(theme.accent)
                }
                Text(experiment.name)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                HStack {
                    Text("Day \(Date.now.experimentDayNumber(since: experiment.startedAt, calendar: experiment.experimentCalendar))")
                    Spacer()
                    Text(experiment.plannedEndAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                ProgressView(value: progress)
                    .tint(theme.accent)
                    .accessibilityLabel("Experiment progress")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                Text(dueCount == 0 ? "Today complete" : "\(dueCount) update\(dueCount == 1 ? "" : "s") due")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dueCount == 0 ? theme.success : theme.textSecondary)
            }
        }
    }
}

private struct ExperimentCompletedLibraryCard: View {
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let workouts: [WorkoutModel]
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]

    private var end: Date {
        experiment.endedAt ?? experiment.plannedEndAt
    }

    private var includedWorkouts: Int {
        workouts.count {
            $0.deletedAt == nil && $0.endedAt != nil
                && $0.startedAt >= experiment.startedAt && $0.startedAt < end
        }
    }

    private var customCoverageText: String {
        let scheduledTrackers = trackers.filter { $0.cadence != .anytime }
        let scheduled = scheduledTrackers.compactMap { tracker -> Int? in
            let trackerStart = max(experiment.startedAt, tracker.createdAt)
            let trackerEnd = min(end, tracker.archivedAt ?? end)
            guard trackerStart < trackerEnd else { return nil }
            return ExperimentTrackerSchedule.expectedOccurrences(
                for: tracker,
                start: trackerStart,
                end: trackerEnd,
                workouts: workouts,
                calendar: experiment.experimentCalendar
            )
        }.reduce(0, +)
        guard scheduled > 0 else {
            return entries.isEmpty ? "No custom entries" : "\(entries.count) custom entries"
        }
        let scheduledTrackerIDs = Set(scheduledTrackers.map(\.id))
        let recorded = entries.count { scheduledTrackerIDs.contains($0.trackerID) }
        let percent = min(Double(recorded) / Double(scheduled), 1)
        return "\(percent.formatted(.percent.precision(.fractionLength(0)))) tracker coverage"
    }

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(experiment.name)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("\(experiment.startedAt.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Text("\(includedWorkouts) workout\(includedWorkouts == 1 ? "" : "s") · \(customCoverageText)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if experiment.resultsViewedAt == nil {
                    Tag(text: "NEW")
                        .accessibilityLabel("New results")
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.accent)
            }
        }
    }
}
