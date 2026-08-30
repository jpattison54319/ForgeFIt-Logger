import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Resolves a preset before entering its analytics screen. Included presets
/// depend on seeded exercise identities; custom presets carry the exact saved
/// section and therefore remain viewable even if a movement is later deleted.
struct ConditioningPresetDetailDestination: View {
    @Environment(\.modelContext) private var modelContext

    let selection: ConditioningPresetSelection
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    var historySnapshot: ExercisePickerHistorySnapshot? = nil
    var loadsPersistedHistory = false

    @Query(sort: \IntervalPresetModel.updatedAt, order: .reverse)
    private var presetRecords: [IntervalPresetModel]
    @State private var activeSelection: ConditioningPresetSelection
    @State private var loadedHistory: [WorkoutModel]?
    @State private var loadedHistorySectionKey: String?
    @State private var historyLoadFailed = false
    @State private var historyRetryRevision = 0

    init(
        selection: ConditioningPresetSelection,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        historySnapshot: ExercisePickerHistorySnapshot? = nil,
        loadsPersistedHistory: Bool = false
    ) {
        self.selection = selection
        self.workouts = workouts
        self.exercises = exercises
        self.historySnapshot = historySnapshot
        self.loadsPersistedHistory = loadsPersistedHistory
        _activeSelection = State(initialValue: selection)
    }

    private var resolvedSelection: ConditioningPresetSelection {
        guard case .saved(let id, _, _) = activeSelection,
              let record = presetRecords.first(where: { $0.id == id && $0.deletedAt == nil }),
              case .section(let section) = record.storedConditioningPreset else {
            return activeSelection
        }
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .saved(id: id, name: name.isEmpty ? section.name : name, section: section)
    }

    private var resolvedSection: ConditioningSection? {
        resolvedSelection.resolvedSection(in: exercises)
    }

    private var historyLoadKey: String {
        let sectionKey = resolvedSection.map(ConditioningPrescriptionSignature.key(for:))
            ?? "unavailable"
        return "\(sectionKey)|\(historyRetryRevision)"
    }

    private var resolvedLoadedHistory: [WorkoutModel]? {
        guard let resolvedSection,
              loadedHistorySectionKey == ConditioningPrescriptionSignature.key(for: resolvedSection) else {
            return nil
        }
        return loadedHistory
    }

    var body: some View {
        Group {
            if resolvedSection == nil {
                ConditioningPresetUnavailableView(title: resolvedSelection.title)
            } else if loadsPersistedHistory, resolvedLoadedHistory == nil {
                if historyLoadFailed {
                    ContentUnavailableView {
                        Label("History unavailable", systemImage: "arrow.clockwise.circle")
                    } description: {
                        Text("ForgeFit couldn't load the complete preset history.")
                    } actions: {
                        Button("Try Again") { historyRetryRevision &+= 1 }
                    }
                } else {
                    ProgressView("Loading complete history")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("conditioning-preset-history-loading")
                }
            } else if let section = resolvedSection {
                ConditioningPresetDetailView(
                    title: resolvedSelection.title,
                    section: section,
                    workouts: resolvedLoadedHistory ?? workouts,
                    exercises: exercises,
                    historySnapshot: historySnapshot,
                    loadsCompleteHistoryForWorkoutDetail: loadsPersistedHistory,
                    editingSelection: resolvedSelection,
                    onSelectionChanged: {
                        loadedHistory = nil
                        loadedHistorySectionKey = nil
                        activeSelection = $0
                    }
                )
            }
        }
        .task(id: historyLoadKey) {
            guard loadsPersistedHistory, let section = resolvedSection else { return }
            loadedHistory = nil
            loadedHistorySectionKey = nil
            historyLoadFailed = false
            do {
                let worker = LiveWorkoutHistoryWorker(modelContainer: modelContext.container)
                let ids = try await worker.completedWorkoutIDs(matchingConditioning: section)
                guard !Task.isCancelled else { return }
                let history = try await fetchCompletedHistory(ids: ids)
                guard !Task.isCancelled else { return }
                loadedHistory = history
                loadedHistorySectionKey = ConditioningPrescriptionSignature.key(for: section)
            } catch is CancellationError {
                return
            } catch {
                historyLoadFailed = true
            }
        }
    }

