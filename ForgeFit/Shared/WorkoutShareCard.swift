import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One rendering unit in a shared workout log: a standalone exercise, or a
/// run of consecutive exercises sharing a superset group. Pairing is part of
/// what a workout *is* — two exercises alternated back-to-back is a different
/// session than the same two done straight — so the share image must carry it.
enum ShareLogEntry: Identifiable {
    case single(WorkoutExerciseModel)
    case superset(group: Int, members: [WorkoutExerciseModel])

    var id: String {
        switch self {
        case .single(let we): "single-\(we.id)"
        case .superset(let group, let members): "ss-\(group)-\(members.first?.id.uuidString ?? "")"
        }
    }

    /// Segments an ordered exercise list into standalone entries and superset
    /// runs. Runs are built from *consecutive* same-group exercises so the log
    /// keeps its logged order; a group member that isn't adjacent to its
    /// partners still carries its badge at the call site, so nothing goes
    /// unlabelled even when ordering is unusual. A group with a single member
    /// stays standalone — a one-exercise "superset" container would be noise.
    static func entries(for ordered: [WorkoutExerciseModel]) -> [ShareLogEntry] {
        var entries: [ShareLogEntry] = []
        var pending: (group: Int, members: [WorkoutExerciseModel])?

        func flush() {
            guard let pending else { return }
            entries.append(
                pending.members.count > 1
                    ? .superset(group: pending.group, members: pending.members)
                    : .single(pending.members[0])
            )
        }

        for we in ordered {
            guard let group = we.supersetGroup else {
                flush(); pending = nil
                entries.append(.single(we))
                continue
            }
            if var current = pending, current.group == group {
                current.members.append(we)
                pending = current
            } else {
                flush()
                pending = (group, [we])
            }
        }
        flush()
        return entries
    }
}

