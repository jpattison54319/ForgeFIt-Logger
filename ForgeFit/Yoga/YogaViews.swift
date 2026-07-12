import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

// MARK: - In-logger yoga card (replaces the strength set table for yoga)

/// A guided-class yoga effort: the flow summary before starting, live pose
/// guidance while recording (compact strip + full-screen player), and a
/// completion summary. No sets or set types — yoga follows the session data
/// model, like cardio.
struct YogaExerciseCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Bindable var workout: WorkoutModel
    let workoutExercise: WorkoutExerciseModel
    let exercise: ExerciseLibraryModel?
    var allowsLiveControls: Bool = true
    let availableSupersetGroups: [Int]
    let onAssignSuperset: (Int?) -> Void
    let onCreateSuperset: () -> Void
    let onUngroupSuperset: (Int) -> Void
    var onShowExerciseDetail: (ExerciseLibraryModel) -> Void = { _ in }
    let onReplace: () -> Void
    let onRemove: () -> Void

    @State private var session: CardioSessionModel?
    @State private var showManual = false
    @State private var importing = false
    @State private var showFlowBuilder = false
    @State private var showPlayer = false

    private var plan: YogaFlowPlan? {
        YogaFlowPlan.resolved(for: workoutExercise, exercise: exercise)
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
                } else {
                    ProgressView().tint(theme.accent).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear(perform: ensureSession)
        .sheet(isPresented: $showFlowBuilder) {
            YogaFlowBuilderView(
                planJSON: workoutExercise.yogaFlowJSON ?? plan?.encodedJSON()
            ) { json in
                workoutExercise.yogaFlowJSON = json
                workoutExercise.updatedAt = Date()
                if let updated = YogaFlowPlan.decode(from: json) {
                    session?.yogaStyleRaw = updated.styleRaw
                    if session?.endedAt == nil {
                        session?.durationSeconds = updated.totalSeconds > 0 ? updated.totalSeconds : nil
                    }
                }
                try? modelContext.save()
                WatchLink.shared.publishState()
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let session {
                YogaPlayerView(session: session, workoutExercise: workoutExercise, onComplete: {
                    complete(session)
                })
            }
        }
    }

    @ViewBuilder
    private func content(_ session: CardioSessionModel) -> some View {
        if !allowsLiveControls {
            historical(session)
        } else if session.liveStartedAt == nil && session.endedAt == nil {
            notStarted(session)
        } else if session.endedAt == nil {
            inProgress(session)
        } else {
            completed(session)
        }
    }

    // MARK: States

    private func historical(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            summaryStats(session)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                Text("Health and timer data stay attached to the original workout.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
        }
    }

    private func notStarted(_ session: CardioSessionModel) -> some View {
        VStack(spacing: Space.md) {
            flowRow

            Button { start(session) } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "play.fill")
                    Text("Start Guided Class")
                }
                .font(.bodyStrong).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("start-yoga-class")

            Text("Spoken cues guide each pose. Time, heart rate & calories auto-fill from Apple Watch.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)

            contraindicationNote

            Button { withAnimation { showManual.toggle() } } label: {
                Text(showManual ? "Hide manual entry" : "Log without guide")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
            }
            if showManual {
                YogaManualEditor(session: session, onChange: persist)
            }
        }
    }

    private func inProgress(_ session: CardioSessionModel) -> some View {
        VStack(spacing: Space.md) {
            if let runner = YogaFlowRunnerHub.shared.runner(for: session.id) {
                YogaRunnerStrip(runner: runner) { showPlayer = true }
            } else if let plan, plan.hasSteps {
                // Plan exists but no live runner (e.g. app relaunched
                // mid-session) — offer to pick the guidance back up.
                Button {
                    YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: modelContext)
                    showPlayer = true
                } label: {
                    Label("Resume guided class", systemImage: "figure.yoga")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsed = max(0, Int(ctx.date.timeIntervalSince(session.liveStartedAt ?? session.startedAt)))
                HStack(spacing: Space.sm) {
                    Circle().fill(theme.accent).frame(width: 10, height: 10)
                    Text("In session").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accent)
                    Spacer()
                    if let hr = WatchLink.shared.liveMetrics?.heartRate {
                        Label("\(hr)", systemImage: "heart.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.danger)
                    }
                    Text(Fmt.elapsed(elapsed)).font(.metricValue).monospacedDigit().foregroundStyle(theme.textPrimary)
                }
            }
            Button { complete(session) } label: {
                HStack(spacing: Space.sm) { Image(systemName: "checkmark"); Text("Complete") }
                    .font(.bodyStrong).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(theme.success)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("complete-yoga-session")
        }
    }

    private func completed(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if importing {
                HStack(spacing: Space.sm) {
                    ProgressView().tint(theme.accent)
                    Text("Fetching from Apple Health…").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
            summaryStats(session)
            HStack(spacing: 6) {
                let filled = session.avgHR != nil || session.activeEnergyKcal != nil
                Image(systemName: filled ? "checkmark.seal.fill" : "square.and.pencil")
                    .font(.system(size: 12)).foregroundStyle(filled ? theme.success : theme.textTertiary)
                Text(filled ? "Auto-filled from Apple Health" : "No Health data for this session — tap Edit")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                Spacer()
                Button(showManual ? "Done" : "Edit") { withAnimation { showManual.toggle() } }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
            }
            if showManual {
                YogaManualEditor(session: session, onChange: persist)
            }
            if let hr = session.avgHR, !showManual {
                HRZoneBar(avgHR: hr, maxHR: session.maxHR, durationSeconds: session.durationSeconds)
            }
            poseSplits(session)
        }
    }

    // MARK: Pieces

    /// Pre-start flow summary: what will run, and the door into editing it.
    private var flowRow: some View {
        HStack(spacing: 8) {
            Image(systemName: style.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Flow").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text(flowSummary)
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(plan?.hasSteps == true ? "Edit" : "Build") { showFlowBuilder = true }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(theme.accentSoft)
                .clipShape(Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("yoga-flow-menu")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var flowSummary: String {
        guard let plan, plan.hasSteps else { return "Single pose" }
        return "\(plan.structureSummary) · \(style.title)"
    }

    /// Safety surface: any contraindication note on any pose in the flow.
    @ViewBuilder
    private var contraindicationNote: some View {
        let notes = (plan?.steps ?? [])
            .compactMap { YogaPoseCatalog.pose(forSlug: $0.poseSlug) }
            .flatMap(\.contraindications)
        let unique = Array(Set(notes)).sorted()
        if !unique.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.warmup)
                Text("Take care with: \(unique.joined(separator: ", ")). Skip any pose that hurts.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func summaryStats(_ session: CardioSessionModel) -> some View {
        HStack {
            StatColumn(label: "Duration", value: Fmt.durationShort(session.durationSeconds), valueColor: theme.accent)
            StatColumn(label: "Poses", value: session.posesCompleted.map(String.init) ?? "—")
            StatColumn(label: "Avg HR", value: session.avgHR.map(String.init) ?? "—", valueColor: theme.danger)
            StatColumn(label: "kcal", value: session.activeEnergyKcal.map { String(Int($0)) } ?? "—")
        }
    }

    /// Completed guided classes list each hold with its actual duration.
    @ViewBuilder
    private func poseSplits(_ session: CardioSessionModel) -> some View {
        let splits = session.splits.filter { $0.label != nil }.sorted { $0.index < $1.index }
        if !splits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Poses").font(.tag).foregroundStyle(theme.textSecondary)
                ForEach(splits) { split in
                    HStack {
                        Text(split.label ?? "Pose \(split.index + 1)")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(Fmt.durationShort(split.durationSeconds))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(theme.accent)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            ZStack {
                theme.surfaceElevated
                YogaPoseArt(exercise: exercise, size: 24)
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                if let exercise {
                    Button {
                        onShowExerciseDetail(exercise)
                    } label: {
                        HStack(spacing: 4) {
                            Text(headerTitle).font(.system(size: 18, weight: .bold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(headerTitle).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.accent)
                }
                HStack(spacing: 6) {
                    Text("\(style.title) Yoga").font(.tag).foregroundStyle(theme.textSecondary)
                    if let group = workoutExercise.supersetGroup {
                        SupersetChip(group: group)
                    }
                }
            }
            Spacer()
            Menu {
                if let exercise {
                    Button("Exercise Details", systemImage: "info.circle") { onShowExerciseDetail(exercise) }
                    Divider()
                }
                SupersetMenuItems(
                    currentGroup: workoutExercise.supersetGroup,
                    availableGroups: availableSupersetGroups,
                    onAssign: onAssignSuperset,
                    onCreate: onCreateSuperset,
                    onUngroup: onUngroupSuperset
                )
                Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                Divider()
                Button("Remove Exercise", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textSecondary).frame(width: 44, height: 44)   // HIG minimum touch target
            }
        }
    }

    /// A multi-pose flow is named for the class, a single pose for the pose.
    private var headerTitle: String {
        if let plan, plan.steps.count > 1 { return "Guided Flow" }
        return exercise?.name ?? "Yoga"
    }

    // MARK: Session lifecycle

    private func ensureSession() {
        if let existing = workout.cardioSessions.first(where: { $0.workoutExerciseID == workoutExercise.id }) {
            session = existing
            return
        }
        // Ad-hoc pose added mid-workout: create its session on the spot,
        // exactly like the cardio card does.
        let new = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: Date(),
            durationSeconds: plan.map { $0.totalSeconds > 0 ? $0.totalSeconds : 0 }.flatMap { $0 > 0 ? $0 : nil },
            yogaStyleRaw: plan?.styleRaw
        )
        modelContext.insert(new)
        workout.cardioSessions.append(new)
        try? modelContext.save()
        session = new
    }

    private func start(_ session: CardioSessionModel) {
        Task { await HealthService.shared.requestAuthorization() }
        let now = Date()
        session.liveStartedAt = now
        session.startedAt = now
        try? modelContext.save()
        if let plan, plan.hasSteps {
            YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: modelContext)
            showPlayer = true
        }
        WatchLink.shared.publishState()
    }

    private func complete(_ session: CardioSessionModel) {
        YogaFlowRunnerHub.shared.stop(for: session.id)
        showPlayer = false
        let end = Date.now
        let start = session.liveStartedAt ?? session.startedAt
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: exercise,
            context: modelContext,
            endedAt: end,
            useClockDuration: true
        )
        try? modelContext.save()
        importing = true
        Task {
            let snap = await HealthService.shared.importSnapshot(from: start, to: end, modality: .other)
            await MainActor.run {
                if let hr = snap.avgHR { session.avgHR = hr }
                if let mx = snap.maxHR { session.maxHR = mx }
                if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                // No distance on the mat — deliberately not filled.
                session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                importing = false
                persist()
            }
        }
        WatchLink.shared.publishState()
    }

    private func persist() {
        workoutExercise.updatedAt = Date()
        try? modelContext.save()
    }
}

// MARK: - Manual entry (logged without the guide)

/// Duration + style for an unguided log; the flexibility snapshot is scaled
/// from the plan when the session completes.
struct YogaManualEditor: View {
    @Environment(\.theme) private var theme
    @Bindable var session: CardioSessionModel
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Duration").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Menu {
                    ForEach([5, 10, 15, 20, 30, 45, 60, 75, 90], id: \.self) { minutes in
                        Button("\(minutes) min") {
                            session.durationSeconds = minutes * 60
                            onChange()
                        }
                    }
                } label: {
                    Text(Fmt.durationShort(session.durationSeconds))
                        .font(.bodyStrong).foregroundStyle(theme.accent)
                }
            }
            Divider().overlay(theme.separator)
            HStack {
                Text("Style").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Menu {
                    ForEach(YogaStyle.allCases, id: \.self) { style in
                        Button {
                            session.yogaStyleRaw = style.rawValue
                            onChange()
                        } label: {
                            Label(style.title, systemImage: style.systemImage)
                        }
                    }
                } label: {
                    Text(session.resolvedYogaStyle.title)
                        .font(.bodyStrong).foregroundStyle(theme.accent)
                }
            }
        }
        .padding(Space.sm)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

// MARK: - Live guidance strip (inside YogaExerciseCard while recording)

/// Current pose, big auto-updating countdown, next-pose preview, per-hold
/// progress, and skip — plus a tap-through into the full-screen player.
struct YogaRunnerStrip: View {
    @Environment(\.theme) private var theme
    let runner: YogaFlowRunner
    var onOpenPlayer: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let step = runner.currentStep {
                HStack(alignment: .firstTextBaseline) {
                    Button(action: onOpenPlayer) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(step.displayName.uppercased())
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(theme.accent)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Text("Pose \(min(runner.currentIndex + 1, runner.steps.count)) of \(runner.steps.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                            if let next = runner.nextStep {
                                Text("Next: \(next.displayName)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Text("Final pose")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if runner.isPaused {
                        Text(Fmt.restTimer(runner.pausedRemaining))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        Text(timerInterval: Date.now...max(Date.now, runner.stepEndsAt), countsDown: true)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                    }
                    Button {
                        runner.isPaused ? runner.resume() : runner.pause()
                    } label: {
                        Image(systemName: runner.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)   // HIG minimum touch target
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    Button {
                        runner.skip()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                // One segment per hold; done = filled, current = glowing.
                HStack(spacing: 3) {
                    ForEach(runner.steps) { runtimeStep in
                        Capsule()
                            .fill(runtimeStep.id < runner.currentIndex
                                  ? theme.accent
                                  : (runtimeStep.id == runner.currentIndex ? theme.accent.opacity(0.9) : theme.surfaceElevated))
                            .frame(height: runtimeStep.id == runner.currentIndex ? 7 : 5)
                    }
                }
            } else if runner.isFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.success)
                    Text("Flow complete — tap Complete when you're ready.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(Space.sm)
        .background(theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

// MARK: - Full-screen guided player

/// The class experience: big pose art, name + Sanskrit, countdown ring, the
/// current spoken cue as a caption (accessibility: everything spoken is
/// visible), next-pose preview, and transport controls. Keeps the screen
/// awake while frontmost.
struct YogaPlayerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: CardioSessionModel
    let workoutExercise: WorkoutExerciseModel
    let onComplete: () -> Void

    private var runner: YogaFlowRunner? {
        YogaFlowRunnerHub.shared.runner(for: session.id)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: Space.lg) {
                topBar
                Spacer()
                if let runner, let step = runner.currentStep {
                    poseStage(runner: runner, step: step)
                } else {
                    finishedStage
                }
                Spacer()
                if let runner, !runner.isFinished {
                    transport(runner)
                }
            }
            .padding(Space.lg)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Minimize player")
            Spacer()
            if let runner {
                Text("Pose \(min(runner.currentIndex + 1, runner.steps.count)) of \(runner.steps.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if let hr = WatchLink.shared.liveMetrics?.heartRate {
                Label("\(hr)", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.danger)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private func poseStage(runner: YogaFlowRunner, step: YogaFlowRunner.RuntimeStep) -> some View {
        VStack(spacing: Space.lg) {
            ZStack {
                // Countdown ring wraps the pose art.
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let total = Double(step.seconds)
                    let remaining = runner.isPaused
                        ? Double(runner.pausedRemaining)
                        : max(0, runner.stepEndsAt.timeIntervalSince(ctx.date))
                    Circle()
                        .stroke(theme.surfaceElevated, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: total > 0 ? remaining / total : 0)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                YogaPoseArt(slug: step.poseStep.poseSlug, size: 130)
                    // Mirror the art for the right-side hold of a two-sided
                    // pose — one asset covers both sides.
                    .scaleEffect(x: step.side == .right ? -1 : 1)
            }
            .frame(width: 210, height: 210)

            VStack(spacing: 4) {
                Text(step.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                if let sanskrit = runner.currentPose?.sanskrit {
                    Text(sanskrit)
                        .font(.system(size: 15, weight: .medium).italic())
                        .foregroundStyle(theme.textSecondary)
                }
            }

            if runner.isPaused {
                Text(Fmt.restTimer(runner.pausedRemaining))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text(timerInterval: Date.now...max(Date.now, runner.stepEndsAt), countsDown: true)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.accent)
            }

            // Visual transcript of the guidance (first entry cue), so the
            // class works with cues muted or VoiceOver running.
            if let cue = runner.currentPose?.cues.entry.first {
                Text(cue)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg)
            }

            if let next = runner.nextStep {
                HStack(spacing: 6) {
                    Text("Next:")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    YogaPoseArt(slug: next.poseStep.poseSlug, size: 18)
                    Text(next.displayName)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                }
            }

            if let contraindications = runner.currentPose?.contraindications, !contraindications.isEmpty {
                Label(contraindications.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.warmup)
            }
        }
    }

    private var finishedStage: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.success)
            Text("Practice complete")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Finish Session")
                    .font(.bodyStrong).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(theme.success)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, Space.xl)
        }
    }

    private func transport(_ runner: YogaFlowRunner) -> some View {
        HStack(spacing: Space.xl) {
            Button { runner.back() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 56, height: 56)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Previous pose")

            Button {
                runner.isPaused ? runner.resume() : runner.pause()
            } label: {
                Image(systemName: runner.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(runner.isPaused ? "Resume" : "Pause")

            Button { runner.skip() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 56, height: 56)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Skip pose")
        }
        .padding(.bottom, Space.lg)
    }
}
