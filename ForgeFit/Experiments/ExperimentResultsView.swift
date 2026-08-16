import ForgeCore
import ForgeData
import Foundation
import SwiftData
import SwiftUI

struct ExperimentResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
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

    @State private var reference: ExperimentReferenceSelection
    @State private var customTrackerPairs: [UUID: UUID]
    @State private var showingComparison = false
    @State private var showingAllData = false
    @State private var analysisError: String?
    @State private var healthSnapshot: ExperimentHealthSnapshot?
    @State private var analysisResult: ExperimentResult?
    @State private var experimentRollup = ExperimentTrainingRollup()
    @State private var isAnalysisLoading = true
    @State private var performanceGate = LiveWorkoutPerformanceGate.shared

    init(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        entries: [ExperimentEntryModel],
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        comparisonExperiments: [ExperimentModel],
        comparisonTrackers: [ExperimentTrackerModel] = [],
        comparisonEntries: [ExperimentEntryModel] = [],
        initialReference: ExperimentReferenceSelection? = nil,
        onExport: @escaping () -> Void
    ) {
        let savedComparison = Self.savedComparison(for: experiment)
        self.experiment = experiment
        self.trackers = trackers
        self.entries = entries
        self.workouts = workouts
        self.exercises = exercises
        self.comparisonExperiments = comparisonExperiments
        self.comparisonTrackers = comparisonTrackers
        self.comparisonEntries = comparisonEntries
        self.onExport = onExport
        _reference = State(
            initialValue: initialReference
                ?? savedComparison?.reference
                ?? .previousEqualPeriod
        )
        _customTrackerPairs = State(
            initialValue: initialReference == nil
                ? (savedComparison?.customTrackerPairs ?? [:])
                : [:]
        )
    }

    private var experimentEnd: Date {
        experiment.observationEnd()
    }

    private var analysisTaskID: AnalysisTaskID {
        AnalysisTaskID(
            reference: reference,
            experimentUpdatedAt: experiment.updatedAt,
            trackers: .init(trackers + comparisonTrackers),
            entries: .init(entries + comparisonEntries),
            workouts: .init(workouts),
            exercises: .init(exercises),
            isLiveWorkoutActive: performanceGate.isLiveWorkoutActive,
            customTrackerPairs: customTrackerPairs
                .map { "\($0.key.uuidString):\($0.value.uuidString)" }
                .sorted()
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                resultsSummary
                customTrackerPairingSection

                if let result = analysisResult {
                    overview(result)
                    strengthSection(result)
                    cardioSection(result)
                    yogaSection(result)
                    healthSection(result)
                    customTrackersSection(result)
                    actionSection

                    Text("These are descriptive comparisons of recorded data during each period. They do not show that the experiment caused a change.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isAnalysisLoading {
                    analysisLoadingCard
                } else {
                    EmptyStateCard(
                        title: "Comparison unavailable",
                        message: "Choose a non-overlapping range with recorded elapsed time.",
                        systemImage: "exclamationmark.triangle"
                    )
                    SecondaryButton(title: "Change Comparison", systemImage: "arrow.left.arrow.right") {
                        showingComparison = true
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            navigationHeader
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
                .background(theme.background)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingComparison) {
            ExperimentComparisonPicker(
                experiment: experiment,
                otherExperiments: comparisonExperiments,
                selection: $reference
            )
        }
        .sheet(isPresented: $showingAllData) {
            ExperimentAllDataView(
                experiment: experiment,
                trackers: trackers,
                entries: entries,
                workouts: workouts,
                exercises: exercises,
                healthSnapshot: healthSnapshot
            )
        }
        .alert("Results unavailable", isPresented: Binding(
            get: { analysisError != nil },
            set: { if !$0 { analysisError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(analysisError ?? "")
        }
        .onAppear {
            if !experiment.isActive {
                ExperimentUIStore.markResultsViewed(experiment, in: modelContext)
            }
        }
        .task(id: analysisTaskID) {
            guard performanceGate.allowsNonWorkoutWork else { return }
            await refreshAnalysis()
        }
        .onChange(of: reference) {
            customTrackerPairs.removeAll()
            persistComparison()
        }
        .onChange(of: customTrackerPairs) {
            persistComparison()
        }
        .interactiveBackSwipeEnabled()
    }

    private var navigationHeader: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                .accessibilityIdentifier("experiment-results-back")
            Spacer()
            Text(experiment.isActive ? "Progress So Far" : "Results")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            CircleIconButton(systemImage: "square.and.arrow.up", label: "Export experiment") {
                onExport()
            }
            .accessibilityIdentifier("experiment-export")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.sm)
    }

    private var resultsSummary: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(experiment.name)
                .font(.screenTitle)
                .foregroundStyle(theme.textPrimary)
            HStack {
                Text(experiment.isActive ? "Elapsed experiment window" : "Completed experiment")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    showingComparison = true
                } label: {
                    Label("Change Comparison", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("experiment-change-comparison")
            }
            if let result = analysisResult {
                Card(padding: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Current · \(windowText(result.currentWindow))")
                        Text("\(referenceTitle) · \(windowText(result.referenceWindow))")
                        if result.metrics.contains(where: {
                            $0.comparisonBasis == .perDay
                        }) {
                            Text("Additive totals use a per-day comparison because the elapsed durations differ.")
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func overview(_ result: ExperimentResult) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Overview")
            Card {
                HStack(spacing: Space.md) {
                    StatColumn(label: "Workouts", value: "\(experimentRollup.workouts)")
                    StatColumn(label: "Training Days", value: "\(experimentRollup.trainingDays)")
                    StatColumn(
                        label: "Duration",
                        value: Fmt.durationShort(experimentRollup.durationSeconds)
                    )
                }
            }

            let headlineKeys = Set(
                ExperimentUIStore.headlineSelections(for: experiment).map(\.key)
            )
            let headline = result.metrics.filter {
                headlineKeys.contains($0.selection.key)
            }
            if headline.isEmpty {
                EmptyStateCard(
                    title: "No headline outcomes",
                    message: "Training and custom data remain available below.",
                    systemImage: "chart.bar"
                )
            } else {
                ForEach(headline, id: \.selection.key) { delta in
                    if healthSnapshot != nil
                        || !delta.selection.metricID.hasPrefix("health.") {
                        ExperimentDeltaCard(
                            title: title(for: delta.selection),
                            current: formattedValue(
                                delta.currentComparisonValue,
                                selection: delta.selection
                            ),
                            reference: formattedValue(
                                delta.referenceComparisonValue,
                                selection: delta.selection
                            ),
                            change: formattedChange(delta, selection: delta.selection),
                            currentCoverage: coverageText(
                                delta.current.coverage,
                                selection: delta.selection
                            ),
                            referenceCoverage: coverageText(
                                delta.reference.coverage,
                                selection: delta.selection
                            ),
                            aggregation: delta.selection.aggregation,
                            comparisonBasis: delta.comparisonBasis
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func strengthSection(_ result: ExperimentResult) -> some View {
        let namesByID = Dictionary(
            exercises.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let comparisons = ExperimentDetailedComparisonPresentation.exerciseComparisons(
            from: result,
            namesByID: namesByID
        )
        SectionHeader("Strength")
        if experimentRollup.strengthWorkouts == 0 {
            EmptyStateCard(
                title: "No strength sessions",
                message: "No completed working sets were recorded in this period.",
                systemImage: "dumbbell"
            )
        } else {
            Card {
                VStack(spacing: Space.md) {
                    ExperimentResultMetricRow(
                        label: "Strength workouts",
                        value: "\(experimentRollup.strengthWorkouts)"
                    )
                    ExperimentResultMetricRow(
                        label: "Recorded volume",
                        value: experimentRollup.strengthVolumeSamples > 0
                            ? Fmt.volume(experimentRollup.strengthVolume)
                            : "Not recorded",
                        detail: coverageDetail(
                            recorded: experimentRollup.strengthVolumeSamples,
                            total: experimentRollup.strengthSetSamples,
                            item: "working sets"
                        )
                    )
                    ExperimentResultMetricRow(
                        label: "Working sets",
                        value: Fmt.sets(experimentRollup.workingSets)
                    )
                    ExperimentResultMetricRow(
                        label: "Recorded reps",
                        value: experimentRollup.repsSamples > 0
                            ? "\(experimentRollup.reps)"
                            : "Not recorded",
                        detail: coverageDetail(
                            recorded: experimentRollup.repsSamples,
                            total: experimentRollup.strengthSetSamples,
                            item: "working sets"
                        )
                    )
                }
            }
        }
        if !comparisons.isEmpty {
            Text("By Exercise")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            ForEach(comparisons) { comparison in
                ExperimentScopedComparisonCard(
                    comparison: comparison,
                    metrics: ExperimentDetailedMetric.strength,
                    systemImage: "dumbbell.fill"
                )
            }
        }
    }

    @ViewBuilder
    private func cardioSection(_ result: ExperimentResult) -> some View {
        let comparisons = ExperimentDetailedComparisonPresentation.cardioComparisons(
            from: result
        )
        SectionHeader("Cardio")
        if experimentRollup.cardioSessions == 0 {
            EmptyStateCard(
                title: "No cardio sessions",
                message: "No completed cardio blocks were recorded in this period.",
                systemImage: "figure.run"
            )
        } else {
            Card {
                VStack(spacing: Space.md) {
                    ExperimentResultMetricRow(
                        label: "Sessions",
                        value: "\(experimentRollup.cardioSessions)"
                    )
                    ExperimentResultMetricRow(
                        label: "Duration",
                        value: experimentRollup.cardioDurationSamples > 0
                            ? Fmt.durationShort(experimentRollup.cardioDurationSeconds)
                            : "Not recorded",
                        detail: coverageDetail(
                            recorded: experimentRollup.cardioDurationSamples,
                            total: experimentRollup.cardioSessions,
                            item: "sessions"
                        )
                    )
                    ExperimentResultMetricRow(
                        label: "Recorded distance",
                        value: experimentRollup.cardioDistanceSamples > 0
                            ? Fmt.distance(experimentRollup.cardioDistanceMeters)
                            : "Not recorded"
                    )
                    if experimentRollup.cardioDistanceSamples < experimentRollup.cardioSessions {
                        Text("Distance coverage: \(experimentRollup.cardioDistanceSamples) of \(experimentRollup.cardioSessions) sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if !comparisons.isEmpty {
            Text("By Activity")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            ForEach(comparisons) { comparison in
                ExperimentScopedComparisonCard(
                    comparison: comparison,
                    metrics: ExperimentDetailedMetric.cardio,
                    systemImage: CardioKind.from(modality: comparison.id).systemImage
                )
            }
        }
    }

    @ViewBuilder
    private func yogaSection(_ result: ExperimentResult) -> some View {
        SectionHeader("Yoga")
        if experimentRollup.yogaSessions == 0 {
            EmptyStateCard(
                title: "No yoga sessions",
                message: "No completed yoga sessions were recorded in this period.",
                systemImage: "figure.mind.and.body"
            )
        } else {
            Card {
                VStack(spacing: Space.md) {
                    ExperimentResultMetricRow(
                        label: "Sessions",
                        value: "\(experimentRollup.yogaSessions)"
                    )
                    ExperimentResultMetricRow(
                        label: "Practice time",
                        value: experimentRollup.yogaDurationSamples > 0
                            ? Fmt.durationShort(experimentRollup.yogaDurationSeconds)
                            : "Not recorded",
                        detail: coverageDetail(
                            recorded: experimentRollup.yogaDurationSamples,
                            total: experimentRollup.yogaSessions,
                            item: "sessions"
                        )
                    )
                    ExperimentResultMetricRow(
                        label: "Poses completed",
                        value: experimentRollup.yogaPoseSamples > 0
                            ? "\(experimentRollup.yogaPoses)"
                            : "Not recorded",
                        detail: coverageDetail(
                            recorded: experimentRollup.yogaPoseSamples,
                            total: experimentRollup.yogaSessions,
                            item: "sessions"
                        )
                    )
                }
            }
        }
        if let comparison = result.metrics.first(where: {
            $0.selection.metricID == "yoga.duration"
        }), comparison.currentComparisonValue != nil
            || comparison.referenceComparisonValue != nil {
            ExperimentDeltaCard(
                title: "Practice time",
                current: formattedValue(
                    comparison.currentComparisonValue,
                    selection: comparison.selection
                ),
                reference: formattedValue(
                    comparison.referenceComparisonValue,
                    selection: comparison.selection
                ),
                change: formattedChange(comparison, selection: comparison.selection),
                currentCoverage: coverageText(
                    comparison.current.coverage,
                    selection: comparison.selection
                ),
                referenceCoverage: coverageText(
                    comparison.reference.coverage,
                    selection: comparison.selection
                ),
                aggregation: comparison.selection.aggregation,
                comparisonBasis: comparison.comparisonBasis
            )
        }
    }

    @ViewBuilder
    private func healthSection(_ result: ExperimentResult) -> some View {
        let health = result.metrics.filter {
            $0.selection.metricID.hasPrefix("health.")
                && ($0.currentComparisonValue != nil || $0.referenceComparisonValue != nil)
        }
        SectionHeader("Health & Activity")
        if healthSnapshot == nil {
            healthLoadingCard
        } else if health.isEmpty {
            EmptyStateCard(
                title: "No complete Health days",
                message: "Health permission, source coverage, and complete boundary days affect this section.",
                systemImage: "heart.text.square"
            )
        } else {
            ForEach(health, id: \.selection.key) { delta in
                ExperimentDeltaCard(
                    title: title(for: delta.selection),
                    current: formattedValue(
                        delta.currentComparisonValue,
                        selection: delta.selection
                    ),
                    reference: formattedValue(
                        delta.referenceComparisonValue,
                        selection: delta.selection
                    ),
                    change: formattedChange(delta, selection: delta.selection),
                    currentCoverage: coverageText(
                        delta.current.coverage,
                        selection: delta.selection
                    ),
                    referenceCoverage: coverageText(
                        delta.reference.coverage,
                        selection: delta.selection
                    ),
                    aggregation: delta.selection.aggregation,
                    comparisonBasis: delta.comparisonBasis
                )
            }
        }
    }

    private var healthLoadingCard: some View {
        Card {
            HStack(spacing: Space.md) {
                ProgressView()
                    .tint(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading Health history")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Reading the exact comparison periods on this iPhone.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experiment-health-loading")
    }

    private var analysisLoadingCard: some View {
        Card {
            HStack(spacing: Space.md) {
                ProgressView()
                    .tint(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing experiment results")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Comparing the selected periods and recorded data.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experiment-analysis-loading")
    }

    @ViewBuilder
    private var customTrackerPairingSection: some View {
        if let referenceExperimentID,
           !pairableCurrentTrackers.isEmpty {
            let referenceTrackers = pairableReferenceTrackers(
                experimentID: referenceExperimentID
            )
            SectionHeader("Match Custom Trackers")
            Text("Choose which custom trackers represent the same thing. ForgeFit only calculates a numeric change when the value type and unit are compatible.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(pairableCurrentTrackers, id: \.id) { tracker in
                        let candidates = referenceTrackers.filter {
                            customTrackersCanBePairedForDisplay(tracker, $0)
                        }
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(tracker.label)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text(tracker.experimentLifetimeLabel(in: experiment))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                            if candidates.isEmpty {
                                Text("Not compared")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(minHeight: 44, alignment: .leading)
                                    .accessibilityLabel(
                                        "\(tracker.label) cannot be compared because the reference experiment has no compatible tracker."
                                    )
                            } else {
                                Picker(
                                    "Reference tracker",
                                    selection: customTrackerPairBinding(for: tracker.id)
                                ) {
                                    Text("Not compared").tag(Optional<UUID>.none)
                                    ForEach(candidates, id: \.id) { candidate in
                                        Text(pairingLabel(candidate))
                                            .tag(Optional(candidate.id))
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(
                                    "Reference tracker for \(tracker.label)"
                                )
                                .accessibilityIdentifier(
                                    "experiment-custom-pair-\(tracker.id.uuidString)"
                                )
                            }
                            if candidates.isEmpty {
                                Text("No compatible tracker in the reference experiment")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func customTrackersSection(_ result: ExperimentResult) -> some View {
        SectionHeader("Custom Trackers")
        if trackers.filter({ $0.deletedAt == nil }).isEmpty {
            EmptyStateCard(
                title: "No custom trackers",
                message: "This experiment used automatic training and Health data only.",
                systemImage: "list.bullet.clipboard"
            )
        } else {
            ForEach(
                trackers.filter { $0.deletedAt == nil }.sorted { $0.position < $1.position },
                id: \.id
            ) { tracker in
                if let delta = customDelta(for: tracker, in: result),
                   delta.currentComparisonValue != nil
                    || delta.referenceComparisonValue != nil {
                    ExperimentDeltaCard(
                        title: tracker.label,
                        current: formattedValue(
                            delta.currentComparisonValue,
                            selection: delta.selection
                        ),
                        reference: formattedValue(
                            delta.referenceComparisonValue,
                            selection: delta.selection
                        ),
                        change: formattedChange(delta, selection: delta.selection),
                        currentCoverage: coverageText(
                            delta.current.coverage,
                            selection: delta.selection
                        ),
                        referenceCoverage: coverageText(
                            delta.reference.coverage,
                            selection: delta.selection
                        ),
                        aggregation: delta.selection.aggregation,
                        comparisonBasis: delta.comparisonBasis
                    )
                }
                Text("Current: \(experiment.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                ExperimentCustomTrackerResultCard(
                    tracker: tracker,
                    entries: entries.filter {
                        $0.deletedAt == nil && $0.trackerID == tracker.id
                    },
                    experiment: experiment,
                    workouts: workouts
                )
                if let referenceTracker = pairedReferenceTracker(for: tracker),
                   let referenceExperiment = comparisonExperiments.first(where: {
                       $0.id == referenceTracker.experimentID
                   }) {
                    Text("Reference: \(referenceExperiment.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ExperimentCustomTrackerResultCard(
                        tracker: referenceTracker,
                        entries: comparisonEntries.filter {
                            $0.deletedAt == nil
                                && $0.experimentID == referenceExperiment.id
                                && $0.trackerID == referenceTracker.id
                        },
                        experiment: referenceExperiment,
                        workouts: workouts
                    )
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: Space.md) {
            SecondaryButton(title: "Compare", systemImage: "arrow.left.arrow.right") {
                showingComparison = true
            }
            .accessibilityIdentifier("experiment-results-compare")
            SecondaryButton(title: "All Data", systemImage: "tablecells") {
                showingAllData = true
            }
            .accessibilityIdentifier("experiment-all-data")
            PrimaryButton(title: "Export Experiment Data", systemImage: "square.and.arrow.up") {
                onExport()
            }
            .accessibilityIdentifier("experiment-export-full")
        }
    }

    private var referenceTitle: String {
        switch reference {
        case .previousEqualPeriod: "Previous period"
        case let .experiment(id, _, _, _):
            comparisonExperiments.first(where: { $0.id == id })?.name
                ?? "Another experiment"
        case .custom: "Custom range"
        }
    }

    private func windowText(_ window: ExperimentWindow) -> String {
        "\(window.start.formatted(date: .abbreviated, time: .shortened)) – \(window.end.formatted(date: .abbreviated, time: .shortened))"
    }

    private var referenceExperimentID: UUID? {
        guard case let .experiment(id, _, _, _) = reference else {
            return nil
        }
        return id
    }

    private var pairableCurrentTrackers: [ExperimentTrackerModel] {
        trackers.filter {
            $0.deletedAt == nil
        }.sorted { $0.position < $1.position }
    }

    private func pairableReferenceTrackers(
        experimentID: UUID
    ) -> [ExperimentTrackerModel] {
        comparisonTrackers.filter {
            $0.experimentID == experimentID && $0.deletedAt == nil
        }.sorted { $0.position < $1.position }
    }

    private func customTrackerPairBinding(
        for currentTrackerID: UUID
    ) -> Binding<UUID?> {
        Binding(
            get: { customTrackerPairs[currentTrackerID] },
            set: { newValue in
                if let newValue {
                    let duplicateCurrentIDs = customTrackerPairs.compactMap {
                        currentID, referenceID in
                        currentID != currentTrackerID && referenceID == newValue
                            ? currentID
                            : nil
                    }
                    for currentID in duplicateCurrentIDs {
                        customTrackerPairs.removeValue(forKey: currentID)
                    }
                    customTrackerPairs[currentTrackerID] = newValue
                } else {
                    customTrackerPairs.removeValue(forKey: currentTrackerID)
                }
            }
        )
    }

    private func customTrackersCanBePairedForDisplay(
        _ current: ExperimentTrackerModel,
        _ reference: ExperimentTrackerModel
    ) -> Bool {
        guard current.type == reference.type else { return false }
        switch current.type {
        case .number, .boolean, .rating:
            return ExperimentAnalysisAdapter.customTrackersAreComparable(
                current,
                reference
            )
        case .choice, .note:
            return true
        }
    }

    private func pairedReferenceTracker(
        for current: ExperimentTrackerModel
    ) -> ExperimentTrackerModel? {
        guard let referenceExperimentID,
              let referenceID = customTrackerPairs[current.id] else {
            return nil
        }
        return comparisonTrackers.first {
            $0.id == referenceID
                && $0.experimentID == referenceExperimentID
                && $0.deletedAt == nil
                && customTrackersCanBePairedForDisplay(current, $0)
        }
    }

    private func pairingLabel(_ tracker: ExperimentTrackerModel) -> String {
        "\(tracker.label) · v\(tracker.definitionVersion)"
    }

    private func customDelta(
        for tracker: ExperimentTrackerModel,
        in result: ExperimentResult
    ) -> ExperimentMetricDelta? {
        result.metrics.first {
            $0.selection.metricID == "custom.tracker"
                && $0.selection.scope?.id == tracker.id.uuidString
        }
    }

    private func refreshAnalysis() async {
        guard performanceGate.allowsNonWorkoutWork else { return }
        let capturedNow = Date.now
        isAnalysisLoading = true
        analysisResult = nil
        analysisError = nil
        healthSnapshot = nil

        // Let the navigation transition paint before walking the local workout
        // graph. The evaluated result is then cached instead of being rebuilt
        // on every SwiftUI body pass.
        await Task.yield()
        guard !Task.isCancelled,
              performanceGate.allowsNonWorkoutWork else { return }

        do {
            let rollup = ExperimentTrainingRollup.make(
                workouts: workouts,
                exercises: exercises,
                start: experiment.startedAt,
                end: experimentEnd,
                calendar: experiment.experimentCalendar
            )
            let provisionalResult = try ExperimentAnalysisAdapter.result(
                experiment: experiment,
                trackers: trackers + comparisonTrackers,
                entries: entries + comparisonEntries,
                workouts: workouts,
                exercises: exercises,
                reference: reference,
                customTrackerPairs: customTrackerPairs,
                healthSnapshot: .empty,
                now: capturedNow
            )
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            experimentRollup = rollup
            analysisResult = provisionalResult
        } catch {
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            analysisError = error.localizedDescription
            healthSnapshot = .empty
            isAnalysisLoading = false
            return
        }

        let request: ExperimentComparisonRequest
        do {
            request = try ExperimentAnalysisAdapter.comparisonRequest(
                experiment: experiment,
                reference: reference,
                now: capturedNow
            )
        } catch {
            analysisResult = nil
            analysisError = error.localizedDescription
            healthSnapshot = .empty
            isAnalysisLoading = false
            return
        }

        let snapshot: ExperimentHealthSnapshot
        do {
            snapshot = try await ExperimentHealthLoader.load(request: request)
        } catch {
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            // Health permissions or availability do not invalidate the exact
            // local training/custom comparison already on screen.
            healthSnapshot = .empty
            isAnalysisLoading = false
            return
        }
        guard !Task.isCancelled,
              performanceGate.allowsNonWorkoutWork else { return }
        healthSnapshot = snapshot
        do {
            analysisResult = try ExperimentAnalysisAdapter.result(
                experiment: experiment,
                trackers: trackers + comparisonTrackers,
                entries: entries + comparisonEntries,
                workouts: workouts,
                exercises: exercises,
                reference: reference,
                customTrackerPairs: customTrackerPairs,
                healthSnapshot: snapshot,
                now: capturedNow
            )
        } catch {
            analysisResult = nil
            analysisError = error.localizedDescription
        }
        guard !Task.isCancelled,
              performanceGate.allowsNonWorkoutWork else { return }
        isAnalysisLoading = false
    }

    private func title(for selection: ExperimentMetricSelection) -> String {
        if selection.metricID == "custom.tracker",
           let raw = selection.scope?.id,
           let id = UUID(uuidString: raw),
           let tracker = trackers.first(where: { $0.id == id }) {
            return tracker.label
        }
        return ExperimentHeadlineMetricOption.all
            .first { $0.id == selection.metricID }?.title
            ?? selection.metricID
    }

    private func formattedValue(
        _ value: Double?,
        selection: ExperimentMetricSelection
    ) -> String {
        guard let value else { return "Not enough data" }
        switch selection.valueKind {
        case .massKilograms:
            return selection.metricID == "health.bodyweight"
                ? Fmt.loadUnit(value)
                : Fmt.volume(value)
        case .durationSeconds:
            return Fmt.durationShort(Int(value.rounded()))
        case .distanceMeters:
            return Fmt.distance(value)
        case .heartRateBPM:
            return "\(Int(value.rounded())) bpm"
        case .heartRateVariabilityMS:
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) ms"
        case .percentage:
            return value.formatted(.percent.scale(1).precision(.fractionLength(0...1)))
        case .steps:
            return "\(Int(value.rounded()).formatted()) steps"
        case .breathsPerMinute:
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) /min"
        case .energyKilocalories:
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) kcal"
        default:
            let formatted = value.formatted(
                .number.precision(.fractionLength(0...1))
            )
            guard selection.metricID == "custom.tracker",
                  let rawID = selection.scope?.id,
                  let trackerID = UUID(uuidString: rawID),
                  let tracker = trackers.first(where: { $0.id == trackerID }) else {
                return formatted
            }
            if tracker.type == .rating {
                return "\(formatted) / 5"
            }
            guard let unit = tracker.unit?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !unit.isEmpty else {
                return formatted
            }
            return "\(formatted) \(unit)"
        }
    }

    private func formattedChange(
        _ delta: ExperimentMetricDelta,
        selection: ExperimentMetricSelection
    ) -> String {
        guard let change = delta.comparisonAbsoluteChange else { return "No comparable value" }
        let prefix = change > 0 ? "+" : change < 0 ? "−" : ""
        let absolute = "\(prefix)\(formattedValue(abs(change), selection: selection))"
        guard let percent = delta.comparisonPercentChange else { return absolute }
        let percentPrefix = percent > 0 ? "+" : ""
        return "\(absolute) (\(percentPrefix)\(percent.formatted(.number.precision(.fractionLength(0...1))))%)"
    }

    private func coverageText(
        _ coverage: ExperimentMetricCoverage,
        selection: ExperimentMetricSelection
    ) -> String {
        if selection.metricID.hasPrefix("health."),
           let fraction = coverage.completeDayFraction {
            return "\(coverage.validValueCount) values · \(fraction.formatted(.percent.precision(.fractionLength(0)))) complete-day coverage"
        }
        let recorded = "\(coverage.validValueCount) recorded value\(coverage.validValueCount == 1 ? "" : "s")"
        guard coverage.missingValueCount > 0 else { return recorded }
        return "\(recorded) · \(coverage.missingValueCount) missing"
    }

    private func coverageDetail(
        recorded: Int,
        total: Int,
        item: String
    ) -> String? {
        guard recorded < total else { return nil }
        return "Recorded in \(recorded) of \(total) \(item)"
    }

    private static func savedComparison(
        for experiment: ExperimentModel
    ) -> ExperimentSavedComparison? {
        ExperimentSavedComparison.decode(experiment.savedComparisonJSON)
    }

    private func persistComparison() {
        let saved = ExperimentSavedComparison(
            reference: reference,
            customTrackerPairs: customTrackerPairs
        )
        guard let data = try? JSONEncoder().encode(saved),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        experiment.savedComparisonJSON = json
        experiment.updatedAt = .now
        modelContext.saveUserChanges()
    }
}

struct ExperimentSavedComparison: Codable {
    struct TrackerPair: Codable {
        let currentID: UUID
        let referenceID: UUID
    }

    let version: Int
    let reference: ExperimentReferenceSelection
    let trackerPairs: [TrackerPair]

    init(
        reference: ExperimentReferenceSelection,
        customTrackerPairs: [UUID: UUID]
    ) {
        version = 2
        self.reference = reference
        trackerPairs = customTrackerPairs.map {
            TrackerPair(currentID: $0.key, referenceID: $0.value)
        }.sorted { $0.currentID.uuidString < $1.currentID.uuidString }
    }

    var customTrackerPairs: [UUID: UUID] {
        Dictionary(
            trackerPairs.map { ($0.currentID, $0.referenceID) },
            uniquingKeysWith: { _, last in last }
        )
    }

    static func decode(_ json: String?) -> ExperimentSavedComparison? {
        guard let json, let data = json.data(using: .utf8) else {
            return nil
        }
        if let saved = try? JSONDecoder().decode(
            ExperimentSavedComparison.self,
            from: data
        ) {
            return saved
        }
        guard let legacy = try? JSONDecoder().decode(
            ExperimentReferenceSelection.self,
            from: data
        ) else {
            return nil
        }
        return ExperimentSavedComparison(
            reference: legacy,
            customTrackerPairs: [:]
        )
    }
}

private struct AnalysisTaskID: Hashable {
    struct CollectionRevision: Hashable {
        let count: Int
        let latestUpdate: Date
    }

    let reference: ExperimentReferenceSelection
    let experimentUpdatedAt: Date
    let trackers: CollectionRevision
    let entries: CollectionRevision
    let workouts: CollectionRevision
    let exercises: CollectionRevision
    let isLiveWorkoutActive: Bool
    let customTrackerPairs: [String]
}

private extension AnalysisTaskID.CollectionRevision {
    init(_ models: [ExperimentTrackerModel]) {
        count = models.count
        latestUpdate = models.map(\.updatedAt).max() ?? .distantPast
    }

    init(_ models: [ExperimentEntryModel]) {
        count = models.count
        latestUpdate = models.map(\.updatedAt).max() ?? .distantPast
    }

    init(_ models: [WorkoutModel]) {
        let completed = models.filter {
            $0.endedAt != nil && $0.deletedAt == nil
        }
        count = completed.count
        latestUpdate = completed.map(\.updatedAt).max() ?? .distantPast
    }

    init(_ models: [ExerciseLibraryModel]) {
        count = models.count
        latestUpdate = models.map(\.updatedAt).max() ?? .distantPast
    }
}

private extension ExperimentMetricDelta {
    var currentDisplayValue: Double? { current.value }

    var currentComparisonValue: Double? {
        comparisonBasis == .perDay ? current.perDayValue : current.value
    }

    var referenceComparisonValue: Double? {
        comparisonBasis == .perDay ? reference.perDayValue : reference.value
    }
}

private struct ExperimentDeltaCard: View {
    @Environment(\.theme) private var theme

    let title: String
    let current: String
    let reference: String
    let change: String
    let currentCoverage: String
    let referenceCoverage: String
    let aggregation: ExperimentMetricAggregation
    let comparisonBasis: ExperimentComparisonBasis

    private var basisTitle: String {
        guard comparisonBasis != .perDay else { return "PER DAY" }
        return switch aggregation {
        case .sum: "TOTAL"
        case .mean, .weightedMean: "AVERAGE"
        case .maximum: "MAX"
        case .minimum: "MIN"
        case .latest: "LATEST"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Text(title)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Tag(text: basisTitle)
                }
                Text(current)
                    .font(.metricValue)
                    .foregroundStyle(theme.textPrimary)
                HStack {
                    Text("Reference \(reference)")
                    Spacer()
                    Text(change)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current · \(currentCoverage)")
                    Text("Reference · \(referenceCoverage)")
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            }
        }
    }
}

private extension ExperimentAllDataView {
    @ViewBuilder
    private func workoutHeader(_ workout: WorkoutModel) -> some View {
        let summary = ExperimentWorkoutSummaryPresentation.make(
            workout: workout,
            exercises: exercises
        )
        VStack(alignment: .leading, spacing: 2) {
            Text(workout.title ?? "Workout")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Label(summary.detail, systemImage: summary.systemImage)
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func workoutStrengthRows(_ workout: WorkoutModel) -> some View {
        let rows = workout.exercises.sorted { $0.position < $1.position }
        ForEach(rows, id: \.id) { exercise in
            let completed = exercise.sets
                .filter { $0.completedAt != nil }
                .sorted { $0.position < $1.position }
            if !completed.isEmpty {
                Divider()
                Text(exerciseNames[exercise.exerciseID] ?? "Exercise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                ForEach(completed, id: \.id) { set in
                    ExperimentResultMetricRow(
                        label: "Set \(set.position + 1) · \(readable(set.setTypeRaw))",
                        value: setDetails(set)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func workoutCardioRows(_ workout: WorkoutModel) -> some View {
        let sessions = workout.cardioSessions.filter {
            $0.deletedAt == nil && $0.endedAt != nil
        }
        ForEach(sessions, id: \.id) { session in
            Divider()
            Text(
                session.isYogaSession
                    ? "Yoga"
                    : CardioKind.from(modality: session.modality).title
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            ForEach(cardioRows(session), id: \.label) { row in
                ExperimentResultMetricRow(label: row.label, value: row.value)
            }
        }
    }

    @ViewBuilder
    private func workoutContextRows(_ workout: WorkoutModel) -> some View {
        let rows = workoutContext(workout)
        if !rows.isEmpty {
            Divider()
            ForEach(rows, id: \.label) { row in
                ExperimentResultMetricRow(label: row.label, value: row.value)
            }
        }
        if let notes = workout.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            Text(notes)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var healthLoadingCard: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                ProgressView()
                    .tint(theme.accent)
                Text("Loading complete Health days")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func setDetails(_ set: SetModel) -> String {
        var parts: [String] = []
        if let load = ExperimentAnalysisAdapter.optionalEffectiveLoad(for: set) {
            parts.append(Fmt.loadUnit(load))
        } else if set.reps != nil {
            parts.append("Load not recorded")
        }
        if let reps = set.reps {
            parts.append("\(reps) reps")
        }
        if let duration = set.durationSeconds {
            parts.append(Fmt.durationShort(duration))
        }
        if let rpe = set.rpe {
            parts.append("RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let volume = ExperimentAnalysisAdapter.optionalTotalVolume(for: set) {
            parts.append(Fmt.volume(volume))
        }
        return parts.isEmpty ? "Completed" : parts.joined(separator: " · ")
    }

    private func cardioRows(_ session: CardioSessionModel) -> [ExperimentAllDataRow] {
        var rows: [ExperimentAllDataRow] = []
        if let duration = session.durationSeconds {
            rows.append(.init(label: "Duration", value: Fmt.durationShort(duration)))
        }
        if let distance = session.distanceMeters {
            rows.append(.init(label: "Distance", value: Fmt.distance(distance)))
        }
        if let pace = session.avgPaceSecondsPerKm {
            rows.append(.init(
                label: "Average pace",
                value: InsightValueFormat.paceString(
                    secondsPerMeter: pace / 1_000,
                    modality: session.modality
                )
            ))
        }
        if let averageHeartRate = session.avgHR {
            rows.append(.init(label: "Average heart rate", value: "\(averageHeartRate) bpm"))
        }
        if let maximumHeartRate = session.maxHR {
            rows.append(.init(label: "Maximum heart rate", value: "\(maximumHeartRate) bpm"))
        }
        if let energy = session.activeEnergyKcal {
            rows.append(.init(
                label: "Active energy",
                value: "\(energy.formatted(.number.precision(.fractionLength(0...1)))) kcal"
            ))
        }
        if let power = session.avgPowerWatts {
            rows.append(.init(
                label: "Average power",
                value: "\(power.formatted(.number.precision(.fractionLength(0...1)))) W"
            ))
        }
        if let elevation = session.elevationGainMeters {
            rows.append(.init(
                label: "Elevation gain",
                value: "\(elevation.formatted(.number.precision(.fractionLength(0...1)))) m"
            ))
        }
        if let steps = session.totalSteps {
            rows.append(.init(label: "Steps", value: steps.formatted()))
        }
        if let poses = session.logicalYogaPosesCompleted {
            rows.append(.init(label: "Poses completed", value: poses.formatted()))
        }
        return rows
    }

    private func workoutContext(_ workout: WorkoutModel) -> [ExperimentAllDataRow] {
        var rows: [ExperimentAllDataRow] = []
        if let source = workout.externalSource ?? workout.sourceDevice {
            rows.append(.init(label: "Source", value: source))
        }
        if let heartRate = workout.avgHR {
            rows.append(.init(label: "Average heart rate", value: "\(heartRate) bpm"))
        }
        if let heartRate = workout.maxHR {
            rows.append(.init(label: "Maximum heart rate", value: "\(heartRate) bpm"))
        }
        if let energy = workout.activeEnergyKcal {
            rows.append(.init(
                label: "Active energy",
                value: "\(energy.formatted(.number.precision(.fractionLength(0...1)))) kcal"
            ))
        }
        if let rpe = workout.wholeSessionRPE {
            rows.append(.init(
                label: "Session RPE",
                value: rpe.formatted(.number.precision(.fractionLength(0...1)))
            ))
        }
        if let readiness = workout.readinessAtStart {
            rows.append(.init(label: "Readiness at start", value: "\(readiness) / 100"))
        }
        return rows
    }

    private func healthRows(
        _ day: ExperimentHealthSnapshot.Day
    ) -> [ExperimentAllDataRow] {
        var rows: [ExperimentAllDataRow] = []
        if let value = day.hrvMilliseconds {
            rows.append(.init(label: "HRV", value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) ms"))
        }
        if let value = day.restingHeartRate {
            rows.append(.init(label: "Resting heart rate", value: "\(value) bpm"))
        }
        if let value = day.respiratoryRate {
            rows.append(.init(label: "Respiratory rate", value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) /min"))
        }
        if let value = day.oxygenSaturationPercent {
            rows.append(.init(label: "Blood oxygen", value: "\(value.formatted(.number.precision(.fractionLength(0...1))))%"))
        }
        if let value = day.sleepTotalMinutes {
            rows.append(.init(label: "Sleep", value: Fmt.durationShort(value * 60)))
        }
        if let value = day.sleepDeepMinutes {
            rows.append(.init(label: "Deep sleep", value: Fmt.durationShort(value * 60)))
        }
        if let value = day.sleepREMMinutes {
            rows.append(.init(label: "REM sleep", value: Fmt.durationShort(value * 60)))
        }
        if let value = day.bodyWeightKilograms {
            rows.append(.init(label: "Body weight", value: Fmt.loadUnit(value)))
        }
        if let value = day.steps {
            rows.append(.init(label: "Steps", value: Int(value.rounded()).formatted()))
        }
        if let value = day.exerciseMinutes {
            rows.append(.init(label: "Exercise", value: Fmt.durationShort(Int(value.rounded()) * 60)))
        }
        if let value = day.activeEnergyKilocalories {
            rows.append(.init(label: "Active energy", value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) kcal"))
        }
        return rows
    }

    private func entryDefinition(
        for entry: ExperimentEntryModel
    ) -> ExperimentAllDataTrackerDefinition? {
        guard let data = entry.definitionSnapshotJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(
            ExperimentAllDataTrackerDefinition.self,
            from: data
        )
    }

    private func readable(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ExperimentAllDataRow: Hashable {
    let label: String
    let value: String
}

private struct ExperimentAllDataTrackerDefinition: Decodable {
    let label: String
    let unit: String?
}

private struct ExperimentScopedComparisonCard: View {
    @Environment(\.theme) private var theme

    let comparison: ExperimentScopedComparison
    let metrics: [ExperimentDetailedMetric]
    let systemImage: String

    private var rows: [ExperimentScopedMetricRow] {
        metrics.compactMap { metric in
            guard let delta = comparison.delta(for: metric),
                  delta.currentComparisonValue != nil
                    || delta.referenceComparisonValue != nil else {
                return nil
            }
            return ExperimentScopedMetricRow(metric: metric, delta: delta)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label(comparison.title, systemImage: systemImage)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)

                ForEach(rows) { row in
                    ExperimentScopedMetricComparisonRow(
                        metric: row.metric,
                        delta: row.delta,
                        scopeID: comparison.id
                    )
                }
            }
        }
    }
}

private struct ExperimentScopedMetricRow: Identifiable {
    let metric: ExperimentDetailedMetric
    let delta: ExperimentMetricDelta

    var id: ExperimentDetailedMetric { metric }
}

private struct ExperimentScopedMetricComparisonRow: View {
    @Environment(\.theme) private var theme

    let metric: ExperimentDetailedMetric
    let delta: ExperimentMetricDelta
    let scopeID: String

    private var label: String {
        delta.comparisonBasis == .perDay ? "\(metric.title) per day" : metric.title
    }

    private var current: String {
        formatted(delta.currentComparisonValue)
    }

    private var reference: String {
        formatted(delta.referenceComparisonValue)
    }

    private var change: String {
        guard let absolute = delta.comparisonAbsoluteChange else {
            return "No comparison"
        }
        if abs(absolute) < 0.000_001 {
            return metric == .cardioPace ? "Same pace" : "No change"
        }
        if metric == .cardioPace {
            let direction = absolute < 0 ? "faster" : "slower"
            if let percent = delta.comparisonPercentChange {
                return "\(abs(percent).formatted(.number.precision(.fractionLength(0...1))))% \(direction)"
            }
            return "\(formatted(abs(absolute))) \(direction)"
        }
        let direction = absolute > 0 ? "↑" : "↓"
        if let percent = delta.comparisonPercentChange {
            return "\(direction) \(abs(percent).formatted(.number.precision(.fractionLength(0...1))))%"
        }
        return "\(direction) \(formatted(abs(absolute)))"
    }

    private var coverage: String {
        "Recorded values: \(coverageCount(delta.current.coverage)) current · \(coverageCount(delta.reference.coverage)) reference"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(current)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            Text("Reference \(reference) · \(change)")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Text(coverage)
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), current \(current), reference \(reference), \(change), \(coverage)"
        )
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "Not recorded" }
        switch metric {
        case .exerciseVolume:
            return Fmt.volume(value)
        case .exerciseBestLoad, .exerciseBestEstimated1RM:
            return Fmt.loadUnit(value)
        default:
            return InsightValueFormat.string(
                value,
                kind: delta.selection.valueKind,
                modality: delta.selection.scope?.kind == .modality ? scopeID : nil
            )
        }
    }

    private func coverageCount(_ coverage: ExperimentMetricCoverage) -> String {
        guard coverage.observationCount > 0 else { return "0" }
        return "\(coverage.validValueCount)/\(coverage.observationCount)"
    }
}

private struct ExperimentResultMetricRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            Text(value)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)\(detail.map { ", \($0)" } ?? "")")
    }
}

private struct ExperimentCustomTrackerResultCard: View {
    @Environment(\.theme) private var theme

    let tracker: ExperimentTrackerModel
    let entries: [ExperimentEntryModel]
    let experiment: ExperimentModel
    let workouts: [WorkoutModel]

    private var expected: Int? {
        let trackerStart = max(experiment.startedAt, tracker.createdAt)
        let experimentEnd = experiment.observationEnd()
        let trackerEnd = min(experimentEnd, tracker.archivedAt ?? experimentEnd)
        guard trackerStart < trackerEnd else { return nil }
        return ExperimentTrackerSchedule.expectedOccurrences(
            for: tracker,
            start: trackerStart,
            end: trackerEnd,
            workouts: workouts,
            calendar: experiment.experimentCalendar
        )
    }

    private var coverage: String {
        guard let expected, expected > 0 else {
            return "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
        }
        let fraction = min(Double(entries.count) / Double(expected), 1)
        return "\(entries.count) of \(expected) · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Image(systemName: tracker.type.experimentSystemImage)
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(tracker.experimentLifetimeLabel(in: experiment))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    Text(coverage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }

                switch tracker.type {
                case .number:
                    numericSummary(entries.compactMap(\.numericValue), unit: tracker.unit)
                case .rating:
                    numericSummary(entries.compactMap { $0.ratingValue.map(Double.init) }, unit: "/ 5")
                case .boolean:
                    let yes = entries.count { $0.booleanValue == true }
                    ExperimentResultMetricRow(
                        label: "Yes",
                        value: entries.isEmpty
                            ? "No entries"
                            : (Double(yes) / Double(max(entries.count, 1)))
                                .formatted(.percent.precision(.fractionLength(0)))
                    )
                case .choice:
                    ForEach(choiceCounts, id: \.choice) { row in
                        ExperimentResultMetricRow(label: row.choice, value: "\(row.count)")
                    }
                case .note:
                    ForEach(entries.prefix(3), id: \.id) { entry in
                        if let note = entry.textValue {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note)
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.textPrimary)
                                Text(entry.observedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    if entries.count > 3 {
                        Text("\(entries.count - 3) more in All Data")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func numericSummary(_ values: [Double], unit: String?) -> some View {
        if values.isEmpty {
            Text("No entries")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        } else {
            let mean = values.reduce(0, +) / Double(values.count)
            ExperimentResultMetricRow(
                label: "Average",
                value: [
                    mean.formatted(.number.precision(.fractionLength(0...2))),
                    unit,
                ].compactMap { $0 }.joined(separator: " ")
            )
            ExperimentResultMetricRow(
                label: "Range",
                value: [
                    "\(values.min()!.formatted(.number.precision(.fractionLength(0...2)))) – \(values.max()!.formatted(.number.precision(.fractionLength(0...2))))",
                    unit,
                ].compactMap { $0 }.joined(separator: " ")
            )
        }
    }

    private var choiceCounts: [(choice: String, count: Int)] {
        Dictionary(grouping: entries.compactMap(\.choiceValue), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count > $1.count }
    }
}

private extension ExperimentTrackerModel {
    func experimentLifetimeLabel(in experiment: ExperimentModel) -> String {
        let start = max(createdAt, experiment.startedAt)
        let experimentEnd = experiment.endedAt ?? experiment.plannedEndAt
        let end = min(archivedAt ?? experimentEnd, experimentEnd)
        let startText = start.formatted(date: .abbreviated, time: .shortened)
        if archivedAt == nil, experiment.isActive {
            return "v\(definitionVersion) · Since \(startText)"
        }
        let endText = end.formatted(date: .abbreviated, time: .shortened)
        return "v\(definitionVersion) · \(startText) – \(endText)"
    }
}

private struct ExperimentComparisonPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let otherExperiments: [ExperimentModel]
    @Binding var selection: ExperimentReferenceSelection

    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var customTimeZoneIdentifier: String
    @State private var error: String?

    init(
        experiment: ExperimentModel,
        otherExperiments: [ExperimentModel],
        selection: Binding<ExperimentReferenceSelection>
    ) {
        self.experiment = experiment
        self.otherExperiments = otherExperiments
        _selection = selection
        if case let .custom(start, end, timeZoneIdentifier) = selection.wrappedValue {
            _customStart = State(initialValue: start)
            _customEnd = State(initialValue: end)
            _customTimeZoneIdentifier = State(initialValue: timeZoneIdentifier)
        } else {
            let comparisonEnd = experiment.startedAt
            _customStart = State(initialValue:
                Calendar.current.date(
                    byAdding: .weekOfYear,
                    value: -8,
                    to: comparisonEnd
                ) ?? comparisonEnd.addingTimeInterval(-8 * 7 * 86_400)
            )
            _customEnd = State(initialValue: comparisonEnd)
            _customTimeZoneIdentifier = State(initialValue: TimeZone.current.identifier)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    comparisonButton(
                        title: "Previous Equal Period",
                        detail: "Immediately before this experiment",
                        selected: selection == .previousEqualPeriod
                    ) {
                        choose(.previousEqualPeriod)
                    }

                    otherExperimentsSection
                    customRangeSection
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Compare With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Range unavailable", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    @ViewBuilder
    private var otherExperimentsSection: some View {
        if !otherExperiments.isEmpty {
            SectionHeader("Other Experiments")
            ForEach(otherExperiments, id: \.id) { other in
                otherExperimentButton(other)
            }
        }
    }

    private var customRangeSection: some View {
        ExperimentCustomRangeSection(
            start: $customStart,
            end: $customEnd,
            isSelected: customSelectionMatchesFields,
            validationMessage: customRangeValidationMessage
        ) {
            choose(.custom(
                start: customStart,
                end: customEnd,
                timeZoneIdentifier: customTimeZoneIdentifier
            ))
        }
    }

    private func comparisonButton(
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? theme.accent : theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func otherExperimentButton(
        _ other: ExperimentModel
    ) -> some View {
        let end = other.endedAt ?? other.plannedEndAt
        let startText = other.startedAt.formatted(
            date: .abbreviated,
            time: .omitted
        )
        let endText = end.formatted(
            date: .abbreviated,
            time: .omitted
        )
        return comparisonButton(
            title: other.name,
            detail: "\(startText) – \(endText)",
            selected: selectedExperimentID == other.id
        ) {
            choose(.experiment(
                id: other.id,
                start: other.startedAt,
                end: end,
                timeZoneIdentifier: other.timeZoneIdentifier
            ))
        }
    }

    private func choose(_ proposed: ExperimentReferenceSelection) {
        do {
            let request = try ExperimentAnalysisAdapter.comparisonRequest(
                experiment: experiment,
                reference: proposed
            )
            _ = try ExperimentComparisonEngine.resolvedReferenceWindow(for: request)
            selection = proposed
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var selectedExperimentID: UUID? {
        guard case let .experiment(id, _, _, _) = selection else {
            return nil
        }
        return id
    }

    private var customSelectionMatchesFields: Bool {
        guard case let .custom(start, end, timeZoneIdentifier) = selection else {
            return false
        }
        return start == customStart
            && end == customEnd
            && timeZoneIdentifier == customTimeZoneIdentifier
    }

    private var customRangeValidationMessage: String? {
        guard customEnd > customStart else {
            return "End must be after start."
        }
        do {
            let request = try ExperimentAnalysisAdapter.comparisonRequest(
                experiment: experiment,
                reference: .custom(
                    start: customStart,
                    end: customEnd,
                    timeZoneIdentifier: customTimeZoneIdentifier
                )
            )
            _ = try ExperimentComparisonEngine.resolvedReferenceWindow(for: request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct ExperimentCustomRangeSection: View {
    @Environment(\.theme) private var theme

    @Binding var start: Date
    @Binding var end: Date
    let isSelected: Bool
    let validationMessage: String?
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Custom Range")
            Card {
                VStack(spacing: Space.md) {
                    if isSelected {
                        HStack {
                            Text("Saved custom comparison")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Tag(text: "SELECTED")
                        }
                    }
                    DatePicker(
                        "Start",
                        selection: $start,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "End",
                        selection: $end,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PrimaryButton(title: "Use Custom Range", action: onUse)
                        .disabled(validationMessage != nil)
                        .opacity(validationMessage == nil ? 1 : 0.5)
                        .accessibilityIdentifier("experiment-use-custom-comparison")
                }
            }
        }
    }
}

struct ExperimentLibraryComparisonView: View {
    @Environment(\.theme) private var theme
    let experiments: [ExperimentModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let onExport: (ExperimentModel) -> Void

    @State private var currentID: UUID?
    @State private var referenceID: UUID?

    private var current: ExperimentModel? {
        experiments.first { $0.id == currentID } ?? experiments.first
    }

    private var reference: ExperimentModel? {
        experiments.first { $0.id == referenceID && $0.id != current?.id }
            ?? experiments.first { $0.id != current?.id }
    }

    var body: some View {
        ScreenScaffold("Compare Experiments") {
            Card {
                VStack(spacing: Space.md) {
                    Picker("Experiment", selection: Binding(
                        get: { current?.id },
                        set: { currentID = $0 }
                    )) {
                        ForEach(experiments, id: \.id) { experiment in
                            Text(experiment.name).tag(Optional(experiment.id))
                        }
                    }
                    Picker("Compare with", selection: Binding(
                        get: { reference?.id },
                        set: { referenceID = $0 }
                    )) {
                        ForEach(experiments.filter { $0.id != current?.id }, id: \.id) { experiment in
                            Text(experiment.name).tag(Optional(experiment.id))
                        }
                    }
                }
            }

            if let current, let reference {
                let end = reference.endedAt ?? reference.plannedEndAt
                NavigationLink {
                    ExperimentResultsView(
                        experiment: current,
                        trackers: trackers.filter { $0.experimentID == current.id && $0.deletedAt == nil },
                        entries: entries.filter { $0.experimentID == current.id && $0.deletedAt == nil },
                        workouts: workouts,
                        exercises: exercises,
                        comparisonExperiments: experiments.filter { $0.id != current.id },
                        comparisonTrackers: trackers.filter {
                            $0.experimentID != current.id && $0.deletedAt == nil
                        },
                        comparisonEntries: entries.filter {
                            $0.experimentID != current.id && $0.deletedAt == nil
                        },
                        initialReference: .experiment(
                            id: reference.id,
                            start: reference.startedAt,
                            end: end,
                            timeZoneIdentifier: reference.timeZoneIdentifier
                        ),
                        onExport: { onExport(current) }
                    )
                } label: {
                    Label("View Comparison", systemImage: "arrow.left.arrow.right")
                        .font(.bodyStrong)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .accessibilityIdentifier("experiment-view-library-comparison")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ExperimentAllDataView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let healthSnapshot: ExperimentHealthSnapshot?

    private var includedWorkouts: [WorkoutModel] {
        workouts.filter {
            $0.deletedAt == nil && $0.endedAt != nil
                && experiment.contains($0.startedAt, asOf: experiment.observationEnd())
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private var includedHealthDays: [ExperimentHealthSnapshot.Day] {
        guard let healthSnapshot else { return [] }
        let end = experiment.observationEnd()
        return healthSnapshot.days.filter {
            $0.timestamp >= experiment.startedAt && $0.timestamp < end
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private var exerciseNames: [UUID: String] {
        Dictionary(
            exercises.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    SectionHeader("Workouts")
                    if includedWorkouts.isEmpty {
                        Text("No workouts")
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(includedWorkouts, id: \.id) { workout in
                            Card(padding: Space.md) {
                                VStack(alignment: .leading, spacing: Space.md) {
                                    workoutHeader(workout)
                                    workoutStrengthRows(workout)
                                    workoutCardioRows(workout)
                                    workoutContextRows(workout)
                                }
                            }
                        }
                    }

                    SectionHeader("Custom Entries")
                    if entries.isEmpty {
                        Text("No custom entries")
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(entries.filter { $0.deletedAt == nil }, id: \.id) { entry in
                            Card(padding: Space.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    let definition = entryDefinition(for: entry)
                                    let tracker = trackers.first { $0.id == entry.trackerID }
                                    Text(definition?.label ?? tracker?.label ?? "Archived tracker")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(entry.value?.experimentDisplayText(
                                        unit: definition?.unit ?? tracker?.unit
                                    ) ?? "No value")
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.textSecondary)
                                    Text(entry.observedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textTertiary)
                                    if definition != nil {
                                        Text("Uses the tracker definition saved with this entry")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                            }
                        }
                    }

                    SectionHeader("Health & Activity")
                    Text("Loaded from Apple Health for complete days in this experiment. These values stay on this iPhone unless you explicitly export them.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if healthSnapshot == nil {
                        healthLoadingCard
                    } else if includedHealthDays.isEmpty {
                        Text("No complete Health days with supported data")
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(includedHealthDays, id: \.timestamp) { day in
                            Card(padding: Space.md) {
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    Text(day.timestamp.formatted(date: .abbreviated, time: .omitted))
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    ForEach(healthRows(day), id: \.label) { row in
                                        ExperimentResultMetricRow(
                                            label: row.label,
                                            value: row.value
                                        )
                                    }
                                    Text(day.provenance == .estimated ? "Contains estimated or corrected values" : "Measured")
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
            .navigationTitle("All Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
