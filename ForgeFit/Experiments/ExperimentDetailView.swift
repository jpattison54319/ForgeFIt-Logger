import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

struct ExperimentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let comparisonExperiments: [ExperimentModel]
    let comparisonTrackers: [ExperimentTrackerModel]
    let comparisonEntries: [ExperimentEntryModel]
    let onExport: () -> Void

    @State private var showingLog = false
    @State private var showingBackfill = false
    @State private var showingManage = false
    @State private var showingEntryHistory = false
    @State private var showingFullTimeline = false

    private var end: Date {
        experiment.observationEnd()
    }

    private var activeTrackers: [ExperimentTrackerModel] {
        trackers.filter { $0.deletedAt == nil && $0.archivedAt == nil }
    }

    private var directlyLoggableTrackers: [ExperimentTrackerModel] {
        activeTrackers.filter {
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

    private var dueCount: Int {
        activeTrackers.count {
            ExperimentTrackerSchedule.isDue(
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

    private var rollup: ExperimentTrainingRollup {
        ExperimentTrainingRollup.make(
            workouts: workouts,
            exercises: exercises,
            start: experiment.startedAt,
            end: end,
            calendar: experiment.experimentCalendar
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                experimentSummary

                if experiment.isActive {
                    if !directlyLoggableTrackers.isEmpty {
                        PrimaryButton(title: "Log Update", systemImage: "plus.circle.fill") {
                            showingLog = true
                        }
                        .accessibilityIdentifier("experiment-detail-log-update")
                    }
                    customEntryActions(addTitle: "Add Past Entry")
                    automaticDataCard
                    timelineSection
                    NavigationLink {
                        resultsView
                    } label: {
                        Card(padding: Space.md) {
                            HStack {
                                Label("Progress So Far", systemImage: "chart.xyaxis.line")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.accentForeground)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("experiment-progress-so-far")
                } else {
                    NavigationLink {
                        resultsView
                    } label: {
                        Card {
                            HStack(spacing: Space.md) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(theme.accentForeground)
                                    .frame(width: 42, height: 42)
                                    .background(theme.surfaceElevated)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("View Results")
                                        .font(.cardTitle)
                                        .foregroundStyle(theme.textPrimary)
                                    Text("Compare periods or completed experiments")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.accentForeground)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("experiment-view-results")
                    completedEntryActions
                    timelineSection
                }
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
        .sheet(isPresented: $showingLog) {
            ExperimentLogUpdateSheet(
                experiment: experiment,
                trackers: experiment.isActive
                    ? directlyLoggableTrackers
                    : trackers.filter { $0.deletedAt == nil },
                entries: entries,
                workouts: workouts,
                initialDate: experiment.isActive
                    ? .now
                    : max(experiment.startedAt, end.addingTimeInterval(-1)),
                isBackfill: !experiment.isActive
            )
        }
        .sheet(isPresented: $showingEntryHistory) {
            ExperimentEntryHistorySheet(
                experiment: experiment,
                trackers: trackers,
                entries: entries,
                workouts: workouts
            )
        }
        .sheet(isPresented: $showingBackfill) {
            ExperimentLogUpdateSheet(
                experiment: experiment,
                trackers: trackers.filter { $0.deletedAt == nil },
                entries: entries,
                workouts: workouts,
                initialDate: experiment.isActive
                    ? .now
                    : max(experiment.startedAt, end.addingTimeInterval(-1)),
                isBackfill: true
            )
        }
        .sheet(isPresented: $showingManage) {
            ExperimentManageSheet(
                experiment: experiment,
                trackers: trackers,
                entries: entries
            ) {
                dismiss()
            }
        }
        .sheet(isPresented: $showingFullTimeline) {
            ExperimentFullTimelineView(items: timelineItems)
        }
        .interactiveBackSwipeEnabled()
    }

    @ViewBuilder
    private var completedEntryActions: some View {
        customEntryActions(addTitle: "Add Entry")
    }

    @ViewBuilder
    private func customEntryActions(addTitle: String) -> some View {
        let availableTrackers = trackers.filter { $0.deletedAt == nil }
        let liveEntries = entries.filter { $0.deletedAt == nil }
        if !availableTrackers.isEmpty {
            HStack(spacing: Space.md) {
                SecondaryButton(title: addTitle, systemImage: "calendar.badge.plus") {
                    showingBackfill = true
                }
                .accessibilityIdentifier("experiment-add-past-entry")
                if !liveEntries.isEmpty {
                    SecondaryButton(title: "Edit Entries", systemImage: "pencil") {
                        showingEntryHistory = true
                    }
                    .accessibilityIdentifier("experiment-edit-entries")
                }
            }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                .accessibilityIdentifier("experiment-detail-back")
            Spacer()
            Text(experiment.isActive ? "Active Experiment" : "Experiment")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            CircleIconButton(systemImage: "ellipsis", label: "Manage experiment") {
                showingManage = true
            }
            .accessibilityIdentifier("experiment-manage")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.sm)
    }

    private var experimentSummary: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(experiment.name)
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Tag(
                    text: experiment.isActive ? "ACTIVE" : "COMPLETE",
                    color: experiment.isActive ? theme.accent : theme.textSecondary,
                    background: experiment.isActive ? theme.accentSoft : theme.surfaceElevated
                )
            }
            if let protocolDescription = experiment.protocolDescription {
                Text(protocolDescription)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let question = experiment.question {
                Card(padding: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QUESTION")
                            .font(.tag)
                            .foregroundStyle(theme.textTertiary)
                        Text(question)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }

            if experiment.isActive {
                let duration = experiment.plannedEndAt.timeIntervalSince(experiment.startedAt)
                let progress = duration > 0
                    ? min(max(Date.now.timeIntervalSince(experiment.startedAt) / duration, 0), 1)
                    : 1
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Day \(Date.now.experimentDayNumber(since: experiment.startedAt, calendar: experiment.experimentCalendar))")
                                    .font(.cardTitle)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Ends \(experiment.plannedEndAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Text(
                                dueCount == 0
                                    ? "Today complete"
                                    : "\(dueCount) update\(dueCount == 1 ? "" : "s") due"
                            )
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(dueCount == 0 ? theme.success : theme.textSecondary)
                        }
                        ProgressView(value: progress)
                            .tint(theme.accent)
                            .accessibilityLabel("Experiment progress")
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
            } else {
                Text("\(experiment.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var automaticDataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Text("Automatic Data")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if HealthMetricsStore.shared.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing Health data")
                    }
                }
                HStack(spacing: Space.md) {
                    StatColumn(label: "Workouts", value: "\(rollup.workouts)")
                    StatColumn(label: "Cardio", value: "\(rollup.cardioSessions)")
                    StatColumn(label: "Yoga", value: "\(rollup.yogaSessions)")
                }
                let completeHealthDays = HealthMetricsStore.shared.metrics.count {
                    guard let day = experiment.experimentCalendar.dateInterval(
                        of: .day,
                        for: $0.date
                    ) else {
                        return false
                    }
                    return day.start >= experiment.startedAt && day.end <= end
                }
                Label(
                    HealthService.shared.isConnected
                        ? "\(completeHealthDays) recent complete Health day\(completeHealthDays == 1 ? "" : "s") loaded"
                        : "Apple Health not connected",
                    systemImage: "heart.text.square"
                )
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                Text("Results loads the exact experiment and comparison windows from Apple Health.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        SectionHeader("Timeline")
        let items = timelineItems
        if items.isEmpty {
            EmptyStateCard(
                title: "No activity yet",
                message: "Completed workouts and custom entries in this experiment will appear here.",
                systemImage: "clock"
            )
        } else {
            Card {
                VStack(spacing: Space.md) {
                    ForEach(Array(items.prefix(12).enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().overlay(theme.separator)
                        }
                        HStack(alignment: .top, spacing: Space.md) {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(theme.accentForeground)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text(item.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                        }
                    }
                    if items.count > 12 {
                        Divider().overlay(theme.separator)
                        Button {
                            showingFullTimeline = true
                        } label: {
                            Label(
                                "View Full Timeline (\(items.count))",
                                systemImage: "list.bullet"
                            )
                            .font(.bodyStrong)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentForeground)
                        .accessibilityIdentifier("experiment-full-timeline")
                    }
                }
            }
        }
    }

    private var timelineItems: [ExperimentTimelineItem] {
        let workoutItems = workouts.compactMap { workout -> ExperimentTimelineItem? in
            guard workout.deletedAt == nil,
                  workout.endedAt != nil,
                  workout.startedAt >= experiment.startedAt,
                  workout.startedAt < end else { return nil }
            let summary = ExperimentWorkoutSummaryPresentation.make(
                workout: workout,
                exercises: exercises
            )
            return ExperimentTimelineItem(
                id: "workout-\(workout.id)",
                date: workout.startedAt,
                title: workout.title ?? "Workout",
                detail: summary.detail,
                systemImage: summary.systemImage
            )
        }
        let entryItems = entries.compactMap { entry -> ExperimentTimelineItem? in
            guard entry.deletedAt == nil,
                  let value = entry.value else { return nil }
            let tracker = trackers.first { $0.id == entry.trackerID }
            let snapshot = entry.experimentDefinitionSnapshot
            return ExperimentTimelineItem(
                id: "entry-\(entry.id)",
                date: entry.observedAt,
                title: snapshot?.label ?? tracker?.label ?? "Archived tracker",
                detail: value.experimentDisplayText(unit: snapshot?.unit ?? tracker?.unit),
                systemImage: snapshot?.type.experimentSystemImage
                    ?? tracker?.type.experimentSystemImage
                    ?? "note.text"
            )
        }
        return (workoutItems + entryItems).sorted { $0.date > $1.date }
    }

    private var resultsView: some View {
        ExperimentResultsView(
            experiment: experiment,
            trackers: trackers,
            entries: entries,
            workouts: workouts,
            exercises: exercises,
            comparisonExperiments: comparisonExperiments,
            comparisonTrackers: comparisonTrackers,
            comparisonEntries: comparisonEntries,
            onExport: onExport
        )
    }
}

private struct ExperimentTimelineItem: Identifiable {
    let id: String
    let date: Date
    let title: String
    let detail: String
    let systemImage: String
}

private struct ExperimentFullTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let items: [ExperimentTimelineItem]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md) {
                    ForEach(items) { item in
                        Card(padding: Space.md) {
                            HStack(alignment: .top, spacing: Space.md) {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(theme.accentForeground)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(item.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textSecondary)
                                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Full Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ExperimentStoredTrackerDefinition: Decodable {
    let version: Int
    let label: String
    let type: ExperimentTrackerType
    let unit: String?
    let scaleMinimumLabel: String?
    let scaleMaximumLabel: String?
    let options: [String]
}

private extension ExperimentEntryModel {
    var experimentDefinitionSnapshot: ExperimentStoredTrackerDefinition? {
        guard let data = definitionSnapshotJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExperimentStoredTrackerDefinition.self, from: data)
    }
}

private struct ExperimentManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let onDeleted: () -> Void
    let originalHeadlineSelections: [ExperimentMetricSelection]

    @State private var name: String
    @State private var protocolDescription: String
    @State private var question: String
    @State private var plannedEnd: Date
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var headlineMetricIDs: Set<String>
    @State private var managedTrackers: [ExperimentTrackerModel]
    @State private var trackerEditor: ExperimentManagedTrackerEditorState?
    @State private var archiveCandidate: ExperimentTrackerModel?
    @State private var confirmingStop = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        entries: [ExperimentEntryModel],
        onDeleted: @escaping () -> Void
    ) {
        self.experiment = experiment
        self.trackers = trackers
        self.entries = entries
        self.onDeleted = onDeleted
        let headlineSelections = ExperimentUIStore.headlineSelections(for: experiment)
        self.originalHeadlineSelections = headlineSelections
        _name = State(initialValue: experiment.name)
        _protocolDescription = State(initialValue: experiment.protocolDescription ?? "")
        _question = State(initialValue: experiment.question ?? "")
        _plannedEnd = State(initialValue: experiment.plannedEndAt)
        _reminderEnabled = State(initialValue: experiment.reminderEnabled)
        _headlineMetricIDs = State(initialValue: Set(
            headlineSelections.map(\.metricID)
        ))
        _managedTrackers = State(initialValue: trackers.filter { $0.deletedAt == nil })
        let minutes = experiment.reminderTimeMinutes ?? 19 * 60
        _reminderTime = State(initialValue: Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: .now
        ) ?? .now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("Name")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                TextField("Experiment name", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .minimumTouchTarget()
                                    .accessibilityIdentifier("experiment-edit-name")
                            }
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("What you are changing")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                TextField(
                                    "Optional plan or protocol",
                                    text: $protocolDescription,
                                    axis: .vertical
                                )
                                .textFieldStyle(.roundedBorder)
                                .minimumTouchTarget()
                            }
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("Question")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                TextField(
                                    "Optional question to answer",
                                    text: $question,
                                    axis: .vertical
                                )
                                .textFieldStyle(.roundedBorder)
                                .minimumTouchTarget()
                            }
                        }
                    }

                    NavigationLink {
                        ExperimentHeadlineOutcomeEditor(
                            selectedMetricIDs: $headlineMetricIDs
                        )
                    } label: {
                        Card(padding: Space.md) {
                            HStack(spacing: Space.md) {
                                Image(systemName: "chart.bar.xaxis")
                                    .foregroundStyle(theme.accentForeground)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Headline Outcomes")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(headlineOutcomeSummary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.accentForeground)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("experiment-manage-outcomes")

                    if experiment.isActive {
                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                DatePicker(
                                    "Scheduled end",
                                    selection: $plannedEnd,
                                    in: earliestScheduledEnd...,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                Divider().overlay(theme.separator)
                                reminderControls
                            }
                        }
                    }

                    SectionHeader("Trackers") {
                        if experiment.isActive {
                            Button {
                                trackerEditor = ExperimentManagedTrackerEditorState(
                                    trackerID: nil,
                                    draft: .init()
                                )
                            } label: {
                                Label("Add Tracker", systemImage: "plus")
                                    .font(.bodyStrong)
                                    .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("experiment-manage-add-tracker")
                        }
                    }
                    if experiment.isActive {
                        Text("Tracker add, edit, archive, and restore actions save immediately. Save applies the experiment details, outcomes, schedule, and reminder fields above.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if activeManagedTrackers.isEmpty {
                        EmptyStateCard(
                            title: experiment.isActive ? "No active trackers" : "No custom trackers",
                            message: experiment.isActive
                                ? "Add a tracker for information that matters to this experiment."
                                : "No custom trackers were configured before this experiment ended.",
                            systemImage: "list.bullet.clipboard"
                        )
                    } else {
                        ForEach(Array(activeManagedTrackers.enumerated()), id: \.element.id) { index, tracker in
                            managedTrackerCard(
                                tracker,
                                index: index,
                                count: activeManagedTrackers.count
                            )
                        }
                    }

                    if !archivedManagedTrackers.isEmpty {
                        SectionHeader("Archived Trackers")
                        ForEach(archivedManagedTrackers, id: \.id) { tracker in
                            archivedTrackerCard(tracker)
                        }
                    }

                    if experiment.isActive {
                        SecondaryButton(title: "Stop Now", systemImage: "stop.fill") {
                            confirmingStop = true
                        }
                        .accessibilityIdentifier("experiment-stop-now")
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label(
                            experiment.isActive ? "Discard Experiment" : "Delete Experiment",
                            systemImage: "trash"
                        )
                        .font(.bodyStrong)
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("experiment-delete")
                }
                .padding(Space.lg)
                .keyboardAdaptiveBottomInset()
            }
            .background(theme.background)
            .navigationTitle("Manage Experiment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.bodyStrong)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("experiment-save-management")
                }
            }
            .sheet(item: $trackerEditor) { editor in
                ExperimentTrackerEditor(
                    initial: editor.draft,
                    preservesExistingEntries: editor.trackerID.map { trackerID in
                        entries.contains {
                            $0.deletedAt == nil && $0.trackerID == trackerID
                        }
                    } ?? false
                ) { draft in
                    saveTracker(draft, replacing: editor.trackerID)
                }
            }
            .confirmationDialog(
                archiveCandidate.map { "Archive \($0.label)?" } ?? "Archive tracker?",
                isPresented: Binding(
                    get: { archiveCandidate != nil },
                    set: { if !$0 { archiveCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive Tracker", role: .destructive) {
                    guard let tracker = archiveCandidate else { return }
                    archiveCandidate = nil
                    archive(tracker)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will stop appearing in future check-ins. Existing entries and their original tracker definition remain in results.")
            }
            .confirmationDialog(
                "Stop this experiment now?",
                isPresented: $confirmingStop,
                titleVisibility: .visible
            ) {
                Button("Stop Experiment", role: .destructive) {
                    do {
                        try ExperimentUIStore.stop(experiment, in: modelContext)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Keep Running", role: .cancel) {}
            } message: {
                Text("The observation window will end now. Custom entries already saved remain. A workout that started before this time is included in full after it finishes, including sets completed afterward.")
            }
            .confirmationDialog(
                experiment.isActive ? "Discard this experiment?" : "Delete this experiment?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(
                    experiment.isActive ? "Discard Experiment" : "Delete Experiment",
                    role: .destructive
                ) {
                    do {
                        try ExperimentUIStore.discard(
                            experiment,
                            trackers: managedTrackers,
                            entries: entries,
                            in: modelContext
                        )
                        dismiss()
                        onDeleted()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only the experiment and its custom entries are removed. Workouts and Apple Health data are unchanged.")
            }
            .alert("Changes couldn’t be saved", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .task { await refreshNotificationStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshNotificationStatus() }
            }
        }
    }

    private var headlineOutcomeSummary: String {
        if headlineMetricIDs.isEmpty {
            return "Results overview only"
        }
        return "\(headlineMetricIDs.count) selected"
    }

    private var earliestScheduledEnd: Date {
        min(experiment.plannedEndAt, Date.now.addingTimeInterval(60))
    }

    private var activeManagedTrackers: [ExperimentTrackerModel] {
        managedTrackers
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
            .sorted {
                if $0.position == $1.position {
                    return $0.createdAt < $1.createdAt
                }
                return $0.position < $1.position
            }
    }

    private var archivedManagedTrackers: [ExperimentTrackerModel] {
        managedTrackers
            .filter { $0.deletedAt == nil && $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    private var notificationsAuthorized: Bool {
        notificationStatus == .authorized
            || notificationStatus == .provisional
            || notificationStatus == .ephemeral
    }

    private var hasScheduledCheckInTracker: Bool {
        hasScheduledCheckInTracker(in: managedTrackers)
    }

    @ViewBuilder
    private var reminderControls: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Toggle("Check-in reminders", isOn: $reminderEnabled)
                .font(.bodyStrong)
                .tint(theme.accent)
                .disabled(!hasScheduledCheckInTracker)
                .accessibilityIdentifier("experiment-manage-reminder-toggle")
            Text(
                hasScheduledCheckInTracker
                    ? "Notifications follow the days used by Daily and Selected Days trackers."
                    : "Check-in reminders require an active Daily or Selected Days tracker."
            )
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if reminderEnabled, hasScheduledCheckInTracker {
                DatePicker(
                    "Reminder time",
                    selection: $reminderTime,
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("experiment-manage-reminder-time")
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check-in reminders")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(
                        hasScheduledCheckInTracker
                            ? "Notifications follow the days used by Daily and Selected Days trackers."
                            : "Requires an active Daily or Selected Days tracker."
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasScheduledCheckInTracker {
                    PrimaryButton(title: "Enable Notifications", systemImage: "bell.fill") {
                        Task { await requestNotificationPermission() }
                    }
                    .accessibilityIdentifier("experiment-manage-enable-notifications")
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications are off")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("The experiment still ends on schedule.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                SecondaryButton(title: "Open Settings", systemImage: "arrow.up.right") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #endif
                }
                .accessibilityIdentifier("experiment-manage-notification-settings")
            }
        @unknown default:
            Text("Reminders unavailable")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func managedTrackerCard(
        _ tracker: ExperimentTrackerModel,
        index: Int,
        count: Int
    ) -> some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.md) {
                    Image(systemName: tracker.type.experimentSystemImage)
                        .foregroundStyle(theme.accentForeground)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("\(tracker.type.experimentTitle) · \(tracker.cadence.experimentTitle)")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }

                Divider().overlay(theme.separator)

                if experiment.isActive {
                    HStack(spacing: Space.sm) {
                        Button {
                            trackerEditor = ExperimentManagedTrackerEditorState(
                                trackerID: tracker.id,
                                draft: ExperimentSetupTrackerDraft(tracker: tracker)
                            )
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("experiment-manage-edit-tracker-\(tracker.id.uuidString)")

                        Spacer(minLength: 0)

                        Button {
                            moveTracker(tracker, offset: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(index == 0)
                        .opacity(index == 0 ? 0.35 : 1)
                        .accessibilityLabel("Move \(tracker.label) up")

                        Button {
                            moveTracker(tracker, offset: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(index == count - 1)
                        .opacity(index == count - 1 ? 0.35 : 1)
                        .accessibilityLabel("Move \(tracker.label) down")

                        Button(role: .destructive) {
                            archiveCandidate = tracker
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("experiment-manage-archive-tracker-\(tracker.id.uuidString)")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                } else {
                    Text("Definitions are locked after the experiment ends.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private func archivedTrackerCard(_ tracker: ExperimentTrackerModel) -> some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: tracker.type.experimentSystemImage)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.label)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Past entries keep this definition")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if experiment.isActive {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        restore(tracker)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("experiment-manage-restore-tracker-\(tracker.id.uuidString)")
                } else {
                    Tag(text: "ARCHIVED")
                }
            }
        }
    }

    private func saveTracker(
        _ draft: ExperimentSetupTrackerDraft,
        replacing trackerID: UUID?
    ) {
        do {
            let result = try ExperimentUIStore.upsertTracker(
                draft,
                replacing: trackerID,
                for: experiment,
                in: modelContext
            )
            managedTrackers = result.trackers
            reminderEnabled = result.reminderEnabled
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archive(_ tracker: ExperimentTrackerModel) {
        do {
            let result = try ExperimentUIStore.archiveTracker(
                tracker,
                for: experiment,
                in: modelContext
            )
            managedTrackers = result.trackers
            reminderEnabled = result.reminderEnabled
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ tracker: ExperimentTrackerModel) {
        do {
            let replacement = try ExperimentUIStore.restoreTrackerVersion(
                tracker,
                for: experiment,
                position: (activeManagedTrackers.map(\.position).max() ?? -1) + 1,
                in: modelContext
            )
            if !managedTrackers.contains(where: { $0.id == replacement.id }) {
                managedTrackers.append(replacement)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func moveTracker(_ tracker: ExperimentTrackerModel, offset: Int) {
        do {
            let result = try ExperimentUIStore.moveTracker(
                tracker,
                offset: offset,
                for: experiment,
                in: modelContext
            )
            managedTrackers = result.trackers
            reminderEnabled = result.reminderEnabled
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hasScheduledCheckInTracker(
        in trackers: [ExperimentTrackerModel]
    ) -> Bool {
        trackers.contains {
            $0.deletedAt == nil
                && $0.archivedAt == nil
                && ($0.cadence == .daily || $0.cadence == .selectedWeekdays)
        }
    }


    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .denied || !hasScheduledCheckInTracker {
            reminderEnabled = false
        }
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )
        await refreshNotificationStatus()
        if notificationsAuthorized {
            reminderEnabled = true
        }
    }

    private func save() {
        if experiment.isActive, plannedEnd <= Date.now {
            error = "Choose a future scheduled end, or use Stop Now to end the experiment."
            return
        }
        do {
            let knownMetricIDs = Set(ExperimentHeadlineMetricOption.all.map(\.id))
            let selections = originalHeadlineSelections.filter {
                !knownMetricIDs.contains($0.metricID)
            } + ExperimentHeadlineMetricOption.all
                .filter { headlineMetricIDs.contains($0.id) }
                .map(\.selection)
            try ExperimentUIStore.updateManagement(
                .init(
                    name: name,
                    protocolDescription: protocolDescription,
                    question: question,
                    headlineMetricSelections: selections,
                    plannedEndAt: plannedEnd,
                    reminderEnabled: notificationsAuthorized
                        && hasScheduledCheckInTracker
                        && reminderEnabled,
                    reminderTime: reminderTime
                ),
                for: experiment,
                in: modelContext
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ExperimentManagedTrackerEditorState: Identifiable {
    let id = UUID()
    let trackerID: UUID?
    let draft: ExperimentSetupTrackerDraft
}

private extension ExperimentSetupTrackerDraft {
    init(tracker: ExperimentTrackerModel) {
        self.init(
            id: tracker.id,
            label: tracker.label,
            kind: ExperimentTrackerUIKind(rawValue: tracker.type.rawValue) ?? .note,
            unit: tracker.unit ?? "",
            lowLabel: tracker.scaleMinimumLabel ?? "",
            highLabel: tracker.scaleMaximumLabel ?? "",
            choices: tracker.options,
            cadence: ExperimentTrackerUICadence(rawValue: tracker.cadence.rawValue) ?? .anytime,
            weekdays: Set(tracker.selectedWeekdays)
        )
    }
}

private struct ExperimentHeadlineOutcomeEditor: View {
    @Environment(\.theme) private var theme
    @Binding var selectedMetricIDs: Set<String>

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Selected outcomes stay at the top of the result. All supported training and Health data remains available.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ExperimentHeadlineMetricOption.all) { option in
                    let selected = selectedMetricIDs.contains(option.id)
                    Button {
                        if selected {
                            selectedMetricIDs.remove(option.id)
                        } else {
                            selectedMetricIDs.insert(option.id)
                        }
                    } label: {
                        Card(padding: Space.md) {
                            HStack(spacing: Space.md) {
                                Image(systemName: option.systemImage)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                                    .frame(width: 36, height: 36)
                                    .background(theme.surfaceElevated)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(option.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("experiment-manage-outcome-\(option.id)")
                }
            }
            .padding(Space.lg)
        }
        .background(theme.background)
        .navigationTitle("Headline Outcomes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExperimentEntryHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let workouts: [WorkoutModel]

    @State private var editTarget: ExperimentEntryEditTarget?
    @State private var deleteCandidate: ExperimentEntryModel?
    @State private var error: String?

    private var liveEntries: [ExperimentEntryModel] {
        entries
            .filter { $0.deletedAt == nil && $0.experimentID == experiment.id }
            .sorted { $0.observedAt > $1.observedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.md) {
                    if liveEntries.isEmpty {
                        EmptyStateCard(
                            title: "No custom entries",
                            message: "Custom entries added to this experiment will appear here.",
                            systemImage: "list.bullet.clipboard"
                        )
                    } else {
                        ForEach(liveEntries, id: \.id) { entry in
                            entryCard(entry)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Custom Entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editTarget) { target in
                ExperimentLogUpdateSheet(
                    experiment: experiment,
                    trackers: trackers,
                    entries: entries,
                    workouts: workouts,
                    initialDate: target.observedAt,
                    isBackfill: true,
                    focusedTrackerID: target.trackerID,
                    editingEntryID: target.id
                )
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Entry", role: .destructive) {
                    guard let entry = deleteCandidate else { return }
                    deleteCandidate = nil
                    do {
                        try ExperimentUIStore.deleteEntry(entry, in: modelContext)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes only the custom entry. Workouts and Apple Health data are unchanged.")
            }
            .alert("Entry couldn’t be changed", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func entryCard(_ entry: ExperimentEntryModel) -> some View {
        let tracker = trackers.first { $0.id == entry.trackerID }
        let snapshot = entry.experimentDefinitionSnapshot
        let label = snapshot?.label ?? tracker?.label ?? "Archived tracker"
        let unit = snapshot?.unit ?? tracker?.unit
        let value = entry.value?.experimentDisplayText(unit: unit) ?? "No value"

        return Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .top, spacing: Space.md) {
                    Image(
                        systemName: snapshot?.type.experimentSystemImage
                            ?? tracker?.type.experimentSystemImage
                            ?? "note.text"
                    )
                    .foregroundStyle(theme.accentForeground)
                    .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(value)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(3)
                        if let workoutTitle = workoutTitle(for: entry) {
                            Label(workoutTitle, systemImage: "figure.strengthtraining.traditional")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        deleteCandidate = entry
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Delete \(label) entry")
                }

                Divider().overlay(theme.separator)

                HStack {
                    Text(entry.observedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        editTarget = ExperimentEntryEditTarget(
                            id: entry.id,
                            trackerID: entry.trackerID,
                            observedAt: entry.observedAt
                        )
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("experiment-edit-entry-\(entry.id.uuidString)")
                }
            }
        }
    }

    private func workoutTitle(for entry: ExperimentEntryModel) -> String? {
        guard let workoutID = entry.workoutID else { return nil }
        guard let workout = workouts.first(where: { $0.id == workoutID }) else {
            return "Original workout"
        }
        let title = workout.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Workout" : title
    }
}

private struct ExperimentEntryEditTarget: Identifiable {
    let id: UUID
    let trackerID: UUID
    let observedAt: Date
}