/// A branded, full-length snapshot of a completed workout, designed to be
/// rendered to a single tall image and shared / saved to Photos. Mirrors every
/// section the user sees on `WorkoutDetailView` — summary, session metrics, HR
/// graph, between-set recovery, muscles worked, and the full set log — so the
/// shared picture is a faithful capture of the workout, not a trimmed summary.
///
/// Takes an explicit `AppTheme` (and the already-loaded HealthKit-derived
/// `hrSamples` / `recoveryPoints`) so it renders correctly off-screen where the
/// environment and async loads aren't available.
struct WorkoutShareCard: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var hrSamples: [(date: Date, bpm: Int)] = []
    var recoveryPoints: [SetRecoveryPoint] = []
    /// Pre-rendered GPS route map per cardio session id (MapKit can't be
    /// rasterized off-screen, so the map is snapshotted before rendering).
    var routeMaps: [UUID: UIImage] = [:]

    /// Point size of the embedded route map — the cardio block's content width
    /// (card 430 − 28·2 padding − 16·2 block padding) at a 16:9-ish ratio.
    static let routeMapSize = CGSize(width: 342, height: 190)

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }
    private var summary: TrainingAnalytics.Summary { analytics.summary(for: workout) }
    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }
    private var sortedExercises: [WorkoutExerciseModel] {
        workout.exercises.sorted { $0.position < $1.position }
    }
    private func library(_ we: WorkoutExerciseModel) -> ExerciseLibraryModel? {
        exercises.first { $0.id == we.exerciseID }
    }

    private var logEntries: [ShareLogEntry] { ShareLogEntry.entries(for: sortedExercises) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statBlock
            if workout.avgHR != nil || workout.activeEnergyKcal != nil || workout.readinessAtStart != nil {
                sessionMetricsBlock
            }
            if !hrSamples.isEmpty {
                heartRateBlock
            }
            if recoveryPoints.contains(where: { $0.recoveryBPM != nil }) {
                recoveryBlock
            }
            if !summary.isCardio {
                let muscles = analytics.muscleVolume(for: workout)
                if !muscles.isEmpty { muscleBlock(muscles) }
            }
            Rectangle().fill(theme.separator).frame(height: 1)
            ForEach(logEntries) { entry in
                switch entry {
                case .single(let we):
                    exerciseBlock(we)
                case .superset(let group, let members):
                    supersetContainer(group: group, members: members)
                }
            }
            // Sessions not linked to an exercise (Health/GPX imports).
            ForEach(workout.cardioSessions.filter { $0.workoutExerciseID == nil }) { session in
                if session.isYogaSession {
                    yogaBlock(nil, session)
                } else {
                    cardioBlock(nil, session)
                }
            }
            footer
        }
        .padding(28)
        .frame(width: 430, alignment: .leading)
        .background(theme.background)
    }

    // MARK: - Header

    private var header: some View {
        chrome.header(title: workout.title ?? "Workout", date: workout.startedAt)
    }

    // MARK: - Stat block

    private var statBlock: some View {
        HStack(spacing: 12) {
            chrome.stat("Duration", Fmt.durationShort(summary.durationSeconds), theme.textPrimary)
            if summary.isCardio {
                chrome.stat("Distance", Fmt.distance(workout.cardioSessions.first?.distanceMeters), theme.secondaryAccent)
                chrome.stat("Avg HR", summary.avgHR.map { "\($0)" } ?? "—", theme.danger)
            } else {
                chrome.stat("Volume", Fmt.volume(summary.volume), theme.secondaryAccent)
                chrome.stat("Sets", ShareCardChrome.setCount(summary.sets), theme.textPrimary)
            }
        }
    }

    // MARK: - Session metrics

    private var sessionMetricsBlock: some View {
        chrome.surfaceBlock {
            chrome.blockTitle("Session metrics", systemImage: "heart.fill", color: theme.danger) {
                if let readiness = workout.readinessAtStart {
                    Text("Started \(readiness)% ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.readinessColor(Double(readiness) / 100))
                }
            }
            HStack(spacing: 12) {
                chrome.miniStat("Avg HR", Fmt.bpm(workout.avgHR))
                chrome.miniStat("Max HR", Fmt.bpm(workout.maxHR))
                chrome.miniStat("Energy", workout.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
            }
            if workout.hrZoneSeconds.contains(where: { $0 > 0 }) {
                ZoneSecondsBar(
                    zoneSeconds: workout.hrZoneSeconds,
                    totalDurationSeconds: summary.durationSeconds
                )
            }
        }
    }

    // MARK: - Heart rate graph

    private var heartRateBlock: some View {
        chrome.surfaceBlock {
            chrome.blockTitle("Heart rate", systemImage: "waveform.path.ecg", color: theme.danger) {
                if let peak = hrSamples.map(\.bpm).max() {
                    Text("peak \(peak) bpm")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.danger)
                }
            }
            HeartRateTrendChart(samples: hrSamples, bands: HeartRateTrendChart.cardioBands(for: workout))
        }
    }

    // MARK: - Between-set recovery

    private var recoveryBlock: some View {
        let dict = Dictionary(recoveryPoints.map { ($0.setID, $0) }, uniquingKeysWith: { first, _ in first })
        let drops = recoveryPoints.compactMap(\.recoveryBPM)
        let avg = drops.isEmpty ? 0 : Int((Double(drops.reduce(0, +)) / Double(drops.count)).rounded())
        let best = drops.max() ?? 0
        let maxDrop = max(1, best)
        return chrome.surfaceBlock {
            chrome.blockTitle("Between-set recovery", systemImage: "arrow.down.heart.fill", color: theme.danger) { EmptyView() }
            HStack(spacing: 12) {
                chrome.miniStat("Avg drop", "\(avg) bpm")
                chrome.miniStat("Best drop", "\(best) bpm")
                chrome.miniStat("Sets", "\(drops.count)")
            }
            ForEach(sortedExercises.filter { we in workout.cardioSessions.allSatisfy { $0.workoutExerciseID != we.id } }) { we in
                let sets = we.sets.sorted { $0.position < $1.position }
                let rows = Array(sets.enumerated()).compactMap { index, set -> (String, SetRecoveryPoint)? in
                    dict[set.id].map { (numberedLabel(for: set, index: index, sets: sets), $0) }
                }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(library(we)?.name ?? "Exercise")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row.0).font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textSecondary).frame(width: 30, alignment: .leading)
                                Text("\(row.1.peakHR) bpm peak")
                                    .font(.tag).foregroundStyle(theme.textPrimary)
                                    .frame(width: 92, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(theme.surfaceHighlight)
                                        Capsule().fill(theme.success)
                                            .frame(width: geo.size.width * CGFloat(row.1.recoveryBPM ?? 0) / CGFloat(maxDrop))
                                    }
                                }
                                .frame(height: 7)
                                Text(row.1.recoveryBPM.map { "▼\($0)" } ?? "—")
                                    .font(.tag)
                                    .foregroundStyle(row.1.recoveryBPM != nil ? theme.success : theme.textTertiary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Muscles worked

    private func muscleBlock(_ rows: [(muscle: String, sets: Double)]) -> some View {
        let maxSets = rows.map(\.sets).max() ?? 1
        return chrome.surfaceBlock {
            chrome.blockTitle("Muscles worked", systemImage: "figure.strengthtraining.traditional", color: theme.accent) { EmptyView() }
            VStack(spacing: 7) {
                ForEach(rows, id: \.muscle) { row in
                    VStack(spacing: 4) {
                        HStack {
                            Text(row.muscle.capitalized).font(.label).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text("\(row.sets.formatted(.number.precision(.fractionLength(0...1)))) sets")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceHighlight)
                                Capsule().fill(theme.accent)
                                    .frame(width: geo.size.width * (row.sets / max(1, maxSets)))
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
    }

    // MARK: - Log entries

    /// Routes one exercise to the block matching how it was logged. Yoga and
    /// cardio both log as sessions but read nothing alike — a flow has poses
    /// and a style, a run has pace and distance.
    /// `showsSupersetBadge` is false inside a superset container, where the
    /// header already names the group — a badge there would repeat it once
    /// per member.
    @ViewBuilder
    private func exerciseBlock(_ we: WorkoutExerciseModel, showsSupersetBadge: Bool = true) -> some View {
        if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == we.id }) {
            if session.isYogaSession {
                yogaBlock(we, session, showsSupersetBadge: showsSupersetBadge)
            } else {
                cardioBlock(we, session, showsSupersetBadge: showsSupersetBadge)
            }
        } else {
            strengthBlock(we, showsSupersetBadge: showsSupersetBadge)
        }
    }

    /// Superset run: members share one bordered container in the group's
    /// colour, so the pairing is visible at a glance rather than inferred
    /// from adjacency.
    private func supersetContainer(group: Int, members: [WorkoutExerciseModel]) -> some View {
        let color = SupersetUI.color(for: group)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Text(SupersetUI.label(for: group))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
            }
            // Members carry no badge: the container's header and border
            // already say which group they're in, and the enclosure itself
            // shows they're paired.
            ForEach(members) { we in
                exerciseBlock(we, showsSupersetBadge: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(color.opacity(0.45), lineWidth: 1.5)
        )
    }

    /// Group badge for a superset member rendered OUTSIDE a container — a
    /// lone member, or one separated from its partners in the logged order.
    /// Inside a container the header carries this, so it's suppressed there.
    @ViewBuilder
    private func supersetBadge(_ we: WorkoutExerciseModel, enabled: Bool) -> some View {
        if enabled, let group = we.supersetGroup {
            Text(SupersetUI.label(for: group))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SupersetUI.color(for: group))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(SupersetUI.color(for: group).opacity(0.16), in: Capsule())
        }
    }

    // MARK: - Strength

    private func strengthBlock(_ we: WorkoutExerciseModel, showsSupersetBadge: Bool) -> some View {
        let unit = library(we)?.effectiveWeightUnit ?? Fmt.unit
        let sets = we.sets.sorted { $0.position < $1.position }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(library(we)?.name ?? "Exercise")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
                supersetBadge(we, enabled: showsSupersetBadge)
            }
            if let notes = we.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            // Deterministic per-set numbering (no mutable counter) — ImageRenderer
            // evaluates the body more than once, so a running `var` double-counts.
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                let style = SetTypeStyle.of(set.setType)
                let label = numberedLabel(for: set, index: index, sets: sets)
                let isCompleted = HistoricalSetPresentation.isCompleted(set)
                HStack(spacing: 8) {
                    Text(label).font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            isCompleted
                                ? (set.setType == .working ? theme.textSecondary : style.color)
                                : theme.textTertiary
                        )
                        .frame(width: 34, alignment: .leading)
                    Text(HistoricalSetPresentation.shareValue(set, unit: unit))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isCompleted ? theme.textPrimary : theme.textTertiary)
                    if set.setType != .working {
                        Text(style.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isCompleted ? style.color : theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if isCompleted, let rpe = set.rpe {
                        Text("RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    } else if isCompleted, let rir = set.rir {
                        Text("\(rir) RIR")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(theme.success)
                    } else {
                        Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                    }
                }
                .opacity(isCompleted ? 1 : 0.72)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Cardio

    private func cardioBlock(_ we: WorkoutExerciseModel?, _ session: CardioSessionModel, showsSupersetBadge: Bool = true) -> some View {
        let kind = CardioKind.from(modality: session.modality)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                Text(we.flatMap { library($0)?.name } ?? kind.title)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
                if let we { supersetBadge(we, enabled: showsSupersetBadge) }
            }
            // Chips follow the modality contract: a rower speaks /500m
            // splits, a bike watts, a stair machine floors. Showing a
            // generic "Pace" for all of them misreports the session.
            WrapLayout(spacing: 8) {
                if kind.usesDistance, let d = session.distanceMeters, d > 0 {
                    chrome.chip("Distance", Fmt.cardioDistance(d, kind: kind))
                }
                chrome.chip("Time", Fmt.durationShort(session.durationSeconds))
                if session.distanceMeters ?? 0 > 0 {
                    chrome.chip(
                        kind.paceHeadline,
                        kind.usesPace
                            ? CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds, kind: kind)
                            : CardioMetrics.speedString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds)
                    )
                }
                if kind.usesPower, let watts = session.avgPowerWatts, watts > 0 {
                    chrome.chip("Power", "\(Int(watts.rounded())) W")
                }
                if kind.usesFloors, let floors = session.floorsClimbed, floors > 0 {
                    chrome.chip("Floors", "\(floors)")
                }
                if kind.usesStepCount, let steps = session.totalSteps, steps > 0 {
                    chrome.chip(kind.stepCountLabel, "\(steps)")
                }
                if kind.usesStrokeRate, let rate = session.strokeRate, rate > 0 {
                    chrome.chip("Stroke rate", "\(rate) spm")
                }
                if kind.usesCadence, let cadence = session.avgCadence, cadence > 0 {
                    chrome.chip("Cadence", "\(cadence) \(kind.cadenceUnit)")
                }
                if kind.usesSwimContract, let lengths = session.lengthsCompleted, lengths > 0 {
                    chrome.chip("Lengths", "\(lengths)")
                }
                if kind.usesElevation, let gain = session.elevationGainMeters, gain > 0 {
                    chrome.chip("Elevation", "\(Int(gain)) m")
                }
                if let hr = session.avgHR { chrome.chip("Avg HR", "\(hr)") }
            }
            if let map = routeMaps[session.id] {
                Image(uiImage: map)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.separator, lineWidth: 1)
                    )
            }
            let zones = CardioMetrics.measuredZoneSecondsArray(seriesJSON: session.sampleSeriesJSON) ?? session.hrZoneSeconds
            if zones.reduce(0, +) > 0 {
                zoneBar(zones)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Yoga

    /// Yoga logs as a session like cardio but shares none of its vocabulary:
    /// the mat doesn't move, so there's no distance or pace — the honest
    /// metrics are time, poses, and style. Previously these rendered through
    /// `cardioBlock`, which stamped a running figure and a "Pace" chip on a
    /// yin practice.
    private func yogaBlock(_ we: WorkoutExerciseModel?, _ session: CardioSessionModel, showsSupersetBadge: Bool = true) -> some View {
        let style = session.resolvedYogaStyle
        let name = we.flatMap { library($0)?.name } ?? "Yoga"
        let poses = session.splits.filter { $0.label != nil }.sorted { $0.index < $1.index }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: style.systemImage)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent)
                Text(name)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
                if let we { supersetBadge(we, enabled: showsSupersetBadge) }
                Spacer(minLength: 0)
                Text("\(style.title) Yoga")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.accentSoft, in: Capsule())
            }
            WrapLayout(spacing: 8) {
                chrome.chip("Time", Fmt.durationShort(session.durationSeconds))
                if let count = session.posesCompleted, count > 0 {
                    chrome.chip("Poses", "\(count)")
                }
                if let hr = session.avgHR { chrome.chip("Avg HR", "\(hr)") }
                if let kcal = session.activeEnergyKcal, kcal > 0 {
                    chrome.chip("Energy", "\(Int(kcal)) kcal")
                }
            }
            if !poses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Poses").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(poses) { pose in
                        HStack(spacing: 8) {
                            Text(pose.label ?? "Pose")
                                .font(.system(size: 12)).foregroundStyle(theme.textPrimary)
                            Spacer(minLength: 0)
                            Text(Fmt.durationShort(pose.durationSeconds))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            let zones = CardioMetrics.measuredZoneSecondsArray(seriesJSON: session.sampleSeriesJSON) ?? session.hrZoneSeconds
            if zones.reduce(0, +) > 0 {
                zoneBar(zones)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func zoneBar(_ zones: [Int]) -> some View {
        let total = max(1, zones.reduce(0, +))
        return HStack(spacing: 2) {
            ForEach(Array(zones.enumerated()), id: \.offset) { index, seconds in
                if seconds > 0 {
                    theme.zoneColor(index + 1)
                        .frame(width: max(3, 360 * (Double(seconds) / Double(total))), height: 8)
                }
            }
        }
        .clipShape(Capsule())
    }

    private func numberedLabel(for set: SetModel, index: Int, sets: [SetModel]) -> String {
        ShareSetLabels.numberedLabel(for: set, index: index, sets: sets)
    }

    // MARK: - Footer

    private var footer: some View {
        chrome.footer()
    }
}

// MARK: - Rendering & sharing

@MainActor
enum ShareRenderer {
    /// Render any share card to a retina-scale image. Injects the theme into the
    /// environment so environment-reading subviews (charts, zone bars) render
    /// correctly off-screen.
    static func image<V: View>(_ content: V, theme: AppTheme) -> UIImage? {
        let renderer = ImageRenderer(content: content.environment(\.theme, theme))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

@MainActor
enum WorkoutShareRenderer {
    /// Render the full-length share card to a single tall image at retina scale.
    static func image(
        for workout: WorkoutModel,
        exercises: [ExerciseLibraryModel],
        theme: AppTheme,
        hrSamples: [(date: Date, bpm: Int)] = [],
        recoveryPoints: [SetRecoveryPoint] = [],
        routeMaps: [UUID: UIImage] = [:]
    ) -> UIImage? {
        ShareRenderer.image(
            WorkoutShareCard(
                workout: workout,
                exercises: exercises,
                theme: theme,
                hrSamples: hrSamples,
                recoveryPoints: recoveryPoints,
                routeMaps: routeMaps
            ),
            theme: theme
        )
    }
}

#if canImport(UIKit)
/// Standard iOS share sheet — lets the user save the image to Photos or send it
/// anywhere. Sharing a single `UIImage` surfaces the "Save Image" action.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so any rendered share image can drive `.sheet(item:)`.
struct ShareImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}
#endif
