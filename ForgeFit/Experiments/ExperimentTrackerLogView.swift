import ForgeData
import SwiftData
import SwiftUI

/// Structured logging for all trackers due in one context. Missing controls
/// remain nil until the user makes a choice, so Save never turns an unanswered
/// yes/no question into "No" or an empty number into zero.
struct ExperimentLogUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let experiment: ExperimentModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
    let workouts: [WorkoutModel]
    var workoutID: UUID?
    var initialDate: Date = .now
    var isBackfill = false
    var focusedTrackerID: UUID?
    var editingEntryID: UUID?
    var onSaved: () -> Void = {}

    @State private var observedAt: Date
    @State private var selectedTrackerID: UUID?
    @State private var selectedWorkoutID: UUID?
    @State private var values: [UUID: TrackerInputDraft] = [:]
    @State private var saveError: String?

    init(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        entries: [ExperimentEntryModel],
        workouts: [WorkoutModel] = [],
        workoutID: UUID? = nil,
        initialDate: Date = .now,
        isBackfill: Bool = false,
        focusedTrackerID: UUID? = nil,
        editingEntryID: UUID? = nil,
        onSaved: @escaping () -> Void = {}
    ) {
        self.experiment = experiment
        self.trackers = trackers
        self.entries = entries
        self.workouts = workouts
        self.workoutID = workoutID
        self.initialDate = initialDate
        self.isBackfill = isBackfill
        self.focusedTrackerID = focusedTrackerID
        self.editingEntryID = editingEntryID
        self.onSaved = onSaved
        let editingEntry = editingEntryID.flatMap { id in
            entries.first { $0.id == id && $0.deletedAt == nil }
        }
        _observedAt = State(initialValue: editingEntry?.observedAt ?? initialDate)
        _selectedTrackerID = State(
            initialValue: editingEntry?.trackerID ?? focusedTrackerID
        )
        _selectedWorkoutID = State(
            initialValue: editingEntry?.workoutID ?? workoutID
        )
    }

    private var windowEnd: Date {
        experiment.endedAt ?? min(experiment.plannedEndAt, .now)
    }

    private var selectedTrackerBounds: (start: Date, end: Date) {
        guard isBackfill, let tracker = selectedTracker else {
            return (experiment.startedAt, windowEnd)
        }
        return (
            max(experiment.startedAt, tracker.createdAt),
            min(windowEnd, tracker.archivedAt ?? windowEnd)
        )
    }

    private var range: ClosedRange<Date> {
        let bounds = selectedTrackerBounds
        return bounds.start...max(
            bounds.start,
            bounds.end.addingTimeInterval(-0.001)
        )
    }

    private var availableTrackers: [ExperimentTrackerModel] {
        trackers
            .filter {
                $0.deletedAt == nil
                    && (isBackfill || $0.archivedAt == nil)
            }
            .sorted { $0.position < $1.position }
    }

    private var selectedTracker: ExperimentTrackerModel? {
        selectedTrackerID.flatMap { id in availableTrackers.first { $0.id == id } }
    }

    private var effectiveWorkoutID: UUID? {
        isBackfill ? selectedWorkoutID : workoutID
    }

    private var completedWorkouts: [WorkoutModel] {
        let bounds = selectedTrackerBounds
        return workouts
            .filter {
                $0.deletedAt == nil
                    && $0.endedAt != nil
                    && $0.startedAt >= bounds.start
                    && $0.startedAt < bounds.end
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var editingEntry: ExperimentEntryModel? {
        editingEntryID.flatMap { id in
            entries.first { $0.id == id && $0.deletedAt == nil }
        }
    }

    private var visibleTrackers: [ExperimentTrackerModel] {
        if isBackfill {
            if selectedTracker?.cadence == .perWorkout, effectiveWorkoutID == nil {
                return []
            }
            return selectedTracker.map { [$0] } ?? []
        }
        return availableTrackers
            .filter { tracker in
                switch tracker.cadence {
                case .daily:
                    return true
                case .selectedWeekdays:
                    return ExperimentTrackerSchedule.isDue(
                        tracker,
                        on: observedAt,
                        calendar: experiment.experimentCalendar
                    )
                case .perWorkout:
                    return effectiveWorkoutID != nil
                case .anytime:
                    return true
                }
            }
    }

    private var hasSavableValue: Bool {
        if let tracker = selectedTracker, isBackfill {
            let bounds = selectedTrackerBounds
            guard bounds.start < bounds.end else { return false }
            if tracker.cadence == .perWorkout, effectiveWorkoutID == nil {
                return false
            }
            if tracker.cadence == .selectedWeekdays,
               !ExperimentTrackerSchedule.isDue(
                   tracker,
                   on: observedAt,
                   calendar: experiment.experimentCalendar
               ) {
                return false
            }
        }
        return visibleTrackers.contains { tracker in
            values[tracker.id]?.entryValue(for: tracker) != nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    contextControls

                    if visibleTrackers.isEmpty {
                        EmptyStateCard(
                            title: emptyTitle,
                            message: emptyMessage,
                            systemImage: isBackfill ? "list.bullet.clipboard" : "checkmark.circle"
                        )
                    } else {
                        ForEach(visibleTrackers, id: \.id) { tracker in
                            trackerCard(tracker)
                        }
                    }
                }
                .padding(Space.lg)
                .keyboardAdaptiveBottomInset()
            }
            .background(theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.bodyStrong)
                        .disabled(!hasSavableValue)
                        .accessibilityIdentifier("experiment-save-update")
                }
            }
            .onAppear(perform: loadExistingValues)
            .onChange(of: observedAt) { _, _ in loadExistingValues() }
            .onChange(of: selectedWorkoutID) { _, workoutID in
                guard let workoutID,
                      let workout = completedWorkouts.first(where: { $0.id == workoutID })
                else {
                    loadExistingValues()
                    return
                }
                observedAt = workout.startedAt
                loadExistingValues()
            }
            .alert("Update couldn’t be saved", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var navigationTitle: String {
        if editingEntry != nil { return "Edit Entry" }
        return isBackfill ? "Add Entry" : "Log Update"
    }

    private var emptyTitle: String {
        if isBackfill, selectedTracker == nil { return "Choose a tracker" }
        if selectedTracker?.cadence == .perWorkout, completedWorkouts.isEmpty {
            return "No completed workouts"
        }
        if selectedTracker?.cadence == .perWorkout, effectiveWorkoutID == nil {
            return "Choose a workout"
        }
        return "Nothing scheduled"
    }

    private var emptyMessage: String {
        if isBackfill, selectedTracker == nil {
            return "Select the custom tracker you want to add to this experiment."
        }
        if selectedTracker?.cadence == .perWorkout, completedWorkouts.isEmpty {
            return "This experiment has no completed workouts available for an after-workout entry."
        }
        if selectedTracker?.cadence == .perWorkout, effectiveWorkoutID == nil {
            return "Select the completed workout this entry belongs to."
        }
        return effectiveWorkoutID == nil
            ? "No daily or anytime trackers are available for this date."
            : "No after-workout trackers are configured."
    }

    @ViewBuilder
    private var contextControls: some View {
        if isBackfill {
            trackerSelectionControl
            if let tracker = selectedTracker {
                if tracker.cadence == .perWorkout {
                    workoutSelectionControl
                } else {
                    entryDatePicker
                    if tracker.cadence == .selectedWeekdays,
                       !ExperimentTrackerSchedule.isDue(
                           tracker,
                           on: observedAt,
                           calendar: experiment.experimentCalendar
                       ) {
                        Label(
                            "\(tracker.label) is not scheduled for this weekday.",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warmup)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("experiment-entry-not-due")
                    }
                }
            }
        } else if workoutID == nil {
            entryDatePicker
        }
    }

    @ViewBuilder
    private var trackerSelectionControl: some View {
        if editingEntry != nil, let tracker = selectedTracker {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: tracker.type.experimentSystemImage)
                        .foregroundStyle(theme.accentForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tracker")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                        Text(tracker.label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer()
                    if tracker.isArchived {
                        Tag(text: "ARCHIVED")
                    }
                }
            }
        } else {
            Menu {
                ForEach(availableTrackers, id: \.id) { tracker in
                    Button {
                        selectTracker(tracker)
                    } label: {
                        Label(
                            tracker.isArchived
                                ? "\(tracker.label) (Archived)"
                                : tracker.label,
                            systemImage: tracker.type.experimentSystemImage
                        )
                    }
                }
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: selectedTracker?.type.experimentSystemImage ?? "list.bullet")
                        .foregroundStyle(theme.accentForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tracker")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                        Text(selectedTracker?.label ?? "Choose tracker")
                            .font(.bodyStrong)
                            .foregroundStyle(
                                selectedTracker == nil
                                    ? theme.textSecondary : theme.textPrimary
                            )
                    }
                    Spacer()
                    if selectedTracker?.isArchived == true {
                        Tag(text: "ARCHIVED")
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .accessibilityIdentifier("experiment-entry-tracker")
        }
    }

    private var workoutSelectionControl: some View {
        Menu {
            ForEach(completedWorkouts, id: \.id) { workout in
                Button {
                    selectedWorkoutID = workout.id
                } label: {
                    Text(workoutMenuTitle(workout))
                }
            }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: selectedWorkoutSystemImage)
                    .foregroundStyle(theme.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Text(selectedWorkoutTitle)
                        .font(.bodyStrong)
                        .foregroundStyle(
                            selectedWorkoutID == nil
                                ? theme.textSecondary : theme.textPrimary
                        )
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .disabled(completedWorkouts.isEmpty)
        .accessibilityIdentifier("experiment-entry-workout")
    }

    private var entryDatePicker: some View {
        DatePicker(
            "Entry date",
            selection: $observedAt,
            in: range,
            displayedComponents: [.date, .hourAndMinute]
        )
        .font(.bodyStrong)
        .foregroundStyle(theme.textPrimary)
        .padding(Space.md)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityIdentifier("experiment-entry-date")
    }

    private var selectedWorkoutTitle: String {
        if let selectedWorkoutID,
           let workout = completedWorkouts.first(where: { $0.id == selectedWorkoutID }) {
            return workoutMenuTitle(workout)
        }
        if selectedWorkoutID != nil {
            return "Original workout"
        }
        return "Choose workout"
    }

    private var selectedWorkoutSystemImage: String {
        guard let selectedWorkoutID,
              let workout = completedWorkouts.first(where: {
                  $0.id == selectedWorkoutID
              }) else {
            return "figure.mixed.cardio"
        }
        return ExperimentWorkoutSummaryPresentation.make(
            workout: workout
        ).systemImage
    }

    private func workoutMenuTitle(_ workout: WorkoutModel) -> String {
        let title = workout.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = title.isEmpty ? "Workout" : title
        return "\(resolvedTitle) · \(workout.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func selectTracker(_ tracker: ExperimentTrackerModel) {
        selectedTrackerID = tracker.id
        selectedWorkoutID = nil
        values = [tracker.id: TrackerInputDraft()]
        if tracker.cadence != .perWorkout {
            let start = max(experiment.startedAt, tracker.createdAt)
            let end = min(windowEnd, tracker.archivedAt ?? windowEnd)
            let upperBound = max(start, end.addingTimeInterval(-0.001))
            observedAt = min(max(initialDate, start), upperBound)
        }
    }

    private func trackerCard(_ tracker: ExperimentTrackerModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: tracker.type.experimentSystemImage)
                        .foregroundStyle(theme.accentForeground)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tracker.label)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(tracker.cadence.experimentTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if tracker.isArchived {
                        Tag(text: "ARCHIVED")
                    }
                    if existingEntry(for: tracker) != nil, tracker.cadence != .anytime {
                        Tag(text: "EDITING", color: theme.accent)
                    }
                }

                input(for: tracker)
            }
        }
        .accessibilityIdentifier("experiment-tracker-input-\(tracker.id.uuidString)")
    }

    @ViewBuilder
    private func input(for tracker: ExperimentTrackerModel) -> some View {
        let binding = inputBinding(for: tracker.id)
        switch tracker.type {
        case .number:
            HStack(spacing: Space.sm) {
                TextField("Value", text: binding.numberText)
                    .keyboardType(.decimalPad)
                    .font(.rowValue)
                    .padding(Space.md)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityLabel(tracker.label)
                if let unit = tracker.unit, !unit.isEmpty {
                    Text(unit)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        case .boolean:
            HStack(spacing: Space.sm) {
                booleanButton("Yes", value: true, binding: binding.booleanValue)
                booleanButton("No", value: false, binding: binding.booleanValue)
            }
        case .rating:
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.xs) {
                    ForEach(1...5, id: \.self) { rating in
                        let selected = binding.ratingValue.wrappedValue == rating
                        Button {
                            binding.ratingValue.wrappedValue = rating
                        } label: {
                            Text("\(rating)")
                                .font(.bodyStrong)
                                .foregroundStyle(selected ? Color.white : theme.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(selected ? theme.accent : theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tracker.label), \(rating) of 5")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if tracker.scaleMinimumLabel != nil || tracker.scaleMaximumLabel != nil {
                    HStack {
                        Text(tracker.scaleMinimumLabel ?? "")
                        Spacer()
                        Text(tracker.scaleMaximumLabel ?? "")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                }
            }
        case .choice:
            Menu {
                ForEach(Array(tracker.options.enumerated()), id: \.offset) { _, option in
                    Button(option) {
                        binding.choiceValue.wrappedValue = option
                    }
                }
            } label: {
                HStack {
                    Text(binding.choiceValue.wrappedValue.isEmpty
                         ? "Choose"
                         : binding.choiceValue.wrappedValue)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.bodyStrong)
                .foregroundStyle(
                    binding.choiceValue.wrappedValue.isEmpty
                        ? theme.textSecondary : theme.textPrimary
                )
                .padding(.horizontal, Space.md)
                .frame(minHeight: 52)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .accessibilityLabel(tracker.label)
        case .note:
            TextEditor(text: binding.noteText)
                .frame(minHeight: 96)
                .padding(Space.sm)
                .scrollContentBackground(.hidden)
                .foregroundStyle(theme.textPrimary)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityLabel(tracker.label)
        }
    }

    private func booleanButton(
        _ title: String,
        value: Bool,
        binding: Binding<Bool?>
    ) -> some View {
        let selected = binding.wrappedValue == value
        return Button {
            binding.wrappedValue = value
        } label: {
            Text(title)
                .font(.bodyStrong)
                .foregroundStyle(selected ? Color.white : theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(selected ? theme.accent : theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func inputBinding(for trackerID: UUID) -> Binding<TrackerInputDraft> {
        Binding(
            get: { values[trackerID] ?? TrackerInputDraft() },
            set: { values[trackerID] = $0 }
        )
    }

    private func existingEntry(for tracker: ExperimentTrackerModel) -> ExperimentEntryModel? {
        if let editingEntry, editingEntry.trackerID == tracker.id {
            return editingEntry
        }
        let matching = entries.filter {
            $0.deletedAt == nil
                && $0.experimentID == experiment.id
                && $0.trackerID == tracker.id
        }
        switch tracker.cadence {
        case .daily, .selectedWeekdays:
            return matching.first {
                experiment.experimentCalendar.isDate(
                    $0.observedAt,
                    inSameDayAs: observedAt
                )
            }
        case .perWorkout:
            return effectiveWorkoutID.flatMap { workoutID in
                matching.first { $0.workoutID == workoutID }
            }
        case .anytime:
            return nil
        }
    }

    private func loadExistingValues() {
        var loaded: [UUID: TrackerInputDraft] = [:]
        for tracker in visibleTrackers {
            if let value = existingEntry(for: tracker)?.value {
                loaded[tracker.id] = TrackerInputDraft(value: value)
            } else {
                loaded[tracker.id] = TrackerInputDraft()
            }
        }
        values = loaded
    }

    private func save() {
        do {
            var updates: [ExperimentUIStore.EntryUpdate] = []
            for tracker in visibleTrackers {
                guard let value = values[tracker.id]?.entryValue(for: tracker) else { continue }
                if let editingEntry, editingEntry.trackerID == tracker.id {
                    guard conflictingEntry(
                        excluding: editingEntry,
                        for: tracker
                    ) == nil else {
                        saveError = "An entry already exists for this tracker and date."
                        return
                    }
                }
                updates.append(.init(
                    trackerID: tracker.id,
                    value: value,
                    observedAt: observedAt,
                    workoutID: effectiveWorkoutID,
                    editingEntryID: editingEntry?.trackerID == tracker.id
                        ? editingEntry?.id
                        : nil
                ))
            }
            guard !updates.isEmpty else { return }
            try ExperimentUIStore.saveEntries(
                updates,
                for: experiment,
                in: modelContext
            )
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func conflictingEntry(
        excluding editingEntry: ExperimentEntryModel,
        for tracker: ExperimentTrackerModel
    ) -> ExperimentEntryModel? {
        let candidates = entries.filter {
            $0.id != editingEntry.id
                && $0.deletedAt == nil
                && $0.experimentID == experiment.id
                && $0.trackerID == tracker.id
        }
        switch tracker.cadence {
        case .daily, .selectedWeekdays:
            return candidates.first {
                experiment.experimentCalendar.isDate(
                    $0.observedAt,
                    inSameDayAs: observedAt
                )
            }
        case .perWorkout:
            return effectiveWorkoutID.flatMap { workoutID in
                candidates.first { $0.workoutID == workoutID }
            }
        case .anytime:
            return nil
        }
    }
}

struct TrackerInputDraft {
    var numberText = ""
    var booleanValue: Bool?
    var ratingValue = 0
    var choiceValue = ""
    var noteText = ""

    init() {}

    init(value: ExperimentEntryValue) {
        switch value {
        case .number(let value):
            // Editing must round-trip the stored scalar. Display-oriented
            // formatting would silently rewrite untouched values such as
            // 0.125 when another tracker in the same check-in is saved.
            numberText = String(value)
        case .boolean(let value):
            booleanValue = value
        case .rating(let value):
            ratingValue = value
        case .choice(let value):
            choiceValue = value
        case .note(let value):
            noteText = value
        }
    }

    func entryValue(for tracker: ExperimentTrackerModel) -> ExperimentEntryValue? {
        switch tracker.type {
        case .number:
            let normalized = numberText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value.isFinite else { return nil }
            return .number(value)
        case .boolean:
            return booleanValue.map(ExperimentEntryValue.boolean)
        case .rating:
            return (1...5).contains(ratingValue) ? .rating(ratingValue) : nil
        case .choice:
            return choiceValue.isEmpty ? nil : .choice(choiceValue)
        case .note:
            let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .note(trimmed)
        }
    }
}