    @MainActor
    private func fetchCompletedHistory(ids: [UUID]) async throws -> [WorkoutModel] {
        guard !ids.isEmpty else { return [] }
        var rows: [WorkoutModel] = []
        let batchSize = 160
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let end = min(start + batchSize, ids.count)
            rows.append(contentsOf: try modelContext.fetch(
                ExercisePickerHistoryDetailDestination.completedHistoryDescriptor(
                    for: Array(ids[start..<end])
                )
            ))
            await Task.yield()
            try Task.checkCancellation()
        }
        return rows.sorted { $0.startedAt > $1.startedAt }
    }
}

/// Exact-prescription performance history for one conditioning preset. This
/// screen is shared by the preset manager and historical conditioning blocks.
struct ConditioningPresetDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let title: String
    let section: ConditioningSection
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    var historySnapshot: ExercisePickerHistorySnapshot? = nil
    var loadsCompleteHistoryForWorkoutDetail = false
    var editingSelection: ConditioningPresetSelection? = nil
    var onSelectionChanged: ((ConditioningPresetSelection) -> Void)? = nil

    @State private var range: TimeChartRange = .all
    @State private var selectedMetric: ConditioningPresetStats.Metric?
    @State private var showFullHistory = false
    @State private var editingPreset: ConditioningPresetSelection?
    @State private var entriesMemo = Memo<String, [ConditioningPresetStats.Entry]>()
    @State private var seriesMemo = Memo<String, [MetricPoint]>()

    private var fingerprint: String {
        "\(AnalyticsFingerprint.of(workouts))|\(ConditioningPrescriptionSignature.key(for: section))"
    }

    private var entries: [ConditioningPresetStats.Entry] {
        entriesMemo(fingerprint) {
            ConditioningPresetStats.entries(for: section, in: workouts)
        }
    }

    private var metrics: [ConditioningPresetStats.Metric] {
        ConditioningPresetStats.availableMetrics(for: section, entries: entries)
    }

    private var activeMetric: ConditioningPresetStats.Metric? {
        if let selectedMetric, metrics.contains(selectedMetric) { return selectedMetric }
        return metrics.first { allSeries(for: $0).count >= 2 } ?? metrics.first
    }

    private var series: [MetricPoint] {
        guard let activeMetric else { return [] }
        return range.filtered(allSeries(for: activeMetric))
    }

    private func allSeries(for metric: ConditioningPresetStats.Metric) -> [MetricPoint] {
        seriesMemo("\(fingerprint)|\(metric.rawValue)") {
            ConditioningPresetStats.series(metric, for: section, entries: entries)
        }
    }

    private static let recentSessionCount = 3
    private var visibleEntries: [ConditioningPresetStats.Entry] {
        showFullHistory ? entries : Array(entries.prefix(Self.recentSessionCount))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.screenTitle)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("conditioning-preset-detail-title")
                    Text(section.format.title)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }

                ConditioningShareBlock(
                    plan: ConditioningPlan(sections: [section]),
                    result: nil,
                    exercises: exercises,
                    theme: theme,
                    showsResult: false,
                    showsPerformance: false,
                    showsSectionName: false
                )

                if entries.isEmpty {
                    emptyHistoryCard
                } else {
                    summaryCard
                    trendCard
                    historyCard
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(item: $editingPreset) { selection in
            ConditioningPresetEditView(
                selection: selection,
                section: section,
                exercises: exercises,
                workouts: workouts,
                historySnapshot: historySnapshot
            ) { updatedSelection in
                onSelectionChanged?(updatedSelection)
            }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                .accessibilityIdentifier("conditioning-preset-detail-back")
            Spacer()
            Text("Conditioning")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let editingSelection {
                CircleIconButton(
                    systemImage: "square.and.pencil",
                    label: editActionLabel
                ) {
                    editingPreset = editingSelection
                }
                .accessibilityIdentifier("edit-conditioning-preset")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.top, Space.sm)
    }

    private var editActionLabel: String {
        guard let editingSelection else { return "Edit preset" }
        return switch editingSelection {
        case .builtIn: "Customize preset"
        case .saved: "Edit preset"
        }
    }

    private var emptyHistoryCard: some View {
        Card {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Complete this exact preset to start its performance history.")
            }
        }
        .accessibilityIdentifier("conditioning-preset-empty-history")
    }

    private var summaryCard: some View {
        Card {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                alignment: .leading,
                spacing: Space.md
            ) {
                StatColumn(label: "Sessions", value: "\(entries.count)")
                StatColumn(
                    label: "Completed",
                    value: "\(entries.filter { $0.result.completed }.count)"
                )
                if let metric = metrics.first,
                   let best = ConditioningPresetStats.bestValue(metric, for: section, entries: entries) {
                    StatColumn(
                        label: metric == .performance ? bestPerformanceLabel : "Best \(ConditioningPresetStats.title(metric, for: section).lowercased())",
                        value: ConditioningPresetStats.format(best, metric: metric, section: section),
                        valueColor: theme.warmup
                    )
                }
            }
        }
        .accessibilityIdentifier("conditioning-preset-summary")
    }

    private var bestPerformanceLabel: String {
        switch section.scoreKind {
        case .elapsedTime: "Best time"
        case .roundsAndReps, .totalReps, .completedIntervals: "Best score"
        case .load: "Best load"
        }
    }

    @ViewBuilder
    private var trendCard: some View {
        if let metric = activeMetric {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        metricMenu(metric)
                        Spacer()
                        TimeChartRangePicker(selection: $range)
                    }

                    if let latest = series.last {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ConditioningPresetStats.format(
                                latest.value,
                                metric: metric,
                                section: section
                            ))
                            .font(.metricValue)
                            .foregroundStyle(theme.textPrimary)
                            Text(metric == .performance ? "last completed session" : "last measured session")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    if series.count >= 2 {
                        InteractiveLineTrendChart(
                            points: series,
                            metricName: ConditioningPresetStats.title(metric, for: section),
                            valueFormatter: { value in
                                ConditioningPresetStats.format(value, metric: metric, section: section)
                            },
                            axisValueFormatter: { value in
                                ConditioningPresetStats.axisValue(value, metric: metric, section: section)
                            },
                            yAxisLabel: ConditioningPresetStats.axisLabel(metric, for: section),
                            yDomainLowerLimit: metric == .secondHalfChange ? nil : 0,
                            color: theme.warmup,
                            chartAccessibilityLabel: "\(title) \(ConditioningPresetStats.title(metric, for: section)) progress chart",
                            chartAccessibilityIdentifier: "conditioning-preset-progress-chart"
                        )
                    } else {
                        Text("Complete this exact preset across multiple sessions to chart this metric.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .frame(height: 80)
                    }

                    Text(ConditioningPresetStats.interpretation(metric, for: section))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Card {
                Text("These sessions do not contain a comparable performance measurement yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func metricMenu(_ activeMetric: ConditioningPresetStats.Metric) -> some View {
        Menu {
            ForEach(metrics) { metric in
                Button {
                    selectedMetric = metric
                } label: {
                    if metric == activeMetric {
                        Label(ConditioningPresetStats.title(metric, for: section), systemImage: "checkmark")
                    } else {
                        Text(ConditioningPresetStats.title(metric, for: section))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(ConditioningPresetStats.title(activeMetric, for: section))
                    .font(.bodyStrong)
                if metrics.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(theme.textSecondary)
            .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(metrics.count < 2)
        .accessibilityLabel("Conditioning progress metric")
        .accessibilityValue(ConditioningPresetStats.title(activeMetric, for: section))
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.bottom, Space.sm)

                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    NavigationLink {
                        if loadsCompleteHistoryForWorkoutDetail {
                            CompleteWorkoutHistoryDetailDestination(
                                workout: entry.workout,
                                exercises: exercises,
                                seedHistory: workouts
                            )
                        } else {
                            WorkoutDetailView(
                                workout: entry.workout,
                                exercises: exercises,
                                history: workouts
                            )
                        }
                    } label: {
                        historyRow(entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the historical workout")

                    if index < visibleEntries.count - 1 {
                        Divider().overlay(theme.separator)
                    }
                }

                if entries.count > Self.recentSessionCount {
                    Divider().overlay(theme.separator)
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            showFullHistory.toggle()
                        }
                    } label: {
                        Text(showFullHistory ? "Show Recent Sessions" : "Show All \(entries.count) Sessions")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                            .frame(maxWidth: .infinity)
                            .minimumTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Space.sm)
                }
            }
        }
        .accessibilityIdentifier("conditioning-preset-history")
    }

    private func historyRow(_ entry: ConditioningPresetStats.Entry) -> some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(historySubtitle(entry))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Space.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .frame(minHeight: 58)
    }

    private func historySubtitle(_ entry: ConditioningPresetStats.Entry) -> String {
        var parts: [String] = []
        if entry.status != .completed { parts.append(entry.status.label) }
        parts.append(ConditioningPresetStats.sessionScore(entry))
        if let fact = ConditioningSharePresentation.performanceFacts(
            section: entry.section,
            result: entry.result
        ).first {
            parts.append("\(fact.label) \(fact.value)")
        }
        return parts.joined(separator: " · ")
    }
}

/// The live logger intentionally carries no complete model-backed workout
/// graph. If the user drills from exact preset history into a saved workout,
/// restore the detail screen's complete comparison context at that explicit
/// boundary instead of silently limiting awards and exercise history to the
/// logger's former recent-window approximation.
private struct CompleteWorkoutHistoryDetailDestination: View {
    @Environment(\.modelContext) private var modelContext

    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let seedHistory: [WorkoutModel]

    @State private var loadedHistory: [WorkoutModel]?
    @State private var historyLoadFailed = false
    @State private var retryRevision = 0

    var body: some View {
        Group {
            if let loadedHistory {
                WorkoutDetailView(
                    workout: loadedHistory.first(where: { $0.id == workout.id }) ?? workout,
                    exercises: exercises,
                    history: loadedHistory
                )
            } else if historyLoadFailed {
                ContentUnavailableView {
                    Label("History unavailable", systemImage: "arrow.clockwise.circle")
                } description: {
                    Text("ForgeFit couldn't load the complete workout comparison history.")
                } actions: {
                    Button("Try Again") { retryRevision &+= 1 }
                }
            } else {
                ProgressView("Loading workout history")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: retryRevision) {
            historyLoadFailed = false
            do {
                let ids = try await LiveWorkoutHistoryWorker(
                    modelContainer: modelContext.container
                ).completedWorkoutIDs()
                guard !Task.isCancelled else { return }
                loadedHistory = try await fetchCompletedHistory(ids: ids)
            } catch is CancellationError {
                return
            } catch {
                historyLoadFailed = true
            }
        }
    }

    @MainActor
    private func fetchCompletedHistory(ids: [UUID]) async throws -> [WorkoutModel] {
        var byID = Dictionary(
            seedHistory.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let batchSize = 160
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let end = min(start + batchSize, ids.count)
            let rows = try modelContext.fetch(
                ExercisePickerHistoryDetailDestination.completedHistoryDescriptor(
                    for: Array(ids[start..<end])
                )
            )
            for row in rows { byID[row.id] = row }
            await Task.yield()
            try Task.checkCancellation()
        }
        if byID[workout.id] == nil { byID[workout.id] = workout }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }
}

private struct ConditioningPresetUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        VStack(spacing: Space.xl) {
            HStack {
                CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                    .accessibilityIdentifier("conditioning-preset-detail-back")
                Spacer()
                Text("Conditioning").font(.rowValue).foregroundStyle(theme.textPrimary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            ContentUnavailableView {
                Label("Preset unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(title) needs an exercise that is missing from the library.")
            }
            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
    }
}
