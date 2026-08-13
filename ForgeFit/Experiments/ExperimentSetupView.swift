import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Four short setup pages with a final review. All state stays in memory until
/// Start succeeds, so leaving the sheet never creates a partial experiment.
struct ExperimentSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme

    let hasActiveWorkout: Bool
    let onStart: (ExperimentSetupDraft) throws -> Void

    @State private var draft = ExperimentSetupDraft()
    @State private var step: Step = .question
    @State private var trackerEditor: TrackerEditorState?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var startError: String?

    private enum Step: Int, CaseIterable {
        case question
        case outcomes
        case trackers
        case review

        var title: String {
            switch self {
            case .question: "Experiment"
            case .outcomes: "Outcomes"
            case .trackers: "Trackers"
            case .review: "Review"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                progress
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        switch step {
                        case .question: questionStep
                        case .outcomes: outcomesStep
                        case .trackers: trackersStep
                        case .review: reviewStep
                        }
                    }
                    .padding(Space.lg)
                    .keyboardAdaptiveBottomInset()
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) {
                    footer
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                        .background(theme.background)
                }
            }
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $trackerEditor) { editor in
                ExperimentTrackerEditor(initial: editor.tracker) { saved in
                    if let index = editor.index, draft.trackers.indices.contains(index) {
                        draft.trackers[index] = saved
                    } else {
                        draft.trackers.append(saved)
                    }
                }
            }
        }
        .interactiveDismissDisabled(step == .review && draft.canStart)
        .task { await refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationStatus() }
        }
        .onChange(of: hasScheduledCheckInTracker) { _, available in
            if !available {
                draft.reminderEnabled = false
            }
        }
        .alert("Experiment couldn’t be started", isPresented: Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError ?? "")
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "xmark", label: "Close experiment setup") { dismiss() }
                .accessibilityIdentifier("experiment-setup-close")
            Spacer()
            Text(step.title)
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    private var progress: some View {
        HStack(spacing: Space.xs) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? theme.accent : theme.surfaceElevated)
                    .frame(height: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count), \(step.title)")
    }

    private var questionStep: some View {
        Group {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("What are you testing?")
                    .font(.sectionTitle)
                    .foregroundStyle(theme.textPrimary)
                experimentTextField(
                    "Experiment name",
                    text: $draft.name,
                    identifier: "experiment-name-field"
                )
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("What will change? (optional)")
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                    TextEditor(text: $draft.protocolDescription)
                        .frame(minHeight: 90)
                        .padding(Space.sm)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(theme.textPrimary)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityIdentifier("experiment-protocol-field")
                }
                experimentTextField(
                    "Question (optional)",
                    text: $draft.question,
                    identifier: "experiment-question-field"
                )
            }

            VStack(alignment: .leading, spacing: Space.md) {
                Text("Duration")
                    .font(.sectionTitle)
                    .foregroundStyle(theme.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.sm) {
                    ForEach(ExperimentDurationPreset.allCases) { preset in
                        Button {
                            draft.durationPreset = preset
                        } label: {
                            HStack {
                                Text(preset.title)
                                    .font(.bodyStrong)
                                Spacer()
                                Image(systemName: draft.durationPreset == preset ? "checkmark.circle.fill" : "circle")
                            }
                            .foregroundStyle(
                                draft.durationPreset == preset ? theme.accent : theme.textPrimary
                            )
                            .padding(Space.md)
                            .frame(minHeight: 52)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(
                                        draft.durationPreset == preset
                                            ? theme.accent.opacity(0.7) : theme.separator,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.durationPreset == preset ? .isSelected : [])
                        .accessibilityIdentifier("experiment-duration-\(preset.rawValue)")
                    }
                }
                if draft.durationPreset == .custom {
                    DatePicker(
                        "Ends",
                        selection: $draft.customEndDate,
                        in: Date().addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("experiment-custom-end-date")
                }
                Text("Ends \(draft.resolvedEndDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var outcomesStep: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Headline outcomes")
                    .font(.sectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("These stay at the top of the result. All supported training and Health data is still included.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(ExperimentHeadlineMetricOption.all) { option in
                let selected = draft.headlineMetricIDs.contains(option.id)
                Button {
                    if selected {
                        draft.headlineMetricIDs.remove(option.id)
                    } else {
                        draft.headlineMetricIDs.insert(option.id)
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
                .accessibilityIdentifier("experiment-outcome-\(option.id)")
            }
        }
    }

    private var trackersStep: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Custom trackers")
                        .font(.sectionTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("Optional information that matters to this experiment.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button {
                    trackerEditor = TrackerEditorState(index: nil, tracker: .init())
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.bodyStrong)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("experiment-add-tracker")
            }

            if draft.trackers.isEmpty {
                Card {
                    HStack(spacing: Space.md) {
                        Image(systemName: "list.bullet.clipboard")
                            .foregroundStyle(theme.textSecondary)
                        Text("No custom trackers")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            } else {
                ForEach(Array(draft.trackers.enumerated()), id: \.element.id) { index, tracker in
                    trackerRow(tracker, index: index)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    reminderControls
                }
            }
        }
    }

    @ViewBuilder
    private var reminderControls: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Toggle("Check-in reminders", isOn: $draft.reminderEnabled)
                .font(.bodyStrong)
                .tint(theme.accent)
                .disabled(!hasScheduledCheckInTracker)
                .accessibilityIdentifier("experiment-reminder-toggle")
            Text(
                hasScheduledCheckInTracker
                    ? "Notifications follow the days used by Daily and Selected Days trackers."
                    : "Check-in reminders require a Daily or Selected Days tracker."
            )
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if draft.reminderEnabled, hasScheduledCheckInTracker {
                DatePicker(
                    "Reminder time",
                    selection: $draft.reminderTime,
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("experiment-reminder-time")
            }
        case .notDetermined:
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check-in reminders")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(
                        hasScheduledCheckInTracker
                            ? "Notifications follow the days used by Daily and Selected Days trackers."
                            : "Requires a Daily or Selected Days tracker."
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if hasScheduledCheckInTracker {
                    Button("Enable") {
                        Task { await requestNotificationPermission() }
                    }
                    .font(.bodyStrong)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("experiment-enable-notifications")
                }
            }
        case .denied:
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reminders unavailable")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("The experiment still ends on schedule.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button("Settings") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #endif
                }
                .font(.bodyStrong)
                .frame(minHeight: 44)
                .accessibilityIdentifier("experiment-notification-settings")
            }
        @unknown default:
            Text("Reminders unavailable")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var hasScheduledCheckInTracker: Bool {
        draft.trackers.contains {
            $0.cadence == .daily || $0.cadence == .selectedDays
        }
    }

    private func trackerRow(_ tracker: ExperimentSetupTrackerDraft, index: Int) -> some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: tracker.kind.systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.trimmedLabel)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("\(tracker.kind.title) · \(tracker.cadence.compactTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button {
                    trackerEditor = TrackerEditorState(index: index, tracker: tracker)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Edit \(tracker.trimmedLabel)")
                .accessibilityIdentifier("experiment-edit-tracker-\(index)")
                Menu {
                    if index > 0 {
                        Button("Move Up", systemImage: "arrow.up") {
                            draft.trackers.swapAt(index, index - 1)
                        }
                    }
                    if index < draft.trackers.count - 1 {
                        Button("Move Down", systemImage: "arrow.down") {
                            draft.trackers.swapAt(index, index + 1)
                        }
                    }
                    Button("Delete Tracker", systemImage: "trash", role: .destructive) {
                        draft.trackers.remove(at: index)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options for \(tracker.trimmedLabel)")
                .accessibilityIdentifier("experiment-tracker-options-\(index)")
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(draft.trimmedName.isEmpty ? "Untitled Experiment" : draft.trimmedName)
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("Now – \(draft.resolvedEndDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }

            reviewCard(
                title: "Question",
                rows: [
                    draft.protocolDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    draft.question.trimmingCharacters(in: .whitespacesAndNewlines),
                ].filter { !$0.isEmpty },
                empty: "No protocol or question added"
            )

            reviewCard(
                title: "Headline outcomes",
                rows: ExperimentHeadlineMetricOption.all
                    .filter { draft.headlineMetricIDs.contains($0.id) }
                    .map(\.title),
                empty: "Results overview only"
            )

            reviewCard(
                title: "Custom trackers",
                rows: draft.trackers.map { "\($0.trimmedLabel) · \($0.cadence.compactTitle)" },
                empty: "No custom trackers"
            )

            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Stored on this iPhone", systemImage: "iphone")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Experiment details and custom entries are not synced or included in ForgeFit’s iCloud backup. Deleting the app or changing phones will not restore them.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if hasActiveWorkout {
                Label("Finish or discard the active workout before starting.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.warmup)
                    .accessibilityIdentifier("experiment-active-workout-blocker")
            }
        }
    }

    private func reviewCard(title: String, rows: [String], empty: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if rows.isEmpty {
                    Text(empty)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(rows, id: \.self) { row in
                        Label(row, systemImage: "checkmark")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            if step != .question {
                SecondaryButton(title: "Back", systemImage: "chevron.left") {
                    step = Step(rawValue: step.rawValue - 1) ?? .question
                }
                .accessibilityIdentifier("experiment-setup-back")
            }
            if step == .review {
                PrimaryButton(title: "Start Experiment", systemImage: "play.fill") {
                    do {
                        try onStart(draft)
                        dismiss()
                    } catch {
                        startError = error.localizedDescription
                    }
                }
                .disabled(!draft.canStart || hasActiveWorkout)
                .opacity(!draft.canStart || hasActiveWorkout ? 0.5 : 1)
                .accessibilityIdentifier("experiment-start")
            } else {
                PrimaryButton(title: "Continue", systemImage: "chevron.right") {
                    step = Step(rawValue: step.rawValue + 1) ?? .review
                }
                .disabled(step == .question && draft.trimmedName.isEmpty)
                .opacity(step == .question && draft.trimmedName.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("experiment-setup-continue")
            }
        }
    }

    private func experimentTextField(
        _ title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        TextField(title, text: text)
            .font(.system(size: 16))
            .foregroundStyle(theme.textPrimary)
            .padding(Space.md)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityIdentifier(identifier)
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .denied {
            draft.reminderEnabled = false
        }
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )
        await refreshNotificationStatus()
        if notificationStatus == .authorized
            || notificationStatus == .provisional
            || notificationStatus == .ephemeral {
            draft.reminderEnabled = true
        }
    }
}

private struct TrackerEditorState: Identifiable {
    let id = UUID()
    let index: Int?
    let tracker: ExperimentSetupTrackerDraft
}

struct ExperimentTrackerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let onSave: (ExperimentSetupTrackerDraft) -> Void
    let preservesExistingEntries: Bool
    @State private var tracker: ExperimentSetupTrackerDraft
    @State private var choiceText = ""

    init(
        initial: ExperimentSetupTrackerDraft,
        preservesExistingEntries: Bool = false,
        onSave: @escaping (ExperimentSetupTrackerDraft) -> Void
    ) {
        self.onSave = onSave
        self.preservesExistingEntries = preservesExistingEntries
        _tracker = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if preservesExistingEntries {
                        Card {
                            Label(
                                "Saving a changed definition archives the current version. Existing entries keep their original label, type, unit, and choices.",
                                systemImage: "archivebox"
                            )
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    TextField("Tracker name", text: $tracker.label)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textPrimary)
                        .padding(Space.md)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityIdentifier("experiment-tracker-name")

                    choiceSection("Type") {
                        ForEach(ExperimentTrackerUIKind.allCases) { kind in
                            selectionRow(
                                title: kind.title,
                                systemImage: kind.systemImage,
                                selected: tracker.kind == kind
                            ) {
                                tracker.kind = kind
                            }
                        }
                    }

                    if tracker.kind == .number {
                        TextField("Unit (optional)", text: $tracker.unit)
                            .padding(Space.md)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .accessibilityIdentifier("experiment-tracker-unit")
                    } else if tracker.kind == .rating {
                        HStack(spacing: Space.md) {
                            TextField("1 means…", text: $tracker.lowLabel)
                                .minimumTouchTarget()
                            TextField("5 means…", text: $tracker.highLabel)
                                .minimumTouchTarget()
                        }
                        .textFieldStyle(.roundedBorder)
                    } else if tracker.kind == .choice {
                        choiceEditor
                    }

                    choiceSection("Schedule") {
                        ForEach(ExperimentTrackerUICadence.allCases) { cadence in
                            selectionRow(
                                title: cadence.title,
                                systemImage: cadenceIcon(cadence),
                                selected: tracker.cadence == cadence
                            ) {
                                tracker.cadence = cadence
                            }
                        }
                    }

                    if tracker.cadence == .selectedDays {
                        weekdayPicker
                    }
                }
                .padding(Space.lg)
                .keyboardAdaptiveBottomInset()
            }
            .background(theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        tracker.choices = normalizedChoices
                        onSave(tracker)
                        dismiss()
                    }
                    .disabled(!canSaveTracker)
                    .accessibilityIdentifier("experiment-save-tracker")
                }
            }
        }
    }

    private var normalizedChoices: [String] {
        var seen = Set<String>()
        return tracker.choices.compactMap { choice in
            let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private var choiceCandidate: String {
        choiceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var choiceAlreadyExists: Bool {
        let key = choiceCandidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return !choiceCandidate.isEmpty && normalizedChoices.contains { choice in
            choice.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == key
        }
    }

    private var canSaveTracker: Bool {
        guard !tracker.trimmedLabel.isEmpty else { return false }
        guard tracker.cadence != .selectedDays || !tracker.weekdays.isEmpty else { return false }
        return tracker.kind != .choice || normalizedChoices.count >= 2
    }

    private var choiceEditor: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Choices")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            ForEach(Array(tracker.choices.enumerated()), id: \.offset) { index, choice in
                HStack {
                    Text(choice)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button(role: .destructive) {
                        tracker.choices.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Delete \(choice)")
                }
                .padding(.leading, Space.md)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            HStack(spacing: Space.sm) {
                TextField("New choice", text: $choiceText)
                    .padding(Space.md)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Button("Add") {
                    guard !choiceCandidate.isEmpty, !choiceAlreadyExists else { return }
                    tracker.choices.append(choiceCandidate)
                    choiceText = ""
                }
                .font(.bodyStrong)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(choiceCandidate.isEmpty || choiceAlreadyExists)
                .accessibilityIdentifier("experiment-add-choice")
            }
            if choiceAlreadyExists {
                Text("That choice already exists.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warmup)
                    .accessibilityIdentifier("experiment-choice-duplicate")
            }
        }
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Days")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: Space.xs) {
                ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                    let weekday = index + 1
                    let selected = tracker.weekdays.contains(weekday)
                    Button {
                        if selected {
                            tracker.weekdays.remove(weekday)
                        } else {
                            tracker.weekdays.insert(weekday)
                        }
                    } label: {
                        Text(String(symbol.prefix(1)))
                            .font(.tag)
                            .foregroundStyle(selected ? Color.white : theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? theme.accent : theme.surface)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("experiment-tracker-weekday-\(weekday)")
                }
            }
        }
    }

    private func choiceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            VStack(spacing: 1) {
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private func selectionRow(
        title: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                Text(title)
                    .font(.bodyStrong)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            }
            .foregroundStyle(selected ? theme.accent : theme.textPrimary)
            .padding(.horizontal, Space.md)
            .frame(minHeight: 52)
            .background(theme.surface)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cadenceIcon(_ cadence: ExperimentTrackerUICadence) -> String {
        switch cadence {
        case .daily: "calendar"
        case .selectedDays: "calendar.badge.clock"
        case .eachWorkout: "figure.strengthtraining.traditional"
        case .anytime: "plus.circle"
        }
    }
}
