import CoreLocation
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Heart-rate zone helper. Classifies single readings (and, via
/// `CardioMetrics.measuredZoneSecondsArray`, the per-10s series a completed
/// session stores) against the user's configured zone model.
enum HRZone {
    /// The user's configured zone model (personalized max HR + boundaries),
    /// loaded from the shared store. Defaults to the classic 190/60-90% model.
    static var config: HRZoneConfig { HRZoneConfigStore.load() }
    static var defaultMaxHR: Int { config.maxHR }

    /// Zone (1...5) for a heart rate. Pass an explicit `maxHR` only to classify
    /// against a different max than the user's configured one.
    static func zone(forAvgHR hr: Int, maxHR: Int? = nil) -> Int {
        let cfg = config
        guard let maxHR else { return cfg.zone(for: hr) }
        return HRZoneConfig(maxHR: maxHR, restingHR: cfg.restingHR, zoneUpperBounds: cfg.zoneUpperBounds).zone(for: hr)
    }

    static func label(_ zone: Int) -> String {
        switch zone {
        case 1: "Z1 · Recovery"
        case 2: "Z2 · Endurance"
        case 3: "Z3 · Tempo"
        case 4: "Z4 · Threshold"
        default: "Z5 · VO₂ Max"
        }
    }
}

// MARK: - In-logger cardio card (replaces the strength set table for cardio)

/// A Strava-style cardio effort: derived pace/speed read-outs, modality-aware
/// metric inputs, an estimated HR-zone bar, and the muscles worked. No sets or
/// set types — cardio follows the cardio data model.
struct CardioExerciseCard: View {
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
    /// Completed workouts, for the "Last time" line — cardio's PREVIOUS column.
    var history: [WorkoutModel] = []

    @State private var session: CardioSessionModel?
    @State private var showManual = false
    @State private var importing = false
    @State private var showIntervalEditor = false
    @AppStorage("zoneVoiceCues") private var zoneVoiceCues = true

    private var kind: CardioKind {
        exercise?.resolvedCardioKind
            ?? CardioKind.infer(name: "Cardio", equipment: nil)
    }

    /// Treadmills / indoor machines don't produce a meaningful GPS distance, so
    /// we neither record a route nor auto-fill distance — the user enters it.
    private var providesGPSDistance: Bool {
        CardioKind.providesGPSDistance(name: exercise?.name ?? "", equipment: exercise?.equipment)
    }

    /// Best live distance while recording: the Apple Watch's streamed distance
    /// if it's flowing, else the phone's GPS running total, else whatever the
    /// session already holds. Treadmills / indoor machines stay manual-only.
    private func liveDistance(_ session: CardioSessionModel) -> Double? {
        guard providesGPSDistance else { return session.distanceMeters }
        if let watch = LiveMetricsHub.shared.liveMetrics?.distanceMeters, watch > 0 { return watch }
        if let gps = CardioRouteRecorder.shared.liveDistanceMeters(for: session.id), gps > 0 { return gps }
        return session.distanceMeters
    }

    private var currentZoneTarget: Int {
        IntervalPlan.decode(from: workoutExercise.intervalPlanJSON)?.hrZoneTarget ?? 0
    }

    private func setZoneTarget(_ zone: Int?) {
        var plan = IntervalPlan.decode(from: workoutExercise.intervalPlanJSON) ?? IntervalPlan(steps: [])
        plan.hrZoneTarget = zone
        workoutExercise.intervalPlanJSON = plan.isMeaningful ? plan.encodedJSON() : nil
        workoutExercise.updatedAt = Date()
        try? modelContext.save()
        WatchLink.shared.publishState()
    }

    /// Pre-start goal selector: open tracking, a heart-rate zone to hold, or
    /// a structured interval session — one row that makes the session's mode
    /// obvious before the Start button.
    private var goalRow: some View {
        let plan = IntervalPlan.decode(from: workoutExercise.intervalPlanJSON)
        let hasIntervals = plan?.hasSteps == true
        let zone = plan?.hrZoneTarget ?? 0
        return HStack(spacing: 8) {
            Image(systemName: hasIntervals ? "timer" : "target")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hasIntervals
                    ? theme.secondaryAccent
                    : (zone == 0 ? theme.textTertiary : theme.zoneColor(zone)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Goal").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text(goalSummary(plan))
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if hasIntervals {
                Button("Edit") { showIntervalEditor = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryAccent)
                    .buttonStyle(.plain)
            }
            Menu {
                Button {
                    setGoalOpen()
                } label: {
                    Label("Open tracking", systemImage: "record.circle")
                }
                Menu {
                    ForEach(1...5, id: \.self) { z in
                        Button(HRZone.label(z)) { setGoalZone(z) }
                    }
                } label: {
                    Label("Heart rate zone", systemImage: "target")
                }
                Button {
                    showIntervalEditor = true
                } label: {
                    Label("Zone & intervals…", systemImage: "slider.horizontal.3")
                }
            } label: {
                Text(plan?.isMeaningful == true ? "Change" : "Set")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.secondaryAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.secondaryAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("cardio-goal-menu")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .sheet(isPresented: $showIntervalEditor) {
            IntervalPlanBuilderView(planJSON: workoutExercise.intervalPlanJSON) { json in
                workoutExercise.intervalPlanJSON = json
                workoutExercise.updatedAt = Date()
                try? modelContext.save()
                WatchLink.shared.publishState()
            }
        }
    }

    private func goalSummary(_ plan: IntervalPlan?) -> String {
        guard let plan, plan.isMeaningful else { return "Open tracking" }
        if plan.hasSteps {
            var text = intervalPlanSummary(plan)
            if let zone = plan.hrZoneTarget { text += " · Z\(zone) lock" }
            return text
        }
        if let zone = plan.hrZoneTarget { return HRZone.label(zone) }
        return "Open tracking"
    }

    private func setGoalOpen() {
        workoutExercise.intervalPlanJSON = nil
        workoutExercise.updatedAt = Date()
        try? modelContext.save()
        WatchLink.shared.publishState()
    }

    private func setGoalZone(_ zone: Int) {
        // A zone goal replaces intervals — the selector is choosing the
        // session's mode, and the interval editor can still layer a zone
        // lock on top of steps.
        workoutExercise.intervalPlanJSON = IntervalPlan(steps: [], hrZoneTarget: zone).encodedJSON()
        workoutExercise.updatedAt = Date()
        try? modelContext.save()
        WatchLink.shared.publishState()
    }

    /// Live zone-lock picker on the cardio card: choose a target zone to get
    /// audible + haptic cues when you drift out and when you come back.
    private var zoneLockRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(currentZoneTarget == 0 ? theme.textTertiary : theme.zoneColor(currentZoneTarget))
            VStack(alignment: .leading, spacing: 1) {
                Text("Zone lock").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text(currentZoneTarget == 0 ? "Off" : HRZone.label(currentZoneTarget))
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Menu {
                Button("Off") { setZoneTarget(nil) }
                ForEach(1...5, id: \.self) { z in
                    Button(HRZone.label(z)) { setZoneTarget(z) }
                }
            } label: {
                Text(currentZoneTarget == 0 ? "Set" : "Z\(currentZoneTarget)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.secondaryAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.secondaryAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func fmtDistance(_ meters: Double) -> String {
        Fmt.cardioDistance(meters, kind: kind)
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                if let session {
                    content(session)
                } else {
                    ProgressView().tint(theme.secondaryAccent).frame(maxWidth: .infinity)
                }
                MuscleChips(muscles: kind.musclesWorked)
            }
        }
        .onAppear(perform: ensureSession)
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

    private func historical(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CardioSessionEditor(session: session, kind: kind, onChange: recompute, showInputs: false)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                Text("Health and timer data stay attached to the original workout.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            if let hr = session.avgHR {
                HRZoneBar(avgHR: hr, maxHR: session.maxHR, durationSeconds: session.durationSeconds)
            }
        }
    }

    /// The most recent completed run of this exercise — distance, time, and
    /// avg HR to match or beat, mirroring the strength PREVIOUS column.
    private var previousSessionText: String? {
        let currentExerciseID = workoutExercise.exerciseID
        let prior = history
            .filter { $0.id != workout.id && $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
        for past in prior {
            for we in past.exercises where we.exerciseID == currentExerciseID {
                guard let pastSession = past.cardioSessions.first(where: { $0.workoutExerciseID == we.id && $0.endedAt != nil }) else { continue }
                var parts: [String] = []
                if let meters = pastSession.distanceMeters, meters > 0 { parts.append(Fmt.cardioDistance(meters, kind: kind)) }
                if let seconds = pastSession.durationSeconds, seconds > 0 { parts.append(Fmt.durationShort(seconds)) }
                if let hr = pastSession.avgHR { parts.append("\(hr) bpm avg") }
                if !parts.isEmpty { return parts.joined(separator: " · ") }
            }
        }
        return nil
    }

    private func previousRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.textTertiary)
            Text("Last time: \(text)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .accessibilityLabel("Previous session: \(text)")
    }

    private func notStarted(_ session: CardioSessionModel) -> some View {
        VStack(spacing: Space.md) {
            if let previousSessionText {
                previousRow(previousSessionText)
            }
            goalRow
            Button { start(session) } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "play.fill")
                    Text("Start \(kind.title)")
                }
                .font(.bodyStrong).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(theme.secondaryAccent)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("start-cardio-segment")

            Text("Tracks live and auto-fills time, heart rate, distance & calories from Apple Watch.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)

            routeStateText(session)

            Button { withAnimation { showManual.toggle() } } label: {
                Text(showManual ? "Hide manual entry" : "Enter manually instead")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
            }
            if showManual {
                CardioSessionEditor(session: session, kind: kind, onChange: recompute)
            }
        }
    }

    private func inProgress(_ session: CardioSessionModel) -> some View {
        VStack(spacing: Space.md) {
            if let previousSessionText {
                previousRow(previousSessionText)
            }
            // Structured intervals: live step guidance drives the session.
            if let runner = IntervalRunnerHub.shared.runner(for: session.id) {
                IntervalRunnerStrip(runner: runner)
            } else if let planJSON = workoutExercise.intervalPlanJSON,
                      IntervalPlan.decode(from: planJSON)?.hasSteps == true {
                // Plan exists but no live runner (e.g. app relaunched
                // mid-session) — offer to pick the guidance back up.
                Button {
                    IntervalRunnerHub.shared.start(planJSON: planJSON, session: session, context: modelContext)
                } label: {
                    Label("Start interval guidance", systemImage: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryAccent)
                }
            } else {
                // Zone-only or open sessions can still set/adjust a zone
                // lock mid-run.
                zoneLockRow
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsed = max(0, Int(ctx.date.timeIntervalSince(session.liveStartedAt ?? session.startedAt)))
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.sm) {
                        Circle().fill(theme.danger).frame(width: 10, height: 10)
                        Text("Recording").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.danger)
                        Spacer()
                        Text(Fmt.elapsed(elapsed)).font(.metricValue).monospacedDigit().foregroundStyle(theme.textPrimary)
                    }
                    let liveDist = liveDistance(session)
                    HStack {
                        StatColumn(label: "Distance", value: liveDist.map { fmtDistance($0) } ?? "—", valueColor: theme.secondaryAccent)
                        StatColumn(
                            label: kind.usesPace ? "Pace" : "Speed",
                            value: kind.usesPace
                                ? CardioMetrics.paceString(distanceMeters: liveDist, durationSeconds: elapsed, kind: kind)
                                : CardioMetrics.speedString(distanceMeters: liveDist, durationSeconds: elapsed)
                        )
                        StatColumn(label: "HR", value: LiveMetricsHub.shared.liveMetrics?.heartRate.map(String.init) ?? "—", valueColor: theme.danger)
                    }
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
            .accessibilityIdentifier("complete-cardio-segment")
            Text("Do the run on your Apple Watch if you like — metrics sync in when you complete.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            routeStateText(session)
        }
    }

    private func completed(_ session: CardioSessionModel) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if importing {
                HStack(spacing: Space.sm) {
                    ProgressView().tint(theme.secondaryAccent)
                    Text("Fetching from Apple Health…").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
            CardioSessionEditor(session: session, kind: kind, onChange: recompute, showInputs: showManual)
            HStack(spacing: 6) {
                let filled = session.avgHR != nil || session.distanceMeters != nil || session.activeEnergyKcal != nil
                Image(systemName: filled ? "checkmark.seal.fill" : "square.and.pencil")
                    .font(.system(size: 12)).foregroundStyle(filled ? theme.success : theme.textTertiary)
                Text(filled ? "Auto-filled from Apple Health" : "No Health data for this segment — tap Edit")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                Spacer()
                Button(showManual ? "Done" : "Edit") { withAnimation { showManual.toggle() } }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.secondaryAccent)
            }
            if let hr = session.avgHR, !showManual {
                HRZoneBar(avgHR: hr, maxHR: session.maxHR, durationSeconds: session.durationSeconds)
            }
            // Structured session results: one row per interval step.
            let intervalSplits = session.splits.filter { $0.label != nil }.sorted { $0.index < $1.index }
            if !intervalSplits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Intervals").font(.tag).foregroundStyle(theme.textSecondary)
                    ForEach(intervalSplits) { split in
                        HStack {
                            Text(split.label ?? "Step \(split.index + 1)")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(Fmt.durationShort(split.durationSeconds))
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(theme.secondaryAccent)
                        }
                    }
                }
            }
            if providesGPSDistance {
                routeStateText(session)
            }
        }
    }

    private func intervalPlanSummary(_ plan: IntervalPlan) -> String {
        let workSteps = plan.steps.filter { $0.kind == .work }
        let recover = plan.steps.first { $0.kind == .recover }
        if let work = workSteps.first {
            let pair = recover.map { "\(Fmt.restTimer(work.seconds)) / \(Fmt.restTimer($0.seconds))" } ?? Fmt.restTimer(work.seconds)
            return "\(workSteps.count)× \(pair) · \(Fmt.durationShort(plan.totalSeconds)) total"
        }
        return "Structured session · \(Fmt.durationShort(plan.totalSeconds))"
    }

    @ViewBuilder
    private func routeStateText(_ session: CardioSessionModel) -> some View {
        if providesGPSDistance {
            let hasRoute = session.routePoints.count >= 2
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: hasRoute ? "map.fill" : "location")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hasRoute ? theme.success : theme.textTertiary)
                    Text(routeStatusCopy(hasRoute: hasRoute))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // A previously-denied permission can't be re-requested from
                // in-app — without this link route maps were a dead end the
                // copy told users to fix but gave no way to.
                if !hasRoute, locationDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Open Settings")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var locationDenied: Bool {
        let status = CardioRouteRecorder.shared.authorizationStatus
        return status == .denied || status == .restricted
    }

    private func routeStatusCopy(hasRoute: Bool) -> String {
        if hasRoute { return "Route saved on this device." }
        if locationDenied {
            return "Location is off for ForgeFit — allow it in Settings to save route maps. Distance and heart rate still work without it."
        }
        if !CardioRouteRecorder.shared.isAuthorized {
            return "Allow location to save route maps. Distance and heart rate still work without it."
        }
        return "Route recording is available for this outdoor session."
    }

    // MARK: - Segment lifecycle

    private func start(_ session: CardioSessionModel) {
        Task { await HealthService.shared.requestAuthorization() }
        if providesGPSDistance {
            CardioRouteRecorder.shared.start(session: session)
        }
        let now = Date()
        session.liveStartedAt = now
        session.startedAt = now
        try? modelContext.save()
        // Structured session: begin the step engine with the segment. The
        // runner drives the zone guard per step (work Z4, recover Z3...).
        if let planJSON = workoutExercise.intervalPlanJSON {
            IntervalRunnerHub.shared.start(planJSON: planJSON, session: session, context: modelContext)
        }
        // Zone-only lock (no steps): begin audible/haptic adherence cues.
        if IntervalRunnerHub.shared.runner(for: session.id) == nil,
           let target = IntervalPlan.decode(from: workoutExercise.intervalPlanJSON)?.hrZoneTarget {
            HRZoneGuard.shared.activate(targetZone: target, speak: zoneVoiceCues)
        }
        WatchLink.shared.publishState()
    }

    private func complete(_ session: CardioSessionModel) {
        IntervalRunnerHub.shared.stop(for: session.id)
        HRZoneGuard.shared.deactivate()
        let end = Date()
        let start = session.liveStartedAt ?? session.startedAt
        session.endedAt = end
        session.durationSeconds = max(1, Int(end.timeIntervalSince(start)))
        CardioRouteRecorder.shared.stop(session: session, in: modelContext)
        try? modelContext.save()
        importing = true
        let hadManualIntervalPlan = IntervalPlan.decode(from: workoutExercise.intervalPlanJSON)?.hasSteps == true
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        Task {
            let snap = await HealthService.shared.importSnapshot(from: start, to: end, modality: kind)
            await MainActor.run {
                if let d = snap.durationSeconds { session.durationSeconds = d }
                if let hr = snap.avgHR ?? bleStats?.avgHR { session.avgHR = hr }
                if let mx = snap.maxHR ?? bleStats?.maxHR { session.maxHR = mx }
                if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                // Skip auto distance for treadmills / indoor machines (manual
                // entry). For outdoor runs, keep the GPS route distance when we
                // recorded a route — it's what the splits are summed from, so
                // overwriting it with HealthKit's shorter estimate makes the
                // total disagree with the splits. Only fall back to HealthKit
                // when there's no route to trust.
                if let dist = snap.distanceMeters, providesGPSDistance, session.routePoints.count < 2 {
                    session.distanceMeters = dist
                }
                // Provisional estimate — finalize() below replaces it with the
                // measured distribution when the HR series has real coverage.
                session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
            }
            // Capture the time-series (measured zones) and auto-detect intervals (free-form runs).
            await CardioSeriesService.finalize(session: session, hadManualIntervalPlan: hadManualIntervalPlan, in: modelContext)
            await MainActor.run {
                importing = false
                recompute()
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Image(systemName: kind.systemImage)
                .font(.rowValue)
                .foregroundStyle(theme.secondaryAccent)
                .frame(width: 38, height: 38)
                .background(theme.surfaceElevated).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                if let exercise {
                    Button {
                        onShowExerciseDetail(exercise)
                    } label: {
                        ExerciseNameLabel(name: exercise.name, font: .system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Cardio").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.textPrimary)
                }
                HStack(spacing: 6) {
                    Text(kind.title).font(.tag).foregroundStyle(theme.textSecondary)
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

    private func ensureSession() {
        if let existing = workout.cardioSessions.first(where: { $0.workoutExerciseID == workoutExercise.id }) {
            session = existing
            return
        }
        let new = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: kind.rawValue,
            startedAt: Date()
        )
        modelContext.insert(new)
        workout.cardioSessions.append(new)
        try? modelContext.save()
        session = new
    }

    private func recompute() {
        if let session {
            // Manual field edits must not fabricate a distribution over real
            // data: keep the measured series-derived zones when they exist and
            // only re-spread the estimate for estimate-only sessions.
            session.hrZoneSeconds = CardioMetrics.measuredZoneSecondsArray(seriesJSON: session.sampleSeriesJSON)
                ?? CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
        }
        workoutExercise.updatedAt = Date()
        try? modelContext.save()
    }
}

/// The editable metrics + read-outs + zone bar for one cardio session.
private struct CardioSessionEditor: View {
    @Environment(\.theme) private var theme
    @Bindable var session: CardioSessionModel
    let kind: CardioKind
    let onChange: () -> Void
    var showInputs: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Headline derived read-outs
            HStack {
                readout(kind.usesPace ? "Pace" : "Speed",
                        kind.usesPace
                        ? CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds, kind: kind)
                        : CardioMetrics.speedString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds),
                        primary: true)
                readout("Distance", session.distanceMeters.map { fmtDistance($0) } ?? "—")
                readout("Time", Fmt.durationShort(session.durationSeconds))
            }
            .padding(.bottom, 2)

            if showInputs {
            Rectangle().fill(theme.separator).frame(height: 0.5)

            // Metric inputs (modality-aware)
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: Space.md) {
                field("Duration", "min", get: session.durationSeconds.map { Double($0) / 60 }, set: { session.durationSeconds = $0.map { Int($0 * 60) } })
                if kind.usesDistance {
                    field("Distance", kind.usesFixedMeters ? "m" : Fmt.distanceUnit.abbreviation,
                          get: session.distanceMeters.map { kind.usesFixedMeters ? $0 : Fmt.distanceUnit.distance(fromMeters: $0) },
                          set: { session.distanceMeters = $0.map { kind.usesFixedMeters ? $0 : Fmt.distanceUnit.meters(fromDistance: $0) } })
                }
                field("Avg HR", "bpm", get: session.avgHR.map(Double.init), set: { session.avgHR = $0.map { Int($0) } })
                field("Max HR", "bpm", get: session.maxHR.map(Double.init), set: { session.maxHR = $0.map { Int($0) } })
                field("Calories", "kcal", get: session.activeEnergyKcal, set: { session.activeEnergyKcal = $0 })
                if kind.usesElevation {
                    field("Elevation", "m", get: session.elevationGainMeters, set: { session.elevationGainMeters = $0 })
                }
                if kind.usesIncline {
                    field("Incline", "%", get: session.inclinePercent, set: { session.inclinePercent = $0 })
                }
                if kind.usesPower {
                    field("Power", "W", get: session.avgPowerWatts, set: { session.avgPowerWatts = $0 })
                }
                if kind.usesStrokeRate {
                    field("Stroke", "spm", get: session.strokeRate.map(Double.init), set: { session.strokeRate = $0.map { Int($0) } })
                } else if kind.usesCadence {
                    field("Cadence", "spm", get: session.avgCadence.map(Double.init), set: { session.avgCadence = $0.map { Int($0) } })
                }
                field("Effort", "/10", get: session.effort.map(Double.init), set: { session.effort = $0.map { Int($0) } })
            }

            if let hr = session.avgHR {
                HRZoneBar(avgHR: hr, maxHR: session.maxHR, durationSeconds: session.durationSeconds)
            }
            } // if showInputs
        }
    }

    private func readout(_ label: String, _ value: String, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.label).foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: primary ? 22 : 18, weight: .bold))
                .foregroundStyle(primary ? theme.secondaryAccent : theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fmtDistance(_ meters: Double) -> String {
        Fmt.cardioDistance(meters, kind: kind)
    }

    private func field(_ label: String, _ unit: String, get: Double?, set: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                TextField("—", text: Binding(
                    get: { get.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "" },
                    set: { set(Double($0)); onChange() }
                ))
                .keyboardType(.decimalPad)
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            }
            Text(unit).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - HR zone bar

struct HRZoneBar: View {
    @Environment(\.theme) private var theme
    let avgHR: Int
    /// Retained for call-site compatibility; classification now uses the user's
    /// configured max HR, not a single session's observed peak.
    var maxHR: Int? = nil
    let durationSeconds: Int?
    var zoneSeconds: [Int]? = nil
    var source: ZoneDataSource = .estimated

    private var distribution: [(zone: Int, seconds: Int)] {
        if let zoneSeconds, zoneSeconds.contains(where: { $0 > 0 }) {
            return zoneSeconds.enumerated().compactMap { index, seconds in
                seconds > 0 ? (index + 1, seconds) : nil
            }
        }
        return CardioMetrics.estimatedZoneSeconds(avgHR: avgHR, durationSeconds: durationSeconds)
    }

    var body: some View {
        let zone = HRZone.zone(forAvgHR: avgHR)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Heart-rate zones").font(.tag).foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(avgHR) bpm avg · \(HRZone.label(zone))")
                    .font(.tag).foregroundStyle(theme.zoneColor(zone))
            }
            let total = distribution.reduce(0) { $0 + $1.seconds }
            if !distribution.isEmpty, total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(distribution, id: \.zone) { item in
                            theme.zoneColor(item.zone)
                                .frame(width: max(3, geo.size.width * (Double(item.seconds) / Double(total))))
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                HStack {
                    ForEach(distribution, id: \.zone) { item in
                        Text("Z\(item.zone) \(Fmt.durationShort(item.seconds))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.zoneColor(item.zone))
                    }
                    Spacer()
                    Text(source.footnote)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }
}

/// Where a time-in-zone distribution came from, so the bar never claims more
/// than the data supports.
enum ZoneDataSource {
    /// Summed from real HR samples (Apple Watch session or the per-10s series).
    case measured
    /// Spread from a single average HR — an approximation, and labeled as one.
    case estimated
    /// An aggregate mixing measured and estimated sessions.
    case mixed

    var footnote: String {
        switch self {
        case .measured: "Measured"
        case .estimated: "Estimated from average HR"
        case .mixed: "Measured + estimated sessions"
        }
    }
}

/// Time-in-zone bar with an honest source label — "Measured" only when the
/// distribution really was summed from HR samples.
struct ZoneSecondsBar: View {
    @Environment(\.theme) private var theme
    let zoneSeconds: [Int]
    var source: ZoneDataSource = .measured

    var body: some View {
        let total = zoneSeconds.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            Text("Time in zones").font(.tag).foregroundStyle(theme.textSecondary)
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(zoneSeconds.enumerated()), id: \.offset) { index, seconds in
                            if seconds > 0 {
                                theme.zoneColor(index + 1)
                                    .frame(width: max(3, geo.size.width * (Double(seconds) / Double(total))))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                HStack {
                    ForEach(Array(zoneSeconds.enumerated()), id: \.offset) { index, seconds in
                        if seconds > 0 {
                            Text("Z\(index + 1) \(Fmt.durationShort(seconds))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.zoneColor(index + 1))
                        }
                    }
                    Spacer()
                    Text(source.footnote).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }
}

// MARK: - Muscle chips

struct MuscleChips: View {
    @Environment(\.theme) private var theme
    let muscles: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Works").font(.tag).foregroundStyle(theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(muscles, id: \.self) { muscle in
                        let isCardio = muscle == "cardiovascular"
                        Text(muscle.capitalized)
                            .font(.tag)
                            .foregroundStyle(isCardio ? theme.danger : theme.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(isCardio ? theme.danger.opacity(0.15) : theme.surfaceHighlight)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - Cardio summary (Insights tab)

struct CardioSummaryCard: View {
    @Environment(\.theme) private var theme
    let analytics: TrainingAnalytics
    @Binding var range: TimeChartRange

    @State private var weeklyMemo = Memo<String, [MetricPoint]>()
    @State private var sessionsMemo = Memo<String, [CardioSessionModel]>()
    @State private var zonesMemo = Memo<String, [Int]>()

    private var analyticsKey: String {
        var count = 0
        var latest = Date.distantPast
        for workout in analytics.workouts where workout.endedAt != nil && workout.deletedAt == nil {
            count += 1
            latest = max(latest, workout.updatedAt)
        }
        return "\(count)|\(latest.timeIntervalSince1970)"
    }
    private var weekly: [MetricPoint] {
        weeklyMemo("\(analyticsKey)|\(range.rawValue)") {
            analytics.cardioWeeklyMinutes(weeks: range.weekCount)
        }
    }
    private var sessions: [CardioSessionModel] {
        sessionsMemo(analyticsKey) {
            analytics.cardioSessions.sorted { $0.startedAt > $1.startedAt }
        }
    }
    private var zoneTotals: [Int] {
        zonesMemo("\(analyticsKey)|\(range.rawValue)") {
            analytics.cardioZoneTotals(weeks: range.weekCount)
        }
    }
    private var totalMinutes: Int { Int(weekly.reduce(0) { $0 + $1.value }) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SectionHeader("Cardio")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .top) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(totalMinutes)").font(.metricValue).foregroundStyle(theme.textPrimary)
                            Text("min").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer(minLength: Space.md)
                        TimeChartRangePicker(selection: $range)
                    }
                    if weekly.contains(where: { $0.value > 0 }) {
                        BarTrendChart(points: weekly, color: theme.secondaryAccent)
                    } else {
                        Text("Start a run, ride, or Zone 2 session to see cardio trends.")
                            .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            if zoneTotals.contains(where: { $0 > 0 }) {
                CardioZoneInsightsCard(zoneSeconds: zoneTotals)
            }
            if !sessions.isEmpty {
                Card {
                    VStack(spacing: Space.md) {
                        ForEach(sessions.prefix(5)) { session in
                            cardioRow(session)
                            if session.id != sessions.prefix(5).last?.id {
                                Rectangle().fill(theme.separator).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cardioRow(_ session: CardioSessionModel) -> some View {
        let kind = CardioKind.from(modality: session.modality)
        let zone = session.avgHR.map { HRZone.zone(forAvgHR: $0) }
        return HStack(spacing: Space.md) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(theme.secondaryAccent)
                .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text([Fmt.distance(session.distanceMeters), CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds)]
                    .filter { $0 != "—" }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.durationShort(session.durationSeconds)).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                if let zone { Text(HRZone.label(zone)).font(.tag).foregroundStyle(theme.zoneColor(zone)) }
            }
        }
    }
}

// MARK: - Cardio zone distribution + adaptations (Insights tab)

/// Evidence-based reference for what training in each HR zone develops. The
/// configured zone model may be %HRmax or %HRR/Karvonen; adaptations reflect
/// established endurance-training physiology, not the specific percentage basis.
struct CardioZoneInfo: Identifiable {
    let zone: Int
    let name: String
    let hrRange: String
    let adaptation: String
    let detail: String
    var id: Int { zone }

    static let all: [CardioZoneInfo] = [
        .init(zone: 1, name: "Recovery", hrRange: "<60%",
              adaptation: "Active recovery & blood flow",
              detail: "Very easy effort that flushes fatigue between hard sessions and adds aerobic time with minimal stress."),
        .init(zone: 2, name: "Endurance", hrRange: "60–70%",
              adaptation: "Aerobic base — mitochondria & fat oxidation",
              detail: "The foundation of endurance: builds mitochondrial density and capillaries and trains your body to burn fat. Most easy training should live here."),
        .init(zone: 3, name: "Tempo", hrRange: "70–80%",
              adaptation: "Aerobic power",
              detail: "Sustained \u{201C}comfortably hard\u{201D} work that lifts aerobic output. Effective but fatiguing — use it deliberately, not by accident."),
        .init(zone: 4, name: "Threshold", hrRange: "80–90%",
              adaptation: "Lactate threshold",
              detail: "Raises the effort you can hold before lactate accumulates — the engine behind faster sustained paces."),
        .init(zone: 5, name: "VO\u{2082} Max", hrRange: "90%+",
              adaptation: "Max aerobic & anaerobic capacity",
              detail: "Short, hard intervals that push your VO\u{2082}max ceiling and top-end power. High stress — keep the doses small."),
    ]
}

struct CardioZoneInsightsCard: View {
    @Environment(\.theme) private var theme
    let zoneSeconds: [Int]   // 5 buckets, Z1…Z5
    @State private var showAdaptations = false

    private var total: Int { zoneSeconds.reduce(0, +) }
    private var zoneBasis: String {
        HRZone.config.usesHeartRateReserve ? "heart-rate reserve" : "max heart rate"
    }
    private var dominantZone: Int? {
        guard total > 0 else { return nil }
        return (zoneSeconds.enumerated().max { $0.element < $1.element }?.offset).map { $0 + 1 }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Heart-rate zones").font(.bodyStrong).foregroundStyle(theme.textPrimary)

                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                if zoneSeconds[i] > 0 {
                                    theme.zoneColor(i + 1)
                                        .frame(width: max(3, geo.size.width * (Double(zoneSeconds[i]) / Double(total))))
                                }
                            }
                        }
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())

                    VStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { i in
                            if zoneSeconds[i] > 0 { legendRow(zone: i + 1, seconds: zoneSeconds[i]) }
                        }
                    }

                    Text("Estimated from average heart rate")
                        .font(.system(size: 11)).foregroundStyle(theme.textTertiary)

                    if let dominantZone {
                        Text(takeaway(for: dominantZone))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(theme.separator)

                    Button {
                        withAnimation(.spring(duration: 0.25)) { showAdaptations.toggle() }
                    } label: {
                        HStack {
                            Text("What your zones train")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                                .rotationEffect(.degrees(showAdaptations ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdaptations {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(CardioZoneInfo.all) { adaptationRow($0) }
                            Text("Zones are % of \(zoneBasis); adaptations reflect established endurance-training science (Seiler intensity model, ACSM guidance).")
                                .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Log a run, ride, or Zone 2 session with heart rate to see your zone distribution.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func legendRow(zone: Int, seconds: Int) -> some View {
        HStack(spacing: Space.sm) {
            Circle().fill(theme.zoneColor(zone)).frame(width: 9, height: 9)
            Text(HRZone.label(zone)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
            Spacer()
            Text(Fmt.durationShort(seconds)).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Text("\(Int((Double(seconds) / Double(total) * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.zoneColor(zone))
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func adaptationRow(_ info: CardioZoneInfo) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle().fill(theme.zoneColor(info.zone)).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Z\(info.zone) · \(info.name)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text(info.hrRange).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                }
                Text(info.adaptation).font(.tag).foregroundStyle(theme.zoneColor(info.zone))
                Text(info.detail).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func takeaway(for zone: Int) -> String {
        switch zone {
        case 1, 2: return "Most of your time is in the aerobic base — great for endurance and recovery."
        case 3: return "You're spending a lot of time at tempo — solid aerobic work; keep easy days truly easy."
        case 4: return "Lots of threshold work — strong for sustained pace; balance it with easy volume."
        default: return "Plenty of high-intensity time — powerful for VO\u{2082}max; make sure recovery keeps up."
        }
    }
}
