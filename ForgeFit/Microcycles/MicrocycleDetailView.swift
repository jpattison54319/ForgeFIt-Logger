import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct MicrocycleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    let trackingID: UUID

    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var trackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var windows: [MicrocycleWindowModel]
    @Query(sort: \RestDayModel.date, order: .reverse)
    private var restDays: [RestDayModel]
    @Query(sort: \WorkoutModel.startedAt, order: .reverse)
    private var workouts: [WorkoutModel]
    @Query(sort: \RoutineModel.position)
    private var routines: [RoutineModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse)
    private var alternations: [RoutineAlternationModel]
    @Query private var exercises: [ExerciseLibraryModel]
    @Query private var setupNotes: [UserExerciseNoteModel]

    @State private var showingRestSheet = false
    @State private var showingEndConfirmation = false
    @State private var actionError: String?
    @State private var selectedDay: MicrocycleDaySelection?

    private var tracking: MicrocycleTrackingModel? {
        trackings.first { $0.id == trackingID && $0.deletedAt == nil }
    }

    private var trackingWindows: [MicrocycleWindowModel] {
        windows.filter { $0.trackingID == trackingID && $0.deletedAt == nil }
    }

    private var currentWindow: MicrocycleWindowModel? {
        guard let tracking else { return nil }
        return MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: trackingWindows
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let tracking {
                    if tracking.needsAttention {
                        needsAttentionCard(tracking)
                    } else if let currentWindow {
                        currentCard(tracking: tracking, window: currentWindow)
                    }
                    historySection(tracking: tracking)
                    if tracking.isActive || tracking.needsAttention {
                        Button("Stop Tracking", systemImage: "stop.fill", role: .destructive) {
                            showingEndConfirmation = true
                        }
                        .font(.bodyStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .accessibilityIdentifier("stop-microcycle-tracking")
                    }
                } else {
                    EmptyStateCard(
                        title: "Microcycle unavailable",
                        message: "This tracking history is no longer available.",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle(tracking?.folderName ?? "Microcycle")
        .sheet(isPresented: $showingRestSheet) {
            RestDayLogSheet { date in
                _ = try RestDayService.log(
                    date: date,
                    workouts: workouts,
                    in: modelContext
                )
            }
        }
        .sheet(item: $selectedDay) { selection in
            if let currentWindow {
                MicrocycleDayDetailSheet(
                    date: selection.date,
                    window: currentWindow,
                    windows: trackingWindows,
                    workouts: workouts,
                    restDays: restDays,
                    exercises: exercises
                )
            }
        }
        .confirmationDialog(
            "Stop tracking this microcycle?",
            isPresented: $showingEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Tracking", role: .destructive, action: endTracking)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Previous windows remain in your history. No workouts are deleted.")
        }
        .alert("Couldn't update microcycle", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
        } message: {
            Text(actionError ?? "")
        }
    }

    private func currentCard(
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel
    ) -> some View {
        let progress = MicrocycleTrackingService.progress(
            for: window,
            windows: trackingWindows,
            workouts: workouts
        )
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current window")
                            .font(.headline)
                            .foregroundStyle(theme.textPrimary)
                        Text("Day \(MicrocycleTrackingService.dayNumber(for: window)) of \(tracking.durationDays)")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Text("\(progress.completedCount)/\(progress.requiredCount)")
                        .font(.headline)
                        .foregroundStyle(progress.isComplete ? theme.accent : theme.textPrimary)
                }

                MicrocycleDayStrip(
                    window: window,
                    workouts: workouts,
                    restDays: RestDayService.live(restDays),
                    onSelectDay: selectDay
                )

                VStack(spacing: Space.sm) {
                    ForEach(progress.routines) { item in
                        routineRow(item)
                    }
                }

                SecondaryButton(title: "Log Rest Day", systemImage: "moon.zzz", action: showRestSheet)
            }
        }
    }

    private func routineRow(_ item: MicrocycleRoutineProgress) -> some View {
        let alternatingState = RoutineAlternationService.state(
            containing: item.routine.id,
            alternations: alternations,
            routines: routines,
            workouts: workouts
        )
        let startRoutine = alternatingState?.due
            ?? routines.first(where: { $0.id == item.routine.id })
        let completedName = item.completedRoutineID.flatMap { id in
            routines.first(where: { $0.id == id })?.name
                ?? (id == item.routine.alternateRoutineID ? item.routine.alternateRoutineName : item.routine.name)
        }
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? theme.accent : theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(startRoutine?.name ?? item.routine.name)
                        .font(.body)
                        .foregroundStyle(item.isCompleted ? theme.textSecondary : theme.textPrimary)
                    if let alternatingState {
                        Label(
                            "Alternates with \(alternatingState.other.name)",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                    }
                    if let completedAt = item.completedAt {
                        Text("Completed\(completedName.map { " \($0)" } ?? "") \(completedAt.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(startRoutine?.name ?? item.routine.name), \(item.isCompleted ? "completed" : "remaining")")

            if let startRoutine {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.sm) {
                        routineStartButton(startRoutine, isAlternate: false)
                        if let other = alternatingState?.other {
                            routineStartButton(other, isAlternate: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        routineStartButton(startRoutine, isAlternate: false)
                        if let other = alternatingState?.other {
                            routineStartButton(other, isAlternate: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routineStartButton(
        _ routine: RoutineModel,
        isAlternate: Bool
    ) -> some View {
        if isAlternate {
            Button("Start \(routine.name) instead") {
                startRoutine(id: routine.id)
            }
            .font(.subheadline.bold())
            .buttonStyle(.glass)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .accessibilityIdentifier("microcycle-start-alternate-\(routine.id.uuidString)")
        } else {
            Button("Start \(routine.name)", systemImage: "play.fill") {
                startRoutine(id: routine.id)
            }
            .font(.subheadline.bold())
            .buttonStyle(.glassProminent)
            .tint(theme.accent)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .accessibilityIdentifier("microcycle-start-routine-\(routine.id.uuidString)")
        }
    }

    private func needsAttentionCard(_ tracking: MicrocycleTrackingModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(theme.warmup)
                Text("Restore this microcycle folder or add a routine to continue automatic windows.")
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityIdentifier("microcycle-needs-attention")
    }

    private func historySection(tracking: MicrocycleTrackingModel) -> some View {
        let past = MicrocycleTrackingService.history(for: tracking, windows: trackingWindows)
            .filter { $0.id != currentWindow?.id }
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text("Previous windows")
                .font(.sectionTitle)
                .foregroundStyle(theme.textPrimary)
            if past.isEmpty {
                Card {
                    Text("Completed windows will appear here.")
                        .font(.body)
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                ForEach(past) { window in
                    let progress = MicrocycleTrackingService.progress(
                        for: window,
                        windows: trackingWindows,
                        workouts: workouts
                    )
                    Card(padding: Space.md) {
                        HStack(spacing: Space.md) {
                            Image(systemName: progress.isComplete ? "checkmark.circle.fill" : "calendar.badge.clock")
                                .foregroundStyle(progress.isComplete ? theme.accent : theme.textSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Cycle \(window.index + 1)")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text("\(window.startsAt.formatted(date: .abbreviated, time: .omitted))–\(window.endsAt.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Text("\(progress.completedCount)/\(progress.requiredCount)")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Cycle \(window.index + 1), \(progress.completedCount) of \(progress.requiredCount) workouts completed")
                    }
                }
            }
        }
    }

    private func showRestSheet() {
        showingRestSheet = true
    }

    private func selectDay(_ date: Date) {
        selectedDay = MicrocycleDaySelection(date: date)
    }

    private func startRoutine(id: UUID) {
        guard let routine = routines.first(where: {
            $0.id == id && $0.deletedAt == nil && $0.archivedAt == nil
        }) else {
            actionError = "This routine is no longer available to start."
            return
        }
        appState.requestStart {
            _ = WorkoutFactory.start(
                routine: routine,
                exercises: exercises,
                setupNotes: setupNotes,
                in: modelContext
            )
            appState.showingLogger = true
        }
    }

    private func endTracking() {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.end(tracking, in: modelContext)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

}
