import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// First-class Yoga block inside the ordered workout logger. The hidden
/// generated exercise row is only an analytics/session anchor for the
/// existing Yoga runner; it never participates in the visible exercise list.
struct YogaBlockCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    @Bindable var workout: WorkoutModel
    @Bindable var block: WorkoutBlockModel
    var allowsLiveControls = true
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onReorderDragChanged: (CGFloat) -> Void
    let onReorderDragEnded: () -> Void
    let onAccessibilityMoveBy: (Int) -> Void

    @State private var workoutExercise: WorkoutExerciseModel?
    @State private var session: CardioSessionModel?
    @State private var showPlayer = false
    @State private var yogaSafetyPresentation: YogaSafetyPresentation?
    @State private var importing = false
    @State private var activeSegmentMessage: String?
    @State private var completionSaveError: String?

    private var plan: YogaFlowPlan? {
        YogaFlowPlan.decode(from: block.planSnapshotJSON)
    }

    private var style: YogaStyle {
        session?.yogaStyle ?? plan?.style ?? .hatha
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                if let session {
                    content(session)
                } else if !allowsLiveControls {
                    noResultSummary
                } else {
                    ProgressView()
                        .tint(theme.accent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: block.planSnapshotJSON) {
            ensureSession()
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let session, let workoutExercise {
                YogaPlayerView(
                    session: session,
                    workoutExercise: workoutExercise,
                    onComplete: { complete(session) }
                )
            }
        }
        .sheet(item: $yogaSafetyPresentation) { presentation in
            switch presentation {
            case .startClass:
                YogaSafetyView(startAction: { beginAfterSafety() })
            case .information:
                YogaSafetyView()
            }
        }
        .alert("Another Segment Is Active", isPresented: Binding(
            get: { activeSegmentMessage != nil },
            set: { if !$0 { activeSegmentMessage = nil } }
        )) {
        } message: {
            Text(activeSegmentMessage ?? "Complete the current segment first.")
        }
        .alert("Yoga Wasn't Saved", isPresented: Binding(
            get: { completionSaveError != nil },
            set: { if !$0 { completionSaveError = nil } }
        )) {
            Button("OK", role: .cancel) { completionSaveError = nil }
        } message: {
            Text("\(completionSaveError ?? "") Your yoga session is still active. Resume it and try completing again.")
        }
        .accessibilityIdentifier("live-yoga-block")
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            ZStack {
                theme.surfaceElevated
                Image(systemName: style.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Yoga")
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("\(style.title) block")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            ReorderHandle(
                onDragChanged: onReorderDragChanged,
                onDragEnded: onReorderDragEnded,
                onAccessibilityMoveBy: onAccessibilityMoveBy
            )
            ScrollSafeMenu(sections: blockMenuSections) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Yoga block options")
            .accessibilityIdentifier("yoga-block-options")
        }
    }

    private var blockMenuSections: [[ScrollSafeMenuItem]] {
        var sections: [[ScrollSafeMenuItem]] = []
        if !hasStarted {
            sections.append([ScrollSafeMenuItem(
                title: "Edit Block",
                systemImage: "slider.horizontal.3",
                action: onEdit
            )])
        }
        sections.append([ScrollSafeMenuItem(
            title: "Remove Block",
            systemImage: "trash",
            isDestructive: true,
            action: onRemove
        )])
        return sections
    }

    @ViewBuilder
    private func content(_ session: CardioSessionModel) -> some View {
        if !allowsLiveControls {
            completedSummary(session)
        } else if session.liveStartedAt == nil && session.endedAt == nil {
            notStarted(session)
        } else if session.endedAt == nil {
            inProgress(session)
        } else {
            completedSummary(session)
        }
    }

    private func notStarted(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            flowSummary
            YogaInstructorPicker()
            Button {
                requestStartOrResume(session)
            } label: {
                Label(plan?.hasSteps == true ? "Start Guided Class" : "Configure Flow", systemImage: plan?.hasSteps == true ? "play.fill" : "slider.horizontal.3")
                    .font(.bodyStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent)
                    .clipShape(.rect(cornerRadius: Radius.control))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("start-yoga-block")
        }
    }

    private func inProgress(_ session: CardioSessionModel) -> some View {
        VStack(spacing: Space.md) {
            if let runner = YogaFlowRunnerHub.shared.runner(for: session.id) {
                YogaRunnerStrip(runner: runner) { showPlayer = true }
            } else if plan?.hasSteps == true {
                Button {
                    startOrResume(session)
                } label: {
                    Label("Resume guided class", systemImage: "figure.yoga")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                        .minimumTouchTarget()
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Space.sm) {
                    Circle().fill(theme.accent).frame(width: 10, height: 10)
                    Text("In session").font(.label).foregroundStyle(theme.accent)
                    Spacer()
                    Text(Fmt.elapsed(max(0, Int(context.date.timeIntervalSince(session.liveStartedAt ?? session.startedAt)))))
                        .font(.metricValue)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                }
            }
            Button { complete(session) } label: {
                Label("Complete Yoga", systemImage: "checkmark")
                    .font(.bodyStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.success)
                    .clipShape(.rect(cornerRadius: Radius.control))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("complete-yoga-block")
            Text("Completing counts the hold you're in.")
                .font(.label)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func completedSummary(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if importing {
                Label("Fetching from Apple Health…", systemImage: "heart.fill")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            HStack {
                StatColumn(label: "Duration", value: Fmt.durationShort(session.durationSeconds), valueColor: theme.accent)
                StatColumn(label: "Poses", value: session.logicalYogaPosesCompleted.map(String.init) ?? "—")
                StatColumn(label: "Avg HR", value: session.avgHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "kcal", value: session.activeEnergyKcal.map { String(Int($0)) } ?? "—")
            }
            Label("Yoga complete", systemImage: "checkmark.circle.fill")
                .font(.bodyStrong)
                .foregroundStyle(theme.success)
        }
    }

    private var flowSummary: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: style.systemImage)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flow")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(plan?.hasSteps == true ? "\(plan?.structureSummary ?? "") · \(style.title)" : "Choose poses or a class")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(action: onEdit) {
                Text("Edit")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.accent)
                    .minimumTouchTarget()
            }
                .disabled(hasStarted)
        }
        .padding(Space.sm)
        .background(theme.surfaceElevated)
        .clipShape(.rect(cornerRadius: Radius.control))
    }

    private var hasStarted: Bool {
        session?.liveStartedAt != nil || session?.endedAt != nil
    }

    private var noResultSummary: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "lock.fill")
                .foregroundStyle(theme.textTertiary)
            Text("No yoga result logged")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
    }

    private func ensureSession() {
        if !allowsLiveControls {
            workoutExercise = workout.exercises.first { $0.generatedByWorkoutBlockID == block.id }
            session = workout.cardioSessions.first { $0.workoutBlockID == block.id }
            return
        }

        let anchor: WorkoutExerciseModel
        if let existing = workout.exercises.first(where: { $0.generatedByWorkoutBlockID == block.id }) {
            anchor = existing
        } else {
            let sessionExercise = YogaPoseCatalog.sessionExercise(in: modelContext)
            anchor = WorkoutExerciseModel(
                userID: workout.userID,
                exerciseID: sessionExercise.id,
                position: block.position,
                yogaFlowJSON: block.planSnapshotJSON,
                generatedByWorkoutBlockID: block.id,
                sets: []
            )
            modelContext.insert(anchor)
            workout.exercises.append(anchor)
        }
        anchor.yogaFlowJSON = block.planSnapshotJSON
        anchor.generatedByWorkoutBlockID = block.id

        let linkedSession: CardioSessionModel
        if let existing = workout.cardioSessions.first(where: { $0.workoutBlockID == block.id }) {
            linkedSession = existing
        } else {
            linkedSession = CardioSessionModel(
                userID: workout.userID,
                workoutExerciseID: anchor.id,
                workoutBlockID: block.id,
                modality: CardioSessionModel.yogaModality,
                startedAt: workout.startedAt,
                sourceDevice: "iphone-yoga"
            )
            modelContext.insert(linkedSession)
            workout.cardioSessions.append(linkedSession)
        }
        linkedSession.workoutExerciseID = anchor.id
        linkedSession.workoutBlockID = block.id
        linkedSession.modality = CardioSessionModel.yogaModality
        if linkedSession.liveStartedAt == nil, linkedSession.endedAt == nil {
            linkedSession.durationSeconds = plan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil }
            linkedSession.yogaStyleRaw = plan?.styleRaw
        }
        modelContext.saveUserChanges()
        workoutExercise = anchor
        session = linkedSession
    }

    private func startOrResume(_ session: CardioSessionModel) {
        guard let plan, plan.hasSteps else {
            onEdit()
            return
        }
        if let active = WorkoutTimedSegmentPolicy.activeSegment(in: workout, excludingBlockID: block.id) {
            activeSegmentMessage = "\(active) is already recording. Complete it before starting Yoga."
            return
        }
        Task { await HealthService.shared.requestAuthorizationIfNeeded() }
        if session.liveStartedAt == nil {
            let now = Date()
            session.liveStartedAt = now
            session.startedAt = now
        }
        block.updatedAt = .now
        modelContext.saveUserChanges()
        YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: modelContext)
        showPlayer = true
        WatchLink.shared.publishState()
    }

    private func requestStartOrResume(_ session: CardioSessionModel) {
        // An already-running class was gated when it first started; resume it
        // directly instead of interrupting recovery from an app relaunch.
        if session.liveStartedAt != nil || YogaSafetyAcknowledgement.isAccepted {
            startOrResume(session)
            return
        }
        yogaSafetyPresentation = .startClass
    }

    private func beginAfterSafety() {
        guard let session else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            startOrResume(session)
        }
    }

    private func complete(_ session: CardioSessionModel) {
        guard let workoutExercise else { return }
        // Record the hold in progress before stopping (Skip's partial credit,
        // FF-013); YogaSessionCompletion.complete derives the rest.
        YogaFlowRunnerHub.shared.complete(for: session.id, persist: false)
        showPlayer = false
        let end = Date.now
        let start = session.liveStartedAt ?? session.startedAt
        let exercise = YogaPoseCatalog.sessionExercise(in: modelContext)
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: exercise,
            context: modelContext,
            endedAt: end,
            useClockDuration: true,
            clearCheckpoint: false
        )
        block.updatedAt = end
        if let failure = modelContext.saveReportingFailure() {
            completionSaveError = failure
            WatchLink.shared.publishState()
            return
        }
        YogaRuntimeCheckpointStore.clear(sessionID: session.id)
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
            .init(
                sessionID: session.id,
                start: start,
                end: end,
                modality: .other,
                fallbackAvgHR: bleStats?.avgHR,
                fallbackMaxHR: bleStats?.maxHR,
                importsDistance: false,
                providesGPSDistance: false,
                hadManualIntervalPlan: false
            ),
            container: modelContext.container
        )
        importing = false
        WatchLink.shared.publishState()
    }
}
